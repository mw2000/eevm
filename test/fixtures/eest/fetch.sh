#!/usr/bin/env bash
# Fetches a pinned ethereum/execution-spec-tests (EEST) release's fixtures for
# `mix eevm.state_tests` and `mix eevm.blockchain_tests`. Used by CI and
# .agents/setup.
#
#   test/fixtures/eest/fetch.sh            # fixtures_stable  -> fixtures/
#   test/fixtures/eest/fetch.sh develop    # fixtures_develop -> fixtures_develop/
#
# fixtures_stable covers mainnet forks through Prague. fixtures_develop adds the
# forks in development (Osaka and its blob-parameter-only forks); CI runs only
# its Osaka cases (--fork osaka).
#
# Release tarballs are kept in $EEST_CACHE_DIR (default ~/.cache/eevm/eest),
# named by asset and version, so CI can cache them and reruns skip the download
# (257 MB stable, 423 MB develop). Only state_tests/ and blockchain_tests/ are
# extracted. Idempotent.
#
# To move to a new release, update EEST_VERSION and both SHA-256 digests (the
# assets' digests on the GitHub release page), then regenerate every
# known-failures list in this directory with the commands in their headers.
set -euo pipefail

EEST_VERSION="v5.4.0"
STABLE_SHA256="92cf1b47ad12fb27163261fc3c1cea5df72439cab507983d06b56c94f8741909"
DEVELOP_SHA256="3e2b02d49fe903eda4fd8caca5cbf0d139c470e97e1de9a85299b1b034f97099"

release="${1:-stable}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$release" in
  stable) sha256="$STABLE_SHA256"; dest="${here}/fixtures" ;;
  develop) sha256="$DEVELOP_SHA256"; dest="${here}/fixtures_develop" ;;
  *) echo "usage: $0 [stable|develop]" >&2; exit 2 ;;
esac

asset="fixtures_${release}"
url="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_VERSION}/${asset}.tar.gz"
cache_dir="${EEST_CACHE_DIR:-${HOME}/.cache/eevm/eest}"
tarball="${cache_dir}/${asset}-${EEST_VERSION}.tar.gz"

if [[ "$(cat "${dest}/.version" 2>/dev/null)" == "${EEST_VERSION}" ]]; then
  echo "EEST ${EEST_VERSION} ${asset} already in ${dest}"
  exit 0
fi

mkdir -p "$cache_dir"
if [[ ! -f "$tarball" ]]; then
  curl -fsSL --retry 3 -o "${tarball}.part" "$url"
  mv "${tarball}.part" "$tarball"
fi
echo "${sha256}  ${tarball}" | sha256sum --check --quiet -

rm -rf "$dest"
mkdir -p "$dest"
tar -xzf "$tarball" -C "$dest" --strip-components=1 fixtures/state_tests fixtures/blockchain_tests
echo "$EEST_VERSION" > "${dest}/.version"
echo "Extracted EEST ${EEST_VERSION} ${asset} into ${dest}"
