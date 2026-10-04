#!/usr/bin/env bash
# Archive .env (all secrets), a pg_dump of the Harbor database and DATA_DIR/secret (encryption
# key, token signing key) into ${BACKUP_DIR}; with BACKUP_REGISTRY=1 also the registry blobs.
# Deletes archives older than ${BACKUP_KEEP_DAYS} days. Restore with scripts/restore.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root backup
load_env

[[ -d "${DATA_PATH}/secret" ]] || die "${DATA_PATH}/secret does not exist, nothing to back up"
[[ -n "$(compose ps -q --status running postgresql 2>/dev/null)" ]] \
  || die "the postgresql service is not running; start Harbor first (make deploy)"

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
umask 077
stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

log "dumping the database"
compose exec -T postgresql pg_dump -U postgres -Fc registry > "${stage}/registry.pgdump"
[[ -s "${stage}/registry.pgdump" ]] || die "pg_dump produced no output"

members=(-C "${stage}" registry.pgdump -C "${ROOT_DIR}" .env -C "${DATA_PATH}" secret)
if is_true "${BACKUP_REGISTRY:-0}"; then
  members+=(registry)
  log "including the registry blobs ($(du -sh "${DATA_PATH}/registry" 2>/dev/null | cut -f1))"
fi

archive="${BACKUP_DIR}/harbor-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "${archive}" "${members[@]}"
log "backup written: ${archive} ($(du -h "${archive}" | cut -f1))"

find "${BACKUP_DIR}" -maxdepth 1 -name 'harbor-*.tar.gz' -mtime +"${BACKUP_KEEP_DAYS:-14}" -print -delete \
  | sed 's/^/[harbor] removed old backup: /'
