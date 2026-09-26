#!/usr/bin/env bash
# Deploy NousResearch/hermes-agent to a Coolify-managed VPS.
# Unofficial, not affiliated with Nous Research. Based on the community
# script hermes-agent-coolify-deploy; changes vs. the original:
#   - --ssh-key/--ssh-port; auth errors are reported instead of silently
#     deleting the known_hosts entry (that only happens on a changed host key)
#   - Coolify token via env COOLIFY_TOKEN or hidden prompt (not in shell history)
#   - --coolify-url for instances behind a domain instead of http://IP:8000
#   - --mode cloudflare: publish via Cloudflare Tunnel -> Traefik (http only)
#   - existing project is reused, an existing service aborts instead of duplicating
#   - server picked by IP when Coolify manages several servers (--server-uuid)
#   - .env: only API_SERVER_* lines are replaced, provider keys survive re-runs;
#     an existing API_SERVER_KEY is kept
#   - --skip-build pulls the official image instead of building on the VPS
#   - every Coolify API call checks the HTTP status
#   - credentials are also stored on the VPS (chmod 600)
set -euo pipefail

for bin in curl python3 openssl ssh sed base64; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="tunnel"
INSTANCE="hermes"
VPS_IP=""
COOLIFY_TOKEN="${COOLIFY_TOKEN:-}"
COOLIFY_PORT="8000"
COOLIFY_BASE=""
SERVER_UUID=""
GATEWAY_DOMAIN=""
DASHBOARD_DOMAIN=""
DASH_USER="hermes-admin"
SSH_USER="root"
SSH_PORT="22"
SSH_KEY=""
SKIP_BUILD=0

usage() {
  cat <<EOF
Usage: COOLIFY_TOKEN=... $0 --vps-ip IP [options]

Required:
  --vps-ip IP                  VPS IP address (SSH target)
  Coolify API token (root permission): env COOLIFY_TOKEN, --coolify-token,
  or a hidden prompt if neither is set.

Options:
  --mode tunnel|public|cloudflare
                               tunnel:     no public exposure, access via SSH port forward
                               public:     Traefik with Let's Encrypt + Basic Auth
                               cloudflare: via Cloudflare Tunnel (cloudflared -> localhost:80)
                               Default: tunnel
  --gateway-domain DOMAIN      Required for public/cloudflare
  --dashboard-domain DOMAIN    Required for public/cloudflare
  --instance NAME              Coolify project/container prefix. Default: hermes
  --coolify-url URL            e.g. https://coolify.example.com (default http://IP:8000)
  --coolify-port PORT          Only without --coolify-url. Default: 8000
  --server-uuid UUID           Coolify server, if the IP does not identify it
  --dash-user NAME             Dashboard user. Default: hermes-admin
  --ssh-user USER              Default: root
  --ssh-port PORT              Default: 22
  --ssh-key PATH               Private key (default: ~/.ssh/hermes_deploy if present,
                               otherwise ssh defaults / ~/.ssh/config)
  --skip-build                 Pull nousresearch/hermes-agent:latest instead of building
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vps-ip) VPS_IP="$2"; shift 2 ;;
    --coolify-token) COOLIFY_TOKEN="$2"; shift 2
      echo "Hinweis: Token als Argument landet in der Shell-History. Besser: export COOLIFY_TOKEN=..." >&2 ;;
    --coolify-url) COOLIFY_BASE="${2%/}"; shift 2 ;;
    --coolify-port) COOLIFY_PORT="$2"; shift 2 ;;
    --server-uuid) SERVER_UUID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --instance) INSTANCE="$2"; shift 2 ;;
    --gateway-domain) GATEWAY_DOMAIN="$2"; shift 2 ;;
    --dashboard-domain) DASHBOARD_DOMAIN="$2"; shift 2 ;;
    --dash-user) DASH_USER="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

