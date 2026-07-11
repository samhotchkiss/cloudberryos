#!/usr/bin/env bash
# M4 acceptance gate addition -- a REAL 0.1.0 -> 0.2.0 upgrade
# (docs/packaging-goal.md "M4 -- Admin panel", "Regression at 0.2.0": "Build
# the 0.1.0 .deb from the committed pre-M4 source (a git worktree / clean
# checkout of 3b6ef12 is the clean way) and the 0.2.0 .deb from your working
# tree"). Unlike ci/upgrade-stage.sh's synthesized patch-bump versions
# (which exercise the schema-migrations runner in the abstract against
# whatever the current version happens to be), this specifically proves the
# M4 milestone boundary: a real 0.1.0 build (no admin panel at all) upgrading
# to a real 0.2.0 build, preserving profile.json, resources.json, and
# admin-token (which exists only from 0.2.0 onward).
#
# Runs on the HOST (needs Docker + git). Usage: ci/m4-upgrade-stage.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/ci/version.sh"

PRE_M4_COMMIT="3b6ef12"

if ! command -v docker >/dev/null 2>&1; then
  echo "ci/m4-upgrade-stage.sh: docker is required but not found on PATH" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "ci/m4-upgrade-stage.sh: git is required but not found on PATH" >&2
  exit 1
fi

CURRENT_VERSION="$(cloudberryos_version "$REPO_ROOT/debian/changelog")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cloudberryos-m4-upgrade-test.XXXXXX")"
WORKTREE_DIR="$WORK/pre-m4-worktree"

cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== m4-upgrade stage: checking out pre-M4 commit $PRE_M4_COMMIT into a git worktree =="
git -C "$REPO_ROOT" worktree add --detach "$WORKTREE_DIR" "$PRE_M4_COMMIT"

PRE_M4_VERSION="$(cloudberryos_version "$WORKTREE_DIR/debian/changelog")"
echo "== m4-upgrade stage: pre-M4 commit $PRE_M4_COMMIT is version $PRE_M4_VERSION; current working tree is $CURRENT_VERSION =="
if [[ "$PRE_M4_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "ci/m4-upgrade-stage.sh: pre-M4 commit and working tree report the SAME version ($PRE_M4_VERSION) -- refusing to run a same-version 'upgrade' test" >&2
  exit 1
fi

mkdir -p "$WORK/out"
echo "== m4-upgrade stage: building $PRE_M4_VERSION (worktree @ $PRE_M4_COMMIT) and $CURRENT_VERSION (working tree) =="
docker run --rm \
  -v "$WORKTREE_DIR":/src-pre-m4:ro \
  -v "$REPO_ROOT":/src-current:ro \
  -v "$WORK":/work \
  -w /work \
  ubuntu:26.04 bash -c '
    set -euo pipefail
    apt-get update -q
    apt-get install -yq --no-install-recommends build-essential devscripts debhelper

    cp -a /src-pre-m4 /work/src-pre-m4
    cp -a /src-current /work/src-current
    rm -rf /work/src-pre-m4/dist /work/src-current/dist

    ( cd /work/src-pre-m4 && dpkg-buildpackage -us -uc -b )
    ( cd /work/src-current && dpkg-buildpackage -us -uc -b )

    mkdir -p /work/out
    cp /work/*_all.deb /work/out/
  '

PRE_M4_DEB="$WORK/out/cloudberryos_${PRE_M4_VERSION}_all.deb"
CURRENT_DEB="$WORK/out/cloudberryos_${CURRENT_VERSION}_all.deb"
test -f "$PRE_M4_DEB" || { echo "build of $PRE_M4_VERSION (pre-M4 worktree) failed to produce a .deb" >&2; exit 1; }
test -f "$CURRENT_DEB" || { echo "build of $CURRENT_VERSION (working tree) failed to produce a .deb" >&2; exit 1; }
echo "== m4-upgrade stage: both .debs built OK =="

echo
echo "== m4-upgrade stage: real $PRE_M4_VERSION -> $CURRENT_VERSION direct upgrade (fresh container) =="
docker run --rm \
  -e PRE_M4_VERSION="$PRE_M4_VERSION" -e CURRENT_VERSION="$CURRENT_VERSION" \
  -v "$WORK/out":/work:ro \
  -v "$REPO_ROOT/ci":/ci:ro \
  -w / \
  ubuntu:26.04 bash -c '
    set -euo pipefail
    apt-get update -q
    bash /ci/m4-upgrade-checks.sh
  '

echo
echo "=== M4 acceptance gate: real ${PRE_M4_VERSION} -> ${CURRENT_VERSION} upgrade: ALL STEPS PASSED ==="
