-- =====================================================================
--  ROBÔ DE OFERTAS — banco de dados completo (Supabase)
--  Como usar: Supabase → SQL Editor → New query → cole TUDO → Run.
--  Pode rodar mais de uma vez sem problema (não apaga nada).
-- =====================================================================

create extension if not exists unaccent;
create extension if not exists pgcrypto;

-- ---------- Slug a partir do título --------------------------------------
create or replace function slugify(txt text)
returns text language sql immutable as $$
  select trim(both '-' from
    regexp_replace(lower(unaccent(coalesce(txt,''))), '[^a-z0-9]+', '-', 'g'));
$$;

-- ---------- Ofertas -------------------------------------------------------
create table if not exists ofertas (
  id               uuid primary key default gen_random_uuid(),
  slug             text unique,
  loja             text not null check (loja in ('amazon','shopee','mercadolivre','magalu','outra')),
  external_id      text,                       -- ASIN, item_id da Shopee, MLB...
  titulo           text not null,
  gancho           text,                       -- headline em caixa alta (Claude)
  descricao        text,
  categoria        text default 'geral',
  preco_de         numeric(12,2),
  preco_por        numeric(12,2) not null,
  desconto_pct     int generated always as (
                     case when preco_de is not null and preco_de > preco_por
                          then round(100 * (preco_de - preco_por) / preco_de)::int end
                   ) stored,
  cupom            text,
  observacao       text,                       -- "pagando com Pix", "frete grátis Prime"...
  link_afiliado    text not null,
  link_original    text,
  imagem_url       text,
  status           text not null default 'ativa' check (status in ('rascunho','ativa','esgotada','expirada')),
  destaque         boolean not null default false,
  fonte            text,                       -- 'shopee_api', 'manual', 'monitor_telegram'...
  publicado_em     timestamptz not null default now(),
  expira_em        timestamptz,
  enviado_whatsapp_em timestamptz,
  enviado_telegram_em timestamptz,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  unique (loja, external_id)                   -- evita postar o mesmo produto duas vezes
);

create index if not exists ofertas_feed_idx on ofertas (status, publicado_em desc);
create index if not exists ofertas_cat_idx  on ofertas (categoria);

-- Slug automático (título + 6 caracteres do id) e updated_at
create or replace function ofertas_before_write()
returns trigger language plpgsql as $$
begin
  if new.slug is null or new.slug = '' then
    new.slug := left(slugify(new.titulo), 80) || '-' || left(replace(new.id::text,'-',''), 6);
  end if;
  new.atualizado_em := now();
  return new;
end $$;

drop trigger if exists trg_ofertas_bw on ofertas;
create trigger trg_ofertas_bw before insert or update on ofertas
for each row execute function ofertas_before_write();

-- ---------- Histórico de preço (filtro anti "De R$ 999" falso) ------------
create table if not exists precos_historico (
  id           bigserial primary key,
  loja         text not null,
  external_id  text not null,
  preco        numeric(12,2) not null,
  coletado_em  timestamptz not null default now()
);
create index if not exists precos_hist_idx on precos_historico (loja, external_id, coletado_em desc);

-- Menor preço dos últimos N dias: o n8n consulta antes de publicar
create or replace function menor_preco(p_loja text, p_external_id text, p_dias int default 60)
returns numeric language sql stable as $$
  select min(preco) from precos_historico
  where loja = p_loja and external_id = p_external_id
    and coletado_em > now() - make_interval(days => p_dias);
$$;

-- ---------- Cliques (medição própria) -------------------------------------
create table if not exists cliques (
  id         bigserial primary key,
  oferta_id  uuid references ofertas(id) on delete cascade,
  origem     text,          -- ?src= do link (whatsapp, telegram, insta, google...)
  pagina     text,          -- 'feed' ou 'oferta'
  criado_em  timestamptz not null default now()
);
create index if not exists cliques_oferta_idx on cliques (oferta_id, criado_em desc);

