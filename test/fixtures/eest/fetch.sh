#!/usr/bin/env bash
# Fetches the pinned ethereum/execution-spec-tests (EEST) release fixtures into
# test/fixtures/eest/fixtures/ for `mix eevm.state_tests` and
# `mix eevm.blockchain_tests`. Used by CI and .agents/setup.
#
# The release tarball is kept in $EEST_CACHE_DIR (default ~/.cache/eevm/eest),
# named by version, so CI can cache it and reruns skip the 257 MB download.
# Only state_tests/ and blockchain_tests/ are extracted. Idempotent.
#
# To move to a new release, update EEST_VERSION and EEST_SHA256 (the asset's
# digest on the GitHub release page), then regenerate both known-failures
# lists in this directory with the commands in their headers.
set -euo pipefail

EEST_VERSION="v5.4.0"
EEST_SHA256="92cf1b47ad12fb27163261fc3c1cea5df72439cab507983d06b56c94f8741909"
EEST_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_VERSION}/fixtures_stable.tar.gz"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${here}/fixtures"
cache_dir="${EEST_CACHE_DIR:-${HOME}/.cache/eevm/eest}"
tarball="${cache_dir}/fixtures_stable-${EEST_VERSION}.tar.gz"

if [[ "$(cat "${dest}/.version" 2>/dev/null)" == "${EEST_VERSION}" ]]; then
  echo "EEST ${EEST_VERSION} fixtures already in ${dest}"
  exit 0
fi

mkdir -p "$cache_dir"
if [[ ! -f "$tarball" ]]; then
  curl -fsSL --retry 3 -o "${tarball}.part" "$EEST_URL"
  mv "${tarball}.part" "$tarball"
fi
echo "${EEST_SHA256}  ${tarball}" | sha256sum --check --quiet -

rm -rf "$dest"
mkdir -p "$dest"
tar -xzf "$tarball" -C "$dest" --strip-components=1 fixtures/state_tests fixtures/blockchain_tests
echo "$EEST_VERSION" > "${dest}/.version"
echo "Extracted EEST ${EEST_VERSION} fixtures into ${dest}"
