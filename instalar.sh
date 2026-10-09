#!/usr/bin/env bash
# =====================================================================
#  ROBÔ DE OFERTAS · instalador
#  Uso (no servidor, como root):   bash instalar.sh
#  Pode rodar de novo quando quiser: guarda as respostas anteriores,
#  atualiza os programas e não apaga nada.
# =====================================================================
set -uo pipefail

VERDE='\033[1;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[1;31m'; AZUL='\033[1;36m'; NEGRITO='\033[1m'; FIM='\033[0m'
ok()    { echo -e "${VERDE}✔ $*${FIM}"; }
aviso() { echo -e "${AMARELO}⚠ $*${FIM}"; }
erro()  { echo -e "${VERMELHO}✖ $*${FIM}"; }
passo() { echo -e "\n${AZUL}━━ $* ━━${FIM}"; }
morrer(){ erro "$*"; exit 1; }

[ "$(id -u)" = "0" ] || morrer "Rode como administrador: sudo bash instalar.sh"
ORIGEM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/robo-ofertas
ENVF="$DEST/.env"
[ -f "$ORIGEM/site/index.html" ] || morrer "Não achei a pasta site/ ao lado do instalador. Rode de dentro da pasta robo-ofertas."
mkdir -p "$DEST"

echo -e "${NEGRITO}
  ╔══════════════════════════════════════════════╗
  ║        ROBÔ DE OFERTAS · INSTALADOR          ║
  ╚══════════════════════════════════════════════╝${FIM}
  Vou fazer algumas perguntas. Para manter a resposta que
  aparece entre [colchetes], é só apertar Enter.
"

# ---------- respostas anteriores ----------
declare -A V
if [ -f "$ENVF" ]; then
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_]+$ ]] || continue
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    V[$k]="$v"
  done < "$ENVF"
  ok "Achei uma instalação anterior. As respostas dela aparecem como padrão."
fi
val() { echo "${V[$1]:-}"; }

perguntar() {  # perguntar VAR "pergunta" "padrão" [secreto] [opcional]
  local var="$1" texto="$2" padrao="${V[$1]:-$3}" secreto="${4:-}" opcional="${5:-}" resp mostra
  while true; do
    if [ -n "$padrao" ]; then
      if [ "$secreto" = "s" ]; then mostra="${padrao:0:6}…"; else mostra="$padrao"; fi
      read -r -p "$(echo -e "${NEGRITO}$texto${FIM} [$mostra]: ")" resp
      resp="${resp:-$padrao}"
    else
      read -r -p "$(echo -e "${NEGRITO}$texto${FIM}: ")" resp
    fi
    resp="$(echo "$resp" | tr -d "\r'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$resp" ] || [ "$opcional" = "o" ]; then V[$var]="$resp"; return; fi
    aviso "Essa resposta é obrigatória."
  done
}

passo "1/8 · Suas informações"
echo "Domínio do site, sem https e sem www. Ex.: achadocerto.com.br"
perguntar DOMINIO "Domínio" ""
V[DOMINIO]="$(echo "${V[DOMINIO]}" | sed -E 's#^https?://##; s#^www\.##; s#/.*$##' | tr 'A-Z' 'a-z')"
echo "Outros domínios seus que devem levar para o site principal (ex.: a versão .com). Separe por espaço. Enter = nenhum."
perguntar DOMINIOS_EXTRA "Domínios extras" "" "" o
echo "O site fica hospedado no Netlify (ou outro serviço)? Responda sim para este servidor cuidar só dos robôs."
perguntar SITE_FORA "Site fora deste servidor? (sim/nao)" "nao"
V[SITE_FORA]="$(echo "${V[SITE_FORA]}" | tr 'A-Z' 'a-z')"
V[DOMINIOS_EXTRA]="$(echo "${V[DOMINIOS_EXTRA]}" | tr 'A-Z,' 'a-z ' | sed -E 's#https?://##g; s#www\.##g; s#/##g')"
perguntar NOME_MARCA "Nome da marca (aparece no site)" "Eh Meu Aí"
perguntar EMPRESA "Razão social e CNPJ para o rodapé (Enter para deixar em branco)" "" "" o