-- ---------- Grupos / comunidades (rotação do link de entrada) -------------
create table if not exists grupos (
  id           serial primary key,
  canal        text not null check (canal in ('whatsapp','telegram')),
  nome         text not null,
  link_convite text not null,
  membros      int not null default 0,
  capacidade   int not null default 1000,
  ativo        boolean not null default true,
  ordem        int not null default 0
);

-- Devolve o convite do primeiro grupo ativo com vaga
create or replace function proximo_grupo(p_canal text)
returns text language sql stable security definer set search_path = public as $$
  select link_convite from grupos
  where canal = p_canal and ativo and membros < capacidade
  order by ordem, id limit 1;
$$;

-- ---------- Painel rápido: cliques por oferta (últimos 7 dias) ------------
create or replace view resumo_cliques_7d as
select o.id, o.titulo, o.loja, o.categoria, o.preco_por,
       count(c.id)                                         as cliques,
       count(c.id) filter (where c.origem = 'whatsapp')    as via_whatsapp,
       count(c.id) filter (where c.origem = 'telegram')    as via_telegram
from ofertas o
left join cliques c on c.oferta_id = o.id and c.criado_em > now() - interval '7 days'
group by o.id
order by cliques desc;

-- ---------- Segurança (RLS) -----------------------------------------------
alter table ofertas          enable row level security;
alter table cliques          enable row level security;
alter table grupos           enable row level security;
alter table precos_historico enable row level security;

-- Público lê só o que está no ar
drop policy if exists ofertas_leitura_publica on ofertas;
create policy ofertas_leitura_publica on ofertas
  for select to anon using (status in ('ativa','esgotada'));

-- Público só registra clique (não lê)
drop policy if exists cliques_insert_publico on cliques;
create policy cliques_insert_publico on cliques
  for insert to anon with check (true);

-- grupos e precos_historico: sem policy para anon = fechados.
-- O site pega o convite só pela função proximo_grupo().
grant execute on function proximo_grupo(text) to anon;
revoke select on resumo_cliques_7d from anon;

-- A service_role (n8n) ignora RLS e grava em tudo.