[[ -z "$VPS_IP" ]] && usage
case "$MODE" in tunnel|public|cloudflare) ;; *) echo "Unknown --mode: $MODE"; usage ;; esac
if [[ "$MODE" != "tunnel" ]]; then
  if [[ -z "$GATEWAY_DOMAIN" || -z "$DASHBOARD_DOMAIN" ]]; then
    echo "--mode $MODE requires --gateway-domain and --dashboard-domain"; exit 1
  fi
  if [[ "$GATEWAY_DOMAIN$DASHBOARD_DOMAIN" == *yourdomain.com* || "$GATEWAY_DOMAIN$DASHBOARD_DOMAIN" == *example.com* ]]; then
    echo "Die Domains sind noch Platzhalter (yourdomain.com/example.com) - bitte echte Subdomains angeben."; exit 1
  fi
fi
[[ "$INSTANCE" =~ ^[a-z0-9-]+$ ]] || { echo "--instance: nur a-z, 0-9 und -"; exit 1; }

if [[ -z "$COOLIFY_TOKEN" ]]; then
  read -rsp "Coolify API token: " COOLIFY_TOKEN; echo
  [[ -z "$COOLIFY_TOKEN" ]] && { echo "Kein Token angegeben."; exit 1; }
fi

if [[ -z "$SSH_KEY" && -f "$HOME/.ssh/hermes_deploy" ]]; then
  SSH_KEY="$HOME/.ssh/hermes_deploy"
fi

COOLIFY_URL="${COOLIFY_BASE:-http://${VPS_IP}:${COOLIFY_PORT}}/api/v1"
DATA_DIR="/data/${INSTANCE}-shared/.hermes"
CRED_FILE="/root/${INSTANCE}-credentials.txt"

SSH_OPTS=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
rssh() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${VPS_IP}" "$@"; }

log() { echo -e "\n=== $1 ==="; }

# Coolify API call with status check. Usage: api METHOD PATH [JSON]
api() {
  local method="$1" path="$2" data="${3:-}" resp code
  local args=(-sS -X "$method" -H "Authorization: Bearer ${COOLIFY_TOKEN}" -H "Accept: application/json"
              -w $'\n%{http_code}')
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data "$data")
  resp=$(curl "${args[@]}" "${COOLIFY_URL}${path}") || { echo "Coolify nicht erreichbar: ${COOLIFY_URL}${path}" >&2; return 1; }
  code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"
  if (( code >= 400 )); then
    echo "Coolify API ${method} ${path} -> HTTP ${code}: ${resp}" >&2
    return 1
  fi
  printf '%s' "$resp"
}

# JSON helper: jq-light via python. Usage: echo "$json" | jpy 'expression using d'
jpy() { python3 -c "import json,sys; d=json.load(sys.stdin); r=($1); print('' if r is None else r)"; }

# ---------------------------------------------------------------------------
log "1/9 SSH"
if ! SSH_ERR=$(rssh 'echo ok' 2>&1 >/dev/null); then
  if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" <<<"$SSH_ERR"; then
    echo "Host-Key des VPS hat sich geaendert (z. B. IP neu vergeben). Entferne alten Eintrag und versuche erneut..."
    ssh-keygen -R "$VPS_IP" >/dev/null 2>&1 || true
    ssh-keygen -R "[${VPS_IP}]:${SSH_PORT}" >/dev/null 2>&1 || true
    rssh 'echo ok' >/dev/null
  elif grep -q "Permission denied" <<<"$SSH_ERR"; then
    echo "SSH-Anmeldung abgelehnt: ${SSH_ERR}"
    echo "Der Server kennt keinen der angebotenen Schluessel${SSH_KEY:+ (verwendet: $SSH_KEY)}."
    echo "Pruefen:  ssh ${SSH_KEY:+-i $SSH_KEY }-p $SSH_PORT ${SSH_USER}@${VPS_IP} true"
    echo "Anderen Schluessel angeben mit --ssh-key PATH."
    exit 1
  else
    echo "SSH fehlgeschlagen: ${SSH_ERR}"; exit 1
  fi
fi
rssh 'command -v docker >/dev/null' || { echo "docker fehlt auf dem VPS."; exit 1; }
echo "SSH OK${SSH_KEY:+ (Schluessel: $SSH_KEY)}"