echo -e "\nSupabase → Project Settings → API (ou Data API / API Keys)"
perguntar SUPABASE_URL "Project URL (https://xxxx.supabase.co)" ""
V[SUPABASE_URL]="${V[SUPABASE_URL]%/}"
perguntar SUPABASE_ANON_KEY "Chave anon / publishable" "" s
perguntar SUPABASE_SERVICE_KEY "Chave service_role / secret" "" s

echo -e "\nAnthropic → console.anthropic.com → API Keys"
perguntar ANTHROPIC_API_KEY "Chave da API da Anthropic (sk-ant-...)" "" s

echo -e "\nTelegram → @BotFather → token do seu bot"
perguntar TELEGRAM_BOT_TOKEN "Token do bot (123456:ABC...)" "" s
echo "Canal público do Telegram, com @ (ex.: @achadocerto). Enter = sem canal por enquanto."
perguntar TELEGRAM_CANAL "Canal do Telegram" "" "" o

echo -e "\nOpcionais (Enter para pular; dá para preencher depois rodando o instalador de novo)"
perguntar AMAZON_TAG "Tag de associado da Amazon (ex.: seunome-20)" "" "" o
perguntar SHOPEE_APP_ID "Shopee Afiliados · App ID" "" "" o
perguntar SHOPEE_SECRET "Shopee Afiliados · Secret" "" s o
perguntar ML_NO_SITE "Esconder ofertas do Mercado Livre do site? (sim/nao)" "nao"

# Gerados automaticamente (nunca mudam depois da primeira vez)
gera() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
V[N8N_ENCRYPTION_KEY]="${V[N8N_ENCRYPTION_KEY]:-$(gera 24)}"
V[EVOLUTION_API_KEY]="${V[EVOLUTION_API_KEY]:-$(gera 20)}"
V[POSTGRES_PASSWORD]="${V[POSTGRES_PASSWORD]:-$(gera 16)}"
V[TELEGRAM_SECRET]="${V[TELEGRAM_SECRET]:-$(gera 16)}"
V[CLAUDE_MODEL]="${V[CLAUDE_MODEL]:-claude-haiku-4-5-20251001}"
V[LINK_NO_POST]="${V[LINK_NO_POST]:-afiliado}"
V[TELEGRAM_ADMIN_ID]="${V[TELEGRAM_ADMIN_ID]:-}"

passo "2/8 · Programas básicos"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl ca-certificates openssl python3 dnsutils >/dev/null 2>&1 || true
if ! command -v docker >/dev/null 2>&1; then
  echo "Instalando o Docker (leva 1 a 3 minutos)…"
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || morrer "Não consegui instalar o Docker. Confira se o servidor tem internet."
fi
docker compose version >/dev/null 2>&1 || morrer "O Docker Compose não está disponível. Use Ubuntu 22.04 ou 24.04."
ok "Docker pronto"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow OpenSSH >/dev/null; ok "Firewall liberado para o site (portas 80 e 443)"
fi

passo "3/8 · Conferindo suas chaves"
D="${V[DOMINIO]}"
AUTH=(); [[ "${V[SUPABASE_SERVICE_KEY]}" == eyJ* ]] && AUTH=(-H "Authorization: Bearer ${V[SUPABASE_SERVICE_KEY]}")
R=$(curl -s -o /dev/null -w "%{http_code}" "${V[SUPABASE_URL]}/rest/v1/ajustes?select=chave&limit=1" -H "apikey: ${V[SUPABASE_SERVICE_KEY]}" "${AUTH[@]}")
case "$R" in
  200) ok "Supabase: conectado e com o banco criado" ;;
  401|403) morrer "Supabase recusou a chave service_role. Copie de novo (Project Settings → API) e rode o instalador outra vez." ;;
  404) morrer "Supabase respondeu, mas o banco ainda não foi criado. Rode o arquivo banco.sql no SQL Editor (Etapa 2 do guia) e depois este instalador de novo." ;;
  *) morrer "Não consegui falar com o Supabase (código $R). Confira a Project URL: ${V[SUPABASE_URL]}" ;;
