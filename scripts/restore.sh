#!/usr/bin/env bash
# Usage: restore.sh <backup.tar.gz>
# Stops Harbor, replaces .env, DATA_DIR/secret and the database (and the registry blobs, if the
# archive has them) with the archive's copy, and loads the database dump. The current files are
# kept next to them with a .before-restore-<timestamp> suffix. Run `make deploy` afterwards.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root restore

archive="${1:-}"
[[ -f "${archive}" ]] || die "usage: $0 <backup.tar.gz>"
archive="$(cd "$(dirname "${archive}")" && pwd)/$(basename "${archive}")"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
log "extracting ${archive}"
tar -xzf "${archive}" -C "${tmp}"
for f in .env registry.pgdump secret; do
  [[ -e "${tmp}/${f}" ]] || die "${archive} contains no ${f}"
done
restore_dirs=(database secret redis)
[[ -d "${tmp}/registry" ]] && restore_dirs+=(registry)

suffix=".before-restore-$(date +%Y%m%d-%H%M%S)"
set_aside() {
  local d
  for d in "${restore_dirs[@]}"; do
    if [[ -e "${DATA_PATH}/${d}" ]]; then mv "${DATA_PATH}/${d}" "${DATA_PATH}/${d}${suffix}"; fi
  done
}

if [[ -f "${ENV_FILE}" ]]; then
  load_env
  if [[ -f "${ROOT_DIR}/docker-compose.yml" ]]; then
    compose down --remove-orphans || warn "could not stop the running stack"
  fi
  set_aside
  mv "${ENV_FILE}" "${ENV_FILE}${suffix}"
fi

install -m 600 "${tmp}/.env" "${ENV_FILE}"
load_env
mkdir -p "${DATA_PATH}"
set_aside
cp -a "${tmp}/secret" "${DATA_PATH}/secret"
[[ -d "${tmp}/registry" ]] && mv "${tmp}/registry" "${DATA_PATH}/registry"

bash "${ROOT_DIR}/scripts/setup.sh" --force
load_env

log "starting an empty database and loading the dump"
compose up -d --wait --wait-timeout "${WAIT_TIMEOUT:-300}" postgresql
compose exec -T postgresql pg_restore -U postgres -d registry --clean --if-exists --no-owner \
  < "${tmp}/registry.pgdump"
compose stop postgresql log

log "restored .env, secret and the database from ${archive}; previous copies have the suffix ${suffix}"
[[ -d "${DATA_PATH}/registry" ]] || warn "no registry blobs in ${DATA_PATH}/registry: artifacts listed in the UI cannot be pulled until the blobs are copied there"
log "next: make deploy"
