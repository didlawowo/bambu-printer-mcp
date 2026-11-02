#!/usr/bin/env bash
# Local install of this fork as a Claude Code MCP server.
# Configuration lives in <repo>/.env (git-ignored, read by dotenv at startup).
#
# Usage: scripts/local-mcp.sh <init|check|register|run> [--dry-run]
#   init      create .env from .env.example (mode 600) if it does not exist
#   check     validate .env, test printer ports 8883/990 and the MCP handshake
#   register  (re)register the "bambu" server in Claude Code, user scope
#   run       start the server on stdio (command used by Claude Code)
#
# Overridable: NODE_VERSION (24.22.2), NODE_BIN, MCP_NAME (bambu), MCP_SCOPE (user)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
NODE_VERSION="${NODE_VERSION:-24.22.2}"
MCP_NAME="${MCP_NAME:-bambu}"
MCP_SCOPE="${MCP_SCOPE:-user}"
SELF="$REPO_DIR/scripts/local-mcp.sh"

# stdout is reserved for MCP messages in "run": every message goes to stderr.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_STEP=$'\033[36m'; C_END=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_STEP=""; C_END=""
fi
ok()   { echo "${C_OK}OK: $*${C_END}" >&2; }
err()  { echo "${C_ERR}ERREUR: $*${C_END}" >&2; }
warn() { echo "${C_WARN}WARN: $*${C_END}" >&2; }
step() { echo "${C_STEP}==> $*${C_END}" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,12p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

resolve_node() {
  if [ -n "${NODE_BIN:-}" ]; then echo "$NODE_BIN"; return; fi
  local dir
  dir="$(mise where "node@$NODE_VERSION" 2>/dev/null)" \
    || die "node $NODE_VERSION introuvable : mise install node@$NODE_VERSION"
  echo "$dir/bin/node"
}

env_value() { # last assignment of $1 in .env, quotes stripped
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
}

cmd_init() {
  local dry="$1"
  if [ -f "$ENV_FILE" ]; then ok ".env existe déjà : $ENV_FILE"; return; fi
  if [ "$dry" = 1 ]; then warn "dry-run : copierait .env.example vers .env (mode 600), BAMBU_MODEL=p1s"; return; fi
  ( umask 077; sed 's/^BAMBU_MODEL=$/BAMBU_MODEL=p1s/' "$REPO_DIR/.env.example" > "$ENV_FILE" )
  ok ".env créé : $ENV_FILE"
  warn "renseigner PRINTER_HOST, BAMBU_SERIAL et BAMBU_TOKEN (écran de l'imprimante)"
}

validate_env() {
  [ -f "$ENV_FILE" ] || die ".env absent : task mcp:init"
  local bad=0 v val
  for v in PRINTER_HOST BAMBU_SERIAL BAMBU_TOKEN BAMBU_MODEL; do
    val="$(env_value "$v")"
    case "$val" in
      ""|192.168.1.100|your_serial_number|your_lan_access_code|TON_*|"<"*)
        err "$v non renseigné dans .env"; bad=1 ;;
    esac
  done
  [ "$bad" = 0 ] || exit 1
  ok ".env complet (modèle $(env_value BAMBU_MODEL))"
}

cmd_check() {
  local node host port handshake
  step "Configuration"
  validate_env
  [ "$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE")" = 600 ] \
    || warn ".env lisible par d'autres comptes : chmod 600 $ENV_FILE"
  step "Node et build"
  node="$(resolve_node)"; [ -x "$node" ] || die "node absent : $node"
  ok "node $("$node" --version)"
  [ -f "$REPO_DIR/dist/index.js" ] || die "dist/index.js absent : task install"
  step "Imprimante"
  host="$(env_value PRINTER_HOST)"
  for port in 8883 990; do
    if nc -z -G 3 "$host" "$port" 2>/dev/null || nc -z -w 3 "$host" "$port" 2>/dev/null; then
      ok "$host:$port joignable"
    else
      err "$host:$port injoignable (imprimante allumée, mode LAN actif, même réseau ?)"; return 1
    fi
  done
  step "Handshake MCP"
  handshake="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
    | (cd "$REPO_DIR" && MCP_TRANSPORT=stdio timeout 15 "$node" dist/index.js 2>/dev/null) | head -n1 || true)"
  case "$handshake" in
    *'"serverInfo"'*) ok "serveur MCP opérationnel" ;;
    *) die "pas de réponse MCP au handshake" ;;
  esac
}

cmd_register() {
  local dry="$1"
  command -v claude >/dev/null || die "CLI claude introuvable"
  validate_env
  if [ "$dry" = 1 ]; then
    warn "dry-run : claude mcp remove $MCP_NAME -s $MCP_SCOPE (si présent)"
    warn "dry-run : claude mcp add $MCP_NAME --scope $MCP_SCOPE -- $SELF run"
    return
  fi
  claude mcp remove "$MCP_NAME" -s "$MCP_SCOPE" >/dev/null 2>&1 || true
  claude mcp add "$MCP_NAME" --scope "$MCP_SCOPE" -- "$SELF" run >/dev/null
  ok "serveur MCP « $MCP_NAME » enregistré ($MCP_SCOPE) : $SELF run"
  warn "il sera chargé à la prochaine session Claude Code"
}

cmd_run() {
  local node
  [ -f "$ENV_FILE" ] || die ".env absent : task mcp:init"
  node="$(resolve_node)"
  cd "$REPO_DIR"
  export MCP_TRANSPORT=stdio
  exec "$node" dist/index.js
}

[ $# -ge 1 ] || usage
action="$1"; shift
dry=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    *) err "option inconnue : $arg"; usage ;;
  esac
done
case "$action" in
  init) cmd_init "$dry" ;;
  check) cmd_check ;;
  register) cmd_register "$dry" ;;
  run) cmd_run ;;
  *) usage ;;
esac