esac
BOT=$(curl -s "https://api.telegram.org/bot${V[TELEGRAM_BOT_TOKEN]}/getMe")
echo "$BOT" | grep -q '"ok":true' || morrer "O Telegram recusou o token do bot. Copie de novo no @BotFather."
BOTNOME=$(echo "$BOT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["username"])')
ok "Telegram: bot @$BOTNOME"
R=$(curl -s -o /dev/null -w "%{http_code}" https://api.anthropic.com/v1/messages -H "x-api-key: ${V[ANTHROPIC_API_KEY]}" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d '{"model":"'"${V[CLAUDE_MODEL]}"'","max_tokens":5,"messages":[{"role":"user","content":"oi"}]}')
case "$R" in
  200) ok "Anthropic: chave funcionando" ;;
  401) morrer "A Anthropic recusou a chave. Crie outra em console.anthropic.com → API Keys." ;;
  400|402|403) aviso "A Anthropic respondeu $R: confira se há créditos na conta (Billing). Sem créditos, os textos saem sem o gancho." ;;
  *) aviso "Não consegui testar a chave da Anthropic agora (código $R). Sigo assim mesmo." ;;
esac

passo "4/8 · Conferindo o domínio"
IP=$(curl -s -4 https://api.ipify.org || curl -s -4 ifconfig.me)
echo "IP deste servidor: $IP"
DNS_OK=1
EXTRAS=""; for x in ${V[DOMINIOS_EXTRA]:-}; do EXTRAS="$EXTRAS $x www.$x"; done
HOSTS=("$D" "www.$D" "n8n.$D" "evo.$D"); [ "${V[SITE_FORA]}" = "sim" ] && HOSTS=("n8n.$D" "evo.$D") && EXTRAS=""
for h in "${HOSTS[@]}" $EXTRAS; do
  A=$(dig +short A "$h" @1.1.1.1 | tail -1)
  if [ "$A" = "$IP" ]; then ok "$h → $A"; else aviso "$h aponta para '${A:-nada}' (deveria ser $IP)"; DNS_OK=0; fi
done
if [ "$DNS_OK" = "0" ]; then
  aviso "O DNS ainda não aponta para este servidor (Etapa 3 do guia). Pode levar até algumas horas para valer."
  read -r -p "Continuar mesmo assim? Os certificados HTTPS saem sozinhos quando o DNS ficar certo. (s/n) [s]: " c
  [ "${c:-s}" = "n" ] && exit 1
fi

passo "5/8 · Gravando a configuração"
umask 077
{
  echo "# Robô de Ofertas · gerado pelo instalador em $(date '+%d/%m/%Y %H:%M')"
  for k in DOMINIO DOMINIOS_EXTRA SITE_FORA NOME_MARCA EMPRESA SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY ANTHROPIC_API_KEY CLAUDE_MODEL \
           TELEGRAM_BOT_TOKEN TELEGRAM_CANAL TELEGRAM_ADMIN_ID TELEGRAM_SECRET AMAZON_TAG SHOPEE_APP_ID SHOPEE_SECRET \
           ML_NO_SITE LINK_NO_POST N8N_ENCRYPTION_KEY EVOLUTION_API_KEY POSTGRES_PASSWORD; do
    printf "%s='%s'\n" "$k" "${V[$k]:-}"
  done
} > "$ENVF"
chmod 600 "$ENVF"
umask 022

cat > "$DEST/Caddyfile" <<'EOF'
{$DOMINIO}, www.{$DOMINIO} {
	root * /srv/site
	encode gzip
	file_server
}
n8n.{$DOMINIO} {
	reverse_proxy n8n:5678
}
evo.{$DOMINIO} {
	reverse_proxy evolution:8080
}
EOF
for x in ${V[DOMINIOS_EXTRA]:-}; do
  printf '%s, www.%s {\n\tredir https://%s{uri} permanent\n}\n' "$x" "$x" "$D" >> "$DEST/Caddyfile"
done
if [ "${V[SITE_FORA]}" = "sim" ]; then
  printf 'n8n.{$DOMINIO} {\n\treverse_proxy n8n:5678\n}\nevo.{$DOMINIO} {\n\treverse_proxy evolution:8080\n}\n' > "$DEST/Caddyfile"
fi

cat > "$DEST/docker-compose.yml" <<'EOF'
name: robo-ofertas
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      DOMINIO: ${DOMINIO}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv/site:ro
      - caddy_data:/data
      - caddy_config:/config
  n8n:
    image: n8nio/n8n:stable
    restart: unless-stopped
    env_file: .env
    environment:
      N8N_HOST: n8n.${DOMINIO}
      N8N_PROTOCOL: https
      N8N_PORT: "5678"
      WEBHOOK_URL: https://n8n.${DOMINIO}/
      N8N_PROXY_HOPS: "1"
      GENERIC_TIMEZONE: America/Sao_Paulo
      TZ: America/Sao_Paulo
      N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"
      NODE_FUNCTION_ALLOW_BUILTIN: crypto
      N8N_RUNNERS_ENABLED: "true"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "168"
      EVOLUTION_URL: http://evolution:8080
      EVOLUTION_PUBLIC_URL: https://evo.${DOMINIO}
      ESCUTA_WEBHOOK_URL: http://n8n:5678/webhook/escuta-ofertas
      SITE_URL: https://${DOMINIO}
    volumes:
      - n8n_data:/home/node/.n8n
  evolution:
    image: evoapicloud/evolution-api:v2.3.4
    restart: unless-stopped
    depends_on: [postgres, redis]
    ports: ["127.0.0.1:8080:8080"]
    environment:
      SERVER_URL: https://evo.${DOMINIO}
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://evolution:${POSTGRES_PASSWORD}@postgres:5432/evolution?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: evolution
      DATABASE_SAVE_DATA_INSTANCE: "true"
      DATABASE_SAVE_DATA_NEW_MESSAGE: "false"
      DATABASE_SAVE_MESSAGE_UPDATE: "false"
      DATABASE_SAVE_DATA_CONTACTS: "false"
      DATABASE_SAVE_DATA_CHATS: "false"
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://redis:6379/6
      CACHE_REDIS_PREFIX_KEY: evolution
      CACHE_LOCAL_ENABLED: "false"
      DEL_INSTANCE: "false"
      LANGUAGE: pt-BR
    volumes:
      - evolution_instances:/evolution/instances
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: evolution
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: evolution
    volumes:
      - pg_data:/var/lib/postgresql/data
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
volumes:
  caddy_data:
  caddy_config:
  n8n_data:
  evolution_instances:
  pg_data:
  redis_data:
EOF

# Site com as suas chaves
rm -rf "$DEST/site"; cp -r "$ORIGEM/site" "$DEST/site"
python3 - "$DEST/site" <<'PY'
import sys, json, os, re, html
pasta = sys.argv[1]
env = {}
for linha in open('/opt/robo-ofertas/.env', encoding='utf-8'):
    m = re.match(r'''^([A-Z_]+)=['"](.*)['"]$''', linha.strip())
    if m: env[m.group(1)] = m.group(2)
j = lambda v: json.dumps(v, ensure_ascii=False)
canal = env.get('TELEGRAM_CANAL', '').lstrip('@')
tg = f'https://t.me/{canal}' if canal else ''
p = os.path.join(pasta, 'index.html'); s = open(p, encoding='utf-8').read()
troca = {
  r'nome: "[^"]*",': f'nome: {j(env.get("NOME_MARCA","Ofertas"))},',
  r'supabaseUrl: "[^"]*",': f'supabaseUrl: {j(env["SUPABASE_URL"])},',
  r'supabaseAnonKey: "[^"]*",': f'supabaseAnonKey: {j(env["SUPABASE_ANON_KEY"])},',
  r'linkWhatsApp: "[^"]*",': 'linkWhatsApp: "entrar.html?canal=whatsapp&src=site",',
  r'linkTelegram: "[^"]*",': f'linkTelegram: {j(tg)},',
  r'rotacaoGrupos: (true|false),': 'rotacaoGrupos: false,',
  r'empresa: "[^"]*",': f'empresa: {j(env.get("EMPRESA",""))},',
}
for a, b in troca.items(): s = re.sub(a, lambda m: b, s, count=1)
nome = env.get("NOME_MARCA", "Ofertas")
s = re.sub(r'<title>[^<]*</title>', lambda m: f'<title>{html.escape(nome)}</title>', s, count=1)
s = re.sub(r'(<meta property="og:title" content=")[^"]*', lambda m: m.group(1) + html.escape(nome), s, count=1)
open(p, 'w', encoding='utf-8').write(s)
p = os.path.join(pasta, 'entrar.html'); s = open(p, encoding='utf-8').read()
s = re.sub(r'const SUPABASE_URL = "[^"]*";', lambda m: f'const SUPABASE_URL = {j(env["SUPABASE_URL"])};', s, count=1)
s = re.sub(r'const SUPABASE_ANON = "[^"]*";', lambda m: f'const SUPABASE_ANON = {j(env["SUPABASE_ANON_KEY"])};', s, count=1)
s = re.sub(r'const FALLBACK = \{[^}]*\};', lambda m: f'const FALLBACK = {{ whatsapp: "/", telegram: {j(tg or "/")} }};', s, count=1)
open(p, 'w', encoding='utf-8').write(s)
print("site configurado")
PY
cp "$ORIGEM/banco.sql" "$DEST/" 2>/dev/null || true
mkdir -p "$DEST/workflows"; cp "$ORIGEM"/workflows/*.json "$DEST/workflows/" 2>/dev/null || true
ok "Configuração gravada em $DEST"

passo "6/8 · Ligando tudo (na primeira vez leva de 3 a 8 minutos)"
cd "$DEST" || morrer "Não achei $DEST"
docker compose pull -q || morrer "Não consegui baixar os programas. Confira a internet do servidor."
docker compose up -d --remove-orphans || morrer "Algo falhou ao ligar. Rode: cd $DEST && docker compose logs --tail 50"
echo -n "Esperando a Evolution (WhatsApp) responder"
for i in $(seq 1 90); do
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/ | grep -qE "200|404" && break
  echo -n "."; sleep 4
done; echo
curl -s -o /dev/null http://127.0.0.1:8080/ && ok "Evolution no ar" || aviso "A Evolution ainda está subindo. Se o bot reclamar, espere 2 minutos."

passo "7/8 · Preparando WhatsApp e Telegram"
EK="${V[EVOLUTION_API_KEY]}"
for inst in postagem escuta; do
  R=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8080/instance/create -H "apikey: $EK" -H "Content-Type: application/json" \
      -d '{"instanceName":"'"$inst"'","integration":"WHATSAPP-BAILEYS","qrcode":false}')
  case "$R" in 200|201) ok "Instância do WhatsApp criada: $inst" ;; 403|409|400) ok "Instância do WhatsApp já existia: $inst" ;; *) aviso "Instância $inst: resposta $R (o bot tenta de novo no /conectar)" ;; esac
done
R=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8080/webhook/set/escuta -H "apikey: $EK" -H "Content-Type: application/json" \
  -d '{"webhook":{"enabled":true,"url":"http://n8n:5678/webhook/escuta-ofertas","byEvents":false,"base64":false,"events":["MESSAGES_UPSERT"]}}')
case "$R" in 200|201) ok "Chip de escuta ligado ao robô" ;; *) aviso "Não consegui ligar o chip de escuta ao robô agora (código $R). O bot refaz isso no /conectar escuta." ;; esac
TG="https://api.telegram.org/bot${V[TELEGRAM_BOT_TOKEN]}"
curl -s -X POST "$TG/setWebhook" -H "Content-Type: application/json" \
  -d '{"url":"https://n8n.'"$D"'/webhook/telegram-bot","secret_token":"'"${V[TELEGRAM_SECRET]}"'","allowed_updates":["message","callback_query"],"drop_pending_updates":true}' \
  | grep -q '"ok":true' && ok "Telegram apontado para o robô" || aviso "O Telegram não aceitou o endereço ainda (normal se o HTTPS não saiu). Rode o instalador de novo depois que o site abrir."
curl -s -X POST "$TG/setMyCommands" -H "Content-Type: application/json" -d '{"commands":[
 {"command":"status","description":"Como está tudo"},
 {"command":"ajuda","description":"Como usar o robô"},
 {"command":"conectar","description":"Ligar um chip: /conectar postagem 5521..."},
 {"command":"grupos","description":"Listar grupos: /grupos postagem ou escuta"},
 {"command":"destino","description":"Escolher o grupo que recebe as ofertas"},
 {"command":"fonte","description":"Ligar/desligar um grupo como fonte"},
 {"command":"convite","description":"Link de entrada usado no site"},
 {"command":"teste","description":"Mensagem de teste no grupo"},
 {"command":"shopee","description":"auto, previa ou desliga"},
 {"command":"palavras","description":"O que a Shopee automática procura"}]}' >/dev/null

passo "8/8 · Conferindo o HTTPS"
echo -n "Esperando os certificados"
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "%{http_code}" "https://n8n.$D/healthz" 2>/dev/null | grep -q 200 && break
  echo -n "."; sleep 5
done; echo
URLS=("https://$D" "https://n8n.$D/healthz" "https://evo.$D"); [ "${V[SITE_FORA]}" = "sim" ] && URLS=("https://n8n.$D/healthz" "https://evo.$D")
for u in "${URLS[@]}"; do
  C=$(curl -s -o /dev/null -w "%{http_code}" "$u")
  [[ "$C" =~ ^(200|301|302|404)$ ]] && ok "$u no ar" || aviso "$u ainda não respondeu (código $C). Se o DNS acabou de mudar, espere e rode o instalador de novo."
done

cat > "$DEST/RESUMO.txt" <<EOF
ROBÔ DE OFERTAS · RESUMO DA INSTALAÇÃO ($(date '+%d/%m/%Y %H:%M'))

Site:              https://$D
n8n (robôs):       https://n8n.$D
Evolution Manager: https://evo.$D/manager
Chave da Evolution (para o Manager): ${V[EVOLUTION_API_KEY]}
Bot do Telegram:   https://t.me/$BOTNOME

Arquivos:          $DEST
Configuração:      $DEST/.env (não compartilhe)
Workflows:         $DEST/workflows (os mesmos que você vai importar)

Comandos úteis no servidor:
  cd $DEST && docker compose ps            # ver se está tudo ligado
  cd $DEST && docker compose logs --tail 80 n8n
  cd $DEST && docker compose restart       # reiniciar tudo
  bash instalar.sh                         # atualizar / mudar respostas
EOF
chmod 600 "$DEST/RESUMO.txt"

echo -e "
${VERDE}${NEGRITO}══════════════ INSTALAÇÃO CONCLUÍDA ══════════════${FIM}
${NEGRITO}Próximos passos (guia, Etapas 6 a 8):${FIM}
 1. Abra ${NEGRITO}https://n8n.$D${FIM} e crie sua conta de dono.
 2. Importe os 3 arquivos da pasta workflows/ e publique/ative cada um.
 3. No Telegram, abra ${NEGRITO}https://t.me/$BOTNOME${FIM} e mande ${NEGRITO}/start${FIM}.
 4. Depois: /conectar postagem 55DDDNUMERO  e  /conectar escuta 55DDDNUMERO

Resumo salvo em: ${NEGRITO}$DEST/RESUMO.txt${FIM}  (veja com: cat $DEST/RESUMO.txt)
"