# ---------------------------------------------------------------------------
log "2/9 Coolify API token + server"
SERVERS_JSON=$(api GET /servers) || { echo "Token-Pruefung fehlgeschlagen (Token braucht root-Rechte)."; exit 1; }
if [[ -z "$SERVER_UUID" ]]; then
  SERVER_UUID=$(echo "$SERVERS_JSON" | python3 -c '
import json, sys
servers = json.load(sys.stdin)
ip = sys.argv[1]
if len(servers) == 1:
    print(servers[0]["uuid"])
else:
    hits = [s for s in servers if s.get("ip") == ip] or \
           [s for s in servers if s.get("ip") in ("host.docker.internal", "localhost", "127.0.0.1")]
    print(hits[0]["uuid"] if len(hits) == 1 else "")
' "$VPS_IP")
fi
if [[ -z "$SERVER_UUID" ]]; then
  echo "Server nicht eindeutig. Verfuegbar:"
  echo "$SERVERS_JSON" | python3 -c 'import json,sys; [print("  ", s["uuid"], s.get("name"), s.get("ip")) for s in json.load(sys.stdin)]'
  echo "Mit --server-uuid UUID angeben."; exit 1
fi
echo "Server UUID: $SERVER_UUID"

# ---------------------------------------------------------------------------
log "3/9 Coolify project"
PROJECT_UUID=$(api GET /projects | jpy "next((p['uuid'] for p in d if p.get('name') == '${INSTANCE}'), '')")
if [[ -n "$PROJECT_UUID" ]]; then
  echo "Projekt '${INSTANCE}' existiert bereits, wird wiederverwendet."
else
  PROJECT_UUID=$(api POST /projects "{\"name\":\"${INSTANCE}\",\"description\":\"Hermes Agent\"}" | jpy "d.get('uuid','')")
fi
[[ -z "$PROJECT_UUID" ]] && { echo "Projekt konnte nicht angelegt werden."; exit 1; }
ENV_UUID=$(api GET "/projects/${PROJECT_UUID}" | jpy "d['environments'][0]['uuid']")
echo "Project: $PROJECT_UUID / Environment: $ENV_UUID"

EXISTING_SERVICE=$(api GET /services | jpy "next((s['uuid'] for s in d if s.get('name') == '${INSTANCE}-agent'), '')")
if [[ -n "$EXISTING_SERVICE" ]]; then
  echo "Service '${INSTANCE}-agent' existiert bereits (UUID ${EXISTING_SERVICE})."
  echo "In Coolify loeschen oder mit anderem --instance erneut starten. Abbruch, um kein Duplikat anzulegen."
  exit 1
fi

# ---------------------------------------------------------------------------
if (( SKIP_BUILD )); then
  log "4/9 Pull official image"
  rssh "docker pull nousresearch/hermes-agent:latest && docker tag nousresearch/hermes-agent:latest hermes-agent:latest"
else
  log "4/9 Build image on VPS (bypasses Coolify's git-tracked Application on purpose)"
  rssh "rm -rf /root/${INSTANCE}-build && git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /root/${INSTANCE}-build"
  rssh "cd /root/${INSTANCE}-build && docker build -t hermes-agent:latest ."
fi
echo "Image hermes-agent:latest bereit."

# ---------------------------------------------------------------------------
log "5/9 Persistent data dir"
rssh "if [ -d '$DATA_DIR' ]; then echo 'data dir already exists, keeping it'; else mkdir -p '$DATA_DIR'; fi"

# ---------------------------------------------------------------------------
log "6/9 API server key + env"
API_KEY=$(rssh "grep -s '^API_SERVER_KEY=' '${DATA_DIR}/.env' | tail -1 | cut -d= -f2-" || true)
if [[ -n "$API_KEY" ]]; then
  echo "Vorhandenen API_SERVER_KEY beibehalten."
else
  API_KEY=$(openssl rand -hex 24)
fi
API_HOST="127.0.0.1"
[[ "$MODE" != "tunnel" ]] && API_HOST="0.0.0.0"
# Nur API_SERVER_*-Zeilen ersetzen - Provider-Keys aus "hermes setup" bleiben.
rssh "python3 - '${DATA_DIR}/.env' '${API_HOST}' '${API_KEY}'" <<'PYEOF'
import os, sys
path, host, key = sys.argv[1:4]
lines = []
if os.path.exists(path):
    with open(path) as f:
        lines = [l for l in f.read().splitlines() if not l.startswith("API_SERVER_")]
lines += ["API_SERVER_ENABLED=true", "API_SERVER_PORT=8642",
          f"API_SERVER_HOST={host}", f"API_SERVER_KEY={key}"]
with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(path, 0o600)
PYEOF
echo "API server env written."

# ---------------------------------------------------------------------------
log "7/9 Render compose + create Coolify Service"
TMP_COMPOSE=$(mktemp)
trap 'rm -f "$TMP_COMPOSE"' EXIT
DASH_PASS=""
case "$MODE" in
  tunnel)
    sed -e "s|__INSTANCE__|${INSTANCE}|g" -e "s|__DATA_DIR__|${DATA_DIR}|g" \
      "${SCRIPT_DIR}/compose.tunnel.yml.tmpl" > "$TMP_COMPOSE"
    ;;
  public)
    DASH_PASS=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)
    DASH_HASH=$(openssl passwd -apr1 "$DASH_PASS")
    DASH_HASH_ESCAPED=$(echo "$DASH_HASH" | sed 's/\$/\$\$/g')
    sed -e "s|__INSTANCE__|${INSTANCE}|g" \
        -e "s|__DATA_DIR__|${DATA_DIR}|g" \
        -e "s|__GATEWAY_DOMAIN__|${GATEWAY_DOMAIN}|g" \
        -e "s|__DASHBOARD_DOMAIN__|${DASHBOARD_DOMAIN}|g" \
        -e "s|__DASH_USER__|${DASH_USER}|g" \
        -e "s|__DASH_HASH_ESCAPED__|${DASH_HASH_ESCAPED}|g" \
        "${SCRIPT_DIR}/compose.public.yml.tmpl" > "$TMP_COMPOSE"
    ;;
  cloudflare)
    DASH_PASS=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)
    DASH_SECRET=$(openssl rand -hex 32)
    sed -e "s|__INSTANCE__|${INSTANCE}|g" \
        -e "s|__DATA_DIR__|${DATA_DIR}|g" \
        -e "s|__GATEWAY_DOMAIN__|${GATEWAY_DOMAIN}|g" \
        -e "s|__DASHBOARD_DOMAIN__|${DASHBOARD_DOMAIN}|g" \
        -e "s|__DASH_USER__|${DASH_USER}|g" \
        -e "s|__DASH_PASS__|${DASH_PASS}|g" \
        -e "s|__DASH_SECRET__|${DASH_SECRET}|g" \
        "${SCRIPT_DIR}/compose.cloudflare.yml.tmpl" > "$TMP_COMPOSE"
    ;;
