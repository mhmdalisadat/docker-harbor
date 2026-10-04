#!/usr/bin/env bash
# Deploy or update: setup (prepare when needed), pull images, `compose up --wait`, healthcheck.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bash "${ROOT_DIR}/scripts/setup.sh" "$@"
load_env

if [[ "${PROXY_MODE}" == "traefik" ]]; then
  net="$(docker network inspect -f '{{.Driver}} {{.Attachable}}' "${TRAEFIK_NETWORK}" 2>/dev/null)" \
    || die "docker network '${TRAEFIK_NETWORK}' not found — is Traefik running on this host / is this node in its swarm?"
  [[ "${net}" != "overlay false" ]] \
    || die "overlay network '${TRAEFIK_NETWORK}' is not attachable, so compose containers cannot join it; recreate it with 'docker network create --driver overlay --attachable ${TRAEFIK_NETWORK}' (requires removing the stacks using it) or use PROXY_MODE=standalone with BIND_ADDRESS"
fi

log "pulling images"
compose pull --quiet

up_args=(-d --remove-orphans --wait --wait-timeout "${WAIT_TIMEOUT:-300}")
if [[ -f "${ROOT_DIR}/.recreate" ]]; then
  log "configuration regenerated: recreating all containers"
  up_args+=(--force-recreate)
fi

log "starting containers"
if ! compose up "${up_args[@]}"; then
  compose ps -a
  compose logs --tail=40
  die "containers did not become healthy within ${WAIT_TIMEOUT:-300}s"
fi
rm -f "${ROOT_DIR}/.recreate"

bash "${ROOT_DIR}/scripts/healthcheck.sh" 120
