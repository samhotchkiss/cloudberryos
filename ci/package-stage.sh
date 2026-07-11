#!/usr/bin/env bash
# M2 acceptance gate (docs/packaging-goal.md "M2 -- Debian packaging and
# lifecycle", Acceptance section, Block A: build + lint + plain-Docker
# lifecycle). Unlike ci/setup-stage.sh (which runs *inside* an
# already-provisioned container), this script runs on the HOST (it needs
# to spin up more than one fresh, throwaway ubuntu:26.04 container: one to
# build+lint, a second clean one for the install/setup/remove/purge
# lifecycle) via `docker run`.
#
# Usage: ci/package-stage.sh   (requires Docker; run from the repo root or
# anywhere -- it cds to the repo root itself)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "ci/package-stage.sh: docker is required but not found on PATH" >&2
  exit 1
fi

echo "== package stage: build + lintian =="
rm -rf dist
mkdir -p dist
docker run --rm -v "$REPO_ROOT":/src -w /src ubuntu:26.04 bash -c '
  set -euo pipefail
  apt-get update -q
  apt-get install -yq --no-install-recommends build-essential devscripts debhelper lintian
  dpkg-buildpackage -us -uc -b
  lintian --fail-on error ../cloudberryos_0.1.0_all.deb
  mkdir -p /src/dist
  cp ../cloudberryos_0.1.0_all.deb /src/dist/
'

test -f dist/cloudberryos_0.1.0_all.deb
echo "== package stage: build + lintian OK =="

echo
echo "== package stage: Block A lifecycle (fresh container) =="
docker run --rm -v "$REPO_ROOT":/src -w /src ubuntu:26.04 bash -c '
  set -euo pipefail
  apt-get update -q
  bash ci/lifecycle-checks.sh
'
echo "== package stage: Block A lifecycle OK =="
