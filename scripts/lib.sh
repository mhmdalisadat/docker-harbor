#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
set -eEuo pipefail
trap 'echo "[harbor] ERROR: exit $? at $(basename "${BASH_SOURCE[0]:-$0}"):${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
HARBOR_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/upstream/VERSION")"

log()  { echo "[harbor] $*"; }
warn() { echo "[harbor] WARNING: $*" >&2; }
die()  { echo "[harbor] ERROR: $*" >&2; exit 1; }

compose() { (cd "${ROOT_DIR}" && docker compose "$@"); }

# prepare writes root-only files (common/config/*/env, 0640 root) that compose has to read.
require_root() {
  [[ "$(id -u)" == 0 ]] || die "run as root (e.g. sudo make $1): Harbor's generated config files are readable by root only"
}

abs_path() {
  case "$1" in
    /*) echo "$1" ;;
    *)  echo "${ROOT_DIR}/${1#./}" ;;
  esac
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found — run: make init, then edit it"
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
  DATA_PATH="$(abs_path "${DATA_DIR:=./data}")"
  LOG_PATH="$(abs_path "${LOG_DIR:=./logs}")"
  BACKUP_DIR="$(abs_path "${BACKUP_DIR:=./backups}")"
  PREPARE_IMAGE="${HARBOR_IMAGE_REGISTRY:-}goharbor/prepare:${HARBOR_VERSION}"
}

# Set KEY=VALUE in .env in place (appended if missing); comments and order are preserved.
env_set() {
  local key="$1" value="$2" tmp
  [[ "${value}" =~ ^[A-Za-z0-9._:/,@+-]*$ ]] || die "refusing to write unsafe value for ${key}"
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    awk -v k="${key}" -v v="${value}" 'index($0, k "=") == 1 && !done { print k "=" v; done = 1; next } { print }' \
      "${ENV_FILE}" > "${tmp}"
  else
    { cat "${ENV_FILE}"; printf '%s=%s\n' "${key}" "${value}"; } > "${tmp}"
  fi
  chmod 600 "${tmp}"
  mv "${tmp}" "${ENV_FILE}"
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
}

gen_secret() { openssl rand -hex 24; }

is_true() { [[ "${1:-0}" =~ ^(1|true|yes)$ ]]; }

# URL clients use to reach Harbor.
public_url() {
  if [[ -n "${EXTERNAL_URL:-}" ]]; then
    echo "${EXTERNAL_URL%/}"
  elif [[ "${PROXY_MODE}" == "traefik" || -n "${TLS_CERT:-}" ]]; then
    local port="${HTTPS_PORT:-443}"
    [[ "${PROXY_MODE}" == "traefik" || "${port}" == "443" ]] && echo "https://${HARBOR_HOSTNAME}" || echo "https://${HARBOR_HOSTNAME}:${port}"
  else
    [[ "${HTTP_PORT:-80}" == "80" ]] && echo "http://${HARBOR_HOSTNAME}" || echo "http://${HARBOR_HOSTNAME}:${HTTP_PORT}"
  fi
}

# Services the generated docker-compose.yml defines for the current settings.
expected_services() {
  local svc=(log registry registryctl postgresql core portal jobservice redis proxy)
  is_true "${ENABLE_TRIVY:-0}" && svc+=(trivy-adapter)
  is_true "${ENABLE_METRICS:-0}" && svc+=(exporter)
  echo "${svc[@]}"
}
