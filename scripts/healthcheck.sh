#!/usr/bin/env bash
# Usage: healthcheck.sh [timeout_seconds] [--local]
# Waits until every service is running (and healthy, where the image has a healthcheck), then
# checks Harbor's own component health through nginx and, unless --local, the public URL.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root status
load_env

timeout=60 local_only=0
for arg in "$@"; do
  case "${arg}" in
    --local) local_only=1 ;;
    ''|*[!0-9]*) die "usage: $0 [timeout_seconds] [--local]" ;;
    *) timeout="${arg}" ;;
  esac
done

# Prints the services that are not ready yet.
not_ready() {
  local svc state health status
  status="$(compose ps -a --format '{{.Service}} {{.State}} {{.Health}}')"
  for svc in $(expected_services); do
    state="" health=""
    read -r state health < <(awk -v s="${svc}" '$1 == s { print $2, $3 }' <<<"${status}") || true
    if [[ "${state:-missing}" != "running" || ( -n "${health:-}" && "${health}" != "healthy" ) ]]; then
      echo "${svc}(${state:-missing}${health:+/${health}})"
    fi
  done
}

deadline=$((SECONDS + timeout))
while pending="$(not_ready)"; [[ -n "${pending}" ]]; do
  ((SECONDS < deadline)) || { compose ps -a; die "not ready after ${timeout}s: ${pending//$'\n'/ }"; }
  sleep 5
done
log "all services running and healthy"

# /api/v2.0/health reports database, redis, registry, jobservice, trivy, ... individually.
# Asked from core itself: with TLS the proxy's :8080 only redirects to https.
while :; do
  health="$(compose exec -T core curl -fsS http://127.0.0.1:8080/api/v2.0/health 2>/dev/null || true)"
  [[ "${health}" == *'"status":"healthy"'* ]] && break
  if ((SECONDS >= deadline)); then
    unhealthy="$(grep -o '"name":"[a-z_-]*","status":"unhealthy"' <<<"${health}" | cut -d'"' -f4 | paste -sd' ' || true)"
    die "Harbor reports unhealthy components: ${unhealthy:-unknown (${health:-no answer from /api/v2.0/health})}"
  fi
  sleep 5
done
log "harbor: all components healthy"

if ((local_only == 0)); then
  url="$(public_url)"
  # /v2/ must answer 401 with a token realm on the public URL, otherwise `docker login` fails.
  curl_opts=(-s -o /dev/null -w '%{http_code}' --max-time 15)
  # A self-signed TLS_CERT should not hide a working route; the docker client checks trust itself.
  [[ "${PROXY_MODE}" == "standalone" && -n "${TLS_CERT:-}" ]] && curl_opts+=(-k)
  if code="$(curl "${curl_opts[@]}" "${url}/v2/")" && [[ "${code}" == "401" ]]; then
    log "${url}/v2/ -> HTTP 401 (registry auth OK)"
  else
    warn "${url}/v2/ answered HTTP ${code:-none} (expected 401); check DNS, TLS and the proxy route"
  fi
fi