esac

COMPOSE_B64=$(base64 < "$TMP_COMPOSE" | tr -d '\n')
SERVICE_JSON=$(python3 - "$INSTANCE" "$PROJECT_UUID" "$ENV_UUID" "$SERVER_UUID" "$COMPOSE_B64" <<'PYEOF'
import json, sys
instance, project_uuid, env_uuid, server_uuid, compose_b64 = sys.argv[1:6]
print(json.dumps({
    "name": f"{instance}-agent",
    "description": "Hermes Agent",
    "project_uuid": project_uuid,
    "environment_uuid": env_uuid,
    "server_uuid": server_uuid,
    "instant_deploy": False,
    "docker_compose_raw": compose_b64,
    "is_container_label_escape_enabled": False,
}))
PYEOF
)
SERVICE_UUID=$(api POST /services "$SERVICE_JSON" | jpy "d.get('uuid','')")
[[ -z "$SERVICE_UUID" ]] && { echo "Service creation failed."; exit 1; }
echo "Service UUID: $SERVICE_UUID"

# ---------------------------------------------------------------------------
case "$MODE" in
public)
  log "8/9 Dashboard's own auth (required in addition to Traefik Basic Auth)"
  echo "Starting service once so a gateway container exists to run the hash helper in..."
  api POST "/services/${SERVICE_UUID}/start" >/dev/null
  sleep 15
  GATEWAY_CONTAINER="gateway-${SERVICE_UUID}"
  DASH_HASH_NATIVE=$(rssh "docker exec ${GATEWAY_CONTAINER} python3 -c \"from plugins.dashboard_auth.basic import hash_password; print(hash_password('${DASH_PASS}'))\"" 2>/dev/null || true)
  if [[ -z "$DASH_HASH_NATIVE" ]]; then
    echo "WARNING: could not generate dashboard's native auth hash (container may not be up yet)."
    echo "Run manually: docker exec ${GATEWAY_CONTAINER} python3 -c \"from plugins.dashboard_auth.basic import hash_password; print(hash_password('YOUR_PASSWORD'))\""
    echo "Then append to ${DATA_DIR}/config.yaml:"
    echo "  dashboard:"
    echo "    basic_auth:"
    echo "      username: ${DASH_USER}"
    echo "      password_hash: '<hash>'"
    echo "...and: docker restart ${INSTANCE}-dashboard-${SERVICE_UUID}"
  else
    rssh "python3 - '${DATA_DIR}/config.yaml' '${DASH_USER}' '${DASH_HASH_NATIVE}'" <<'PYEOF'