-- ---------- Funções usadas pela Shopee automática ----------
create or replace function avaliar_oferta(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loja    text    := p->>'loja';
  v_ext     text    := p->>'external_id';
  v_preco   numeric := (p->>'preco_por')::numeric;
  v_min     numeric;
  v_recente boolean;
begin
  select min(preco) into v_min
  from precos_historico
  where loja = v_loja and external_id = v_ext
    and coletado_em > now() - interval '60 days';

  if not exists (
    select 1 from precos_historico
    where loja = v_loja and external_id = v_ext
      and coletado_em > now() - interval '6 hours'
  ) then
    insert into precos_historico (loja, external_id, preco) values (v_loja, v_ext, v_preco);
  end if;

  select exists (
    select 1 from ofertas
    where loja = v_loja and external_id = v_ext
      and status <> 'rascunho'
      and publicado_em > now() - interval '7 days'
  ) into v_recente;

  if v_recente then
    return jsonb_build_object('publicar', false, 'motivo', 'já postado nos últimos 7 dias', 'oferta', p);
  end if;

  if v_min is not null and v_preco > v_min * 1.03 then
    return jsonb_build_object('publicar', false,
      'motivo', 'preço acima do menor dos últimos 60 dias (R$ ' || v_min || ')', 'oferta', p);
  end if;

  return jsonb_build_object('publicar', true,
    'motivo', case when v_min is null then 'primeira coleta' else 'no menor preço de 60 dias' end,
    'oferta', p);
end $$;

-- Só a service_role (n8n) pode chamar
revoke execute on function avaliar_oferta(jsonb) from public, anon, authenticated;
grant  execute on function avaliar_oferta(jsonb) to service_role;

-- ---------- Capturas de outros grupos ----------
create table if not exists capturas (
  id              uuid primary key default gen_random_uuid(),
  fonte_jid       text,                 -- grupo de onde veio
  fonte_msg_id    text unique,          -- id da mensagem no WhatsApp (evita processar 2x)
  texto_original  text,
  loja            text,
  produto_key     text,                 -- MLB… ou ASIN (ou a URL, se não identificou)
  produto_url     text,                 -- link limpo, sem afiliado de ninguém
  link_original   text,                 -- link como veio no post
  preco_de        numeric(12,2),
  preco_por       numeric(12,2),
  cupom           text,
  tg_message_id   bigint,               -- mensagem que o bot te mandou (para casar a sua resposta)
  status          text not null default 'pendente'
                  check (status in ('pendente','em_previa','ignorada')),
  criado_em       timestamptz not null default now()
);
create index if not exists capturas_key_idx on capturas (produto_key, criado_em desc);
create index if not exists capturas_tg_idx  on capturas (tg_message_id);

alter table capturas enable row level security;   -- sem policy: só a service_role acessa

-- Registra a captura se ela for nova. Barra:
--   mesma mensagem duas vezes; mesmo produto nas últimas 24h; produto que você já postou nos últimos 7 dias.
create or replace function registrar_captura(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if exists (select 1 from capturas where fonte_msg_id = p->>'fonte_msg_id') then
    return jsonb_build_object('novo', false, 'motivo', 'mensagem repetida');
  end if;

  if exists (select 1 from capturas
             where produto_key = p->>'produto_key'
               and criado_em > now() - interval '24 hours') then
    return jsonb_build_object('novo', false, 'motivo', 'produto já capturado nas últimas 24h');
  end if;

  if exists (select 1 from ofertas
             where external_id = p->>'produto_key'
               and status in ('ativa','rascunho')
               and publicado_em > now() - interval '7 days') then
    return jsonb_build_object('novo', false, 'motivo', 'você já postou esse produto nos últimos 7 dias');
  end if;

  insert into capturas (fonte_jid, fonte_msg_id, texto_original, loja, produto_key, produto_url,
                        link_original, preco_de, preco_por, cupom)
  values (p->>'fonte_jid', p->>'fonte_msg_id', p->>'texto_original', p->>'loja', p->>'produto_key',
          p->>'produto_url', p->>'link_original',
          nullif(p->>'preco_de','')::numeric, nullif(p->>'preco_por','')::numeric, p->>'cupom')
  returning id into v_id;

  return jsonb_build_object('novo', true, 'id', v_id);
end $$;

revoke execute on function registrar_captura(jsonb) from public, anon, authenticated;
grant  execute on function registrar_captura(jsonb) to service_role;

-- ---------- Ajustes feitos pelo bot do Telegram ----------
create table if not exists ajustes (
  chave         text primary key,
  valor         jsonb,
  atualizado_em timestamptz not null default now()
);
alter table ajustes enable row level security;   -- só a service_role (n8n) acessa

-- ---------- Ofertas que aparecem (ou não) no site ----------
alter table ofertas add column if not exists mostrar_no_site boolean not null default true;
drop policy if exists ofertas_leitura_publica on ofertas;
create policy ofertas_leitura_publica on ofertas
  for select to anon using (status in ('ativa','esgotada') and mostrar_no_site);


-- ---------- Entradas nos grupos por origem (?src=) ----------
create or replace view entradas_por_origem_30d as
select origem, replace(pagina, 'entrada-', '') as canal, count(*) as entradas
from cliques
where pagina like 'entrada-%' and criado_em > now() - interval '30 days'
group by 1, 2
order by entradas desc;
revoke all on entradas_por_origem_30d from anon, authenticated;

-- ---------- Permissões (garante acesso mesmo em projetos novos do Supabase) ----------
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
grant select on ofertas to anon;
grant insert on cliques to anon;
grant usage on sequence cliques_id_seq to anon;
grant execute on function proximo_grupo(text) to anon;

-- Conferência: deve aparecer "banco pronto"
select 'banco pronto' as resultado;
