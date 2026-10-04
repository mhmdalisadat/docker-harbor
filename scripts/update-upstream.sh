#!/usr/bin/env bash
# Usage: update-upstream.sh [vX.Y.Z]   (default: latest stable release)
# Pins a Harbor release: writes upstream/VERSION and refreshes the reference files
# (harbor.yml.tmpl, prepare, LICENSE) from github.com/goharbor/harbor.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

version="${1:-}"
if [[ -z "${version}" ]]; then
  version="$(curl -fsSL https://api.github.com/repos/goharbor/harbor/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "${version}" ]] || die "could not determine the latest release; pass a version, e.g. v2.15.2"
fi
[[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a release version: ${version}"

base="https://raw.githubusercontent.com/goharbor/harbor/${version}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL "${base}/make/harbor.yml.tmpl" -o "${tmp}/harbor.yml.tmpl"
curl -fsSL "${base}/make/prepare" -o "${tmp}/prepare"
curl -fsSL "${base}/LICENSE" -o "${tmp}/LICENSE"
grep -q '^_version:' "${tmp}/harbor.yml.tmpl" || die "unexpected harbor.yml.tmpl for ${version}"

previous="${HARBOR_VERSION}"
mv "${tmp}/harbor.yml.tmpl" "${tmp}/prepare" "${tmp}/LICENSE" "${ROOT_DIR}/upstream/"
echo "${version}" > "${ROOT_DIR}/upstream/VERSION"
log "pinned ${version} (was ${previous})"
log "review: git diff -- upstream/   (new harbor.yml settings may need to go into scripts/setup.sh)"
log "release notes: https://github.com/goharbor/harbor/releases/tag/${version}"
log "then: make backup && make deploy"