import os, sys
path, user, pw_hash = sys.argv[1:4]
content = open(path).read() if os.path.exists(path) else ""
if "dashboard:" not in content:
    content = content.rstrip("\n") + f"\n\ndashboard:\n  basic_auth:\n    username: {user}\n    password_hash: '{pw_hash}'\n"
    with open(path, "w") as f:
        f.write(content)
    print("config.yaml updated")
else:
    print("dashboard: block already present, skipping (edit manually if needed)")
PYEOF
    echo "Reconciling Coolify's auto-generated HERMES_DASHBOARD_BASIC_AUTH_* env vars (env wins over config.yaml)..."
    api PATCH "/services/${SERVICE_UUID}/envs" "{\"key\":\"HERMES_DASHBOARD_BASIC_AUTH_USERNAME\",\"value\":\"${DASH_USER}\"}" >/dev/null || true
    api PATCH "/services/${SERVICE_UUID}/envs" "{\"key\":\"HERMES_DASHBOARD_BASIC_AUTH_PASSWORD\",\"value\":\"${DASH_PASS}\"}" >/dev/null || true
    api POST "/services/${SERVICE_UUID}/restart" >/dev/null
    sleep 10
    echo "Verifying real login (not just Traefik's separate Basic Auth layer)..."
    LOGIN_CHECK=$(curl -sk -u "${DASH_USER}:${DASH_PASS}" -X POST "https://${DASHBOARD_DOMAIN}/auth/password-login" \
      -H "Content-Type: application/json" \
      -d "{\"provider\":\"basic\",\"username\":\"${DASH_USER}\",\"password\":\"${DASH_PASS}\"}" \
      --max-time 10 || true)
    if echo "$LOGIN_CHECK" | grep -q '"ok":true'; then
      echo "Login verified OK."
    else
      echo "WARNING: login check did not return ok:true - response: $LOGIN_CHECK"
    fi
  fi
  ;;
cloudflare)
  log "8/9 Start service + trusted_proxies for Traefik"
  if ! rssh "docker ps --format '{{.Image}}' | grep -q cloudflare/cloudflared"; then
    echo "WARNING: kein laufender cloudflared-Container auf dem VPS gefunden."
    echo "  In Coolify: + New -> Service -> Cloudflared, CLOUDFLARE_TUNNEL_TOKEN setzen, deployen."
    echo "  Tunnel-Route in Cloudflare: Subdomain *, Service HTTP localhost:80."
  fi
  api POST "/services/${SERVICE_UUID}/start" >/dev/null
  echo "Warte auf config.yaml (max. 120 s)..."
  for _ in $(seq 1 24); do
    rssh "test -f '${DATA_DIR}/config.yaml'" && break
    sleep 5
  done
  COOLIFY_SUBNET=$(rssh "docker network inspect coolify -f '{{(index .IPAM.Config 0).Subnet}}'" 2>/dev/null || true)
  if [[ -z "$COOLIFY_SUBNET" ]]; then
    echo "WARNING: Subnetz des coolify-Netzes nicht ermittelt - trusted_proxies bitte von Hand setzen."
  elif ! rssh "test -f '${DATA_DIR}/config.yaml'"; then
    echo "WARNING: ${DATA_DIR}/config.yaml fehlt noch (Container gestartet?). Von Hand ergaenzen:"
    echo "  dashboard:"
    echo "    public_url: \"https://${DASHBOARD_DOMAIN}\""
    echo "    trusted_proxies: [\"${COOLIFY_SUBNET}\"]"
  else
    rssh "python3 - '${DATA_DIR}/config.yaml' '${DASHBOARD_DOMAIN}' '${COOLIFY_SUBNET}'" <<'PYEOF'
import sys
path, domain, subnet = sys.argv[1:4]
content = open(path).read()
if "\ndashboard:" in "\n" + content:
    print("dashboard: block already present - public_url/trusted_proxies bitte pruefen:")
    print(f"  public_url: \"https://{domain}\"\n  trusted_proxies: [\"{subnet}\"]")
else:
    content = content.rstrip("\n") + (
        f"\n\ndashboard:\n  public_url: \"https://{domain}\"\n"
        f"  trusted_proxies:\n    - \"{subnet}\"\n")
    with open(path, "w") as f:
        f.write(content)
    print(f"config.yaml updated (trusted_proxies {subnet})")
PYEOF
    api POST "/services/${SERVICE_UUID}/restart" >/dev/null
  fi
  ;;
tunnel)
  log "8/9 Starting service"
  api POST "/services/${SERVICE_UUID}/start" >/dev/null
  ;;
esac

# ---------------------------------------------------------------------------
log "9/9 Verification"
sleep 15
echo "Containers:"
rssh "docker ps --format '{{.Names}}\t{{.Status}}' | grep -E '${SERVICE_UUID}|${INSTANCE}-hermes'" || echo "  (not up yet, check manually)"
echo ""
if [[ "$MODE" == "tunnel" ]]; then
  echo "Connect with:"
  echo "  ssh -L 8642:localhost:8642 -p ${SSH_PORT} ${SSH_USER}@${VPS_IP}"
  echo "Then locally: hermes model -> custom endpoint -> http://localhost:8642/v1"
else
  echo "Gateway health:"
  curl -sk -o /dev/null -w "  HTTP:%{http_code}\n" --max-time 10 "https://${GATEWAY_DOMAIN}/health" || true
  echo "Dashboard (401 = Hermes-Login, 302/403 = Cloudflare Access davor):"
  curl -sk -o /dev/null -w "  HTTP:%{http_code}\n" --max-time 10 "https://${DASHBOARD_DOMAIN}/" || true
  echo ""
  echo "Gateway API:    https://${GATEWAY_DOMAIN}/v1"
  echo "Dashboard:      https://${DASHBOARD_DOMAIN}"
  if [[ "$MODE" == "cloudflare" ]]; then
    echo ""
    echo "Dringend: Cloudflare Zero Trust -> Access -> Applications -> Self-hosted fuer"
    echo "  ${DASHBOARD_DOMAIN} anlegen (nur eigene E-Mail). Die API-Domain NICHT dahinter,"
    echo "  sie ist per API_SERVER_KEY geschuetzt."
  fi
fi

log "CREDENTIALS"
CREDS="API_SERVER_KEY:   ${API_KEY}"
if [[ -n "$DASH_PASS" ]]; then
  CREDS+=$'\n'"Dashboard user:   ${DASH_USER}"$'\n'"Dashboard pass:   ${DASH_PASS}"
fi
echo "$CREDS"
rssh "umask 077 && cat > '${CRED_FILE}'" <<<"$CREDS" && echo "(auch gespeichert auf dem VPS: ${CRED_FILE}, chmod 600 - nach Uebernahme in den Passwort-Vault loeschen)"

log "Done"
echo "Project: ${INSTANCE} | Service: ${SERVICE_UUID} | Data dir: ${DATA_DIR}"
echo "Next: LLM-Provider einrichten - docker exec -it <gateway-container> hermes setup"
