#!/usr/bin/env bash
# M3 acceptance gate (docs/packaging-goal.md "M3 -- Upgrades and
# migrations", Acceptance section). Runs on the HOST (needs Docker): it
# synthesizes throwaway patch-bumped source workspaces relative to
# whatever the CURRENT committed version is (temporary debian/changelog
# entries + a differing starter catalog + real migration scripts -- NONE
# of this is committed to the repo, per the "Versions" Locked Decision),
# builds all three .debs in one throwaway container, then runs the three
# acceptance forms:
#   1. Direct upgrade (apt-get install ./<next1>.deb over an installed <base>)
#   2. Failing-migration recovery (<next2> ships a raising migration)
#   3. Signed-repo upgrade (local apt-ftparchive + throwaway-GPG-key repo)
#
# Versions are derived from debian/changelog (ci/version.sh), never
# hardcoded -- this is what lets the same gate keep passing across
# milestones (0.1.0 at M3, 0.2.0 at M4, ...).
#
# Usage: ci/upgrade-stage.sh   (requires Docker; run from the repo root or
# anywhere -- it cds to the repo root itself)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/ci/version.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "ci/upgrade-stage.sh: docker is required but not found on PATH" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ci/upgrade-stage.sh: python3 is required on the host to synthesize the test workspaces" >&2
  exit 1
fi

BASE_VERSION="$(cloudberryos_version "$REPO_ROOT/debian/changelog")"
NEXT1_VERSION="$(cloudberryos_bump_patch "$BASE_VERSION" 1)"
NEXT2_VERSION="$(cloudberryos_bump_patch "$BASE_VERSION" 2)"
echo "== upgrade stage: base version $BASE_VERSION (committed), synthesizing $NEXT1_VERSION / $NEXT2_VERSION (never committed) =="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cloudberryos-upgrade-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# next1 workspace: a copy of the repo + a temporary changelog entry + a
# differing starter catalog + a real 002 migration exercising the runner.
# ---------------------------------------------------------------------------
SRC_NEXT1="$WORK/src-next1"
mkdir -p "$SRC_NEXT1"
tar -C "$REPO_ROOT" --exclude=.git --exclude=dist -cf - . | tar -C "$SRC_NEXT1" -xf -

CHANGELOG_NEXT1_ENTRY="cloudberryos (${NEXT1_VERSION}) unstable; urgency=medium

  * Throwaway M3 upgrade-test build (NEVER committed): differing starter
    catalog plus a 002 migration that exercises the runner end to end.

 -- Sam <s@swh.me>  Sat, 11 Jul 2026 16:00:00 -0600

"
printf '%s' "$CHANGELOG_NEXT1_ENTRY" | cat - "$SRC_NEXT1/debian/changelog" > "$SRC_NEXT1/debian/changelog.new"
mv "$SRC_NEXT1/debian/changelog.new" "$SRC_NEXT1/debian/changelog"

python3 - "$SRC_NEXT1/config/resources.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["resources"].append({
    "title": "Upgrade-Test Starter Catalog Diff Marker",
    "url": "https://starter-catalog-diff.example.org/",
    "category": "Explore",
    "summary": "Present only in the synthesized next1 starter catalog.",
    "allow_domains": ["starter-catalog-diff.example.org"],
})
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

cat > "$SRC_NEXT1/migrations/002-upgrade-test.py" <<'EOF'
"""Throwaway M3 upgrade-test migration -- NEVER committed to the repo.

Bumps resources.json to schema_version 2 with a real, verifiable
transform. Defines no upgrade_profile hook on purpose: profile.json must
stay byte-identical across the M3 acceptance upgrade.
"""

SCHEMA_VERSION = 2


def upgrade_resources(d):
    d["migrated_by_002"] = True
    return d
EOF

# ---------------------------------------------------------------------------
# next2 workspace: built on top of next1's tree (same catalog/build.py, so
# squid.conf generation stays byte-identical), + a deliberately-raising 003
# migration for the failing-migration-recovery test.
# ---------------------------------------------------------------------------
SRC_NEXT2="$WORK/src-next2"
cp -a "$SRC_NEXT1" "$SRC_NEXT2"

CHANGELOG_NEXT2_ENTRY="cloudberryos (${NEXT2_VERSION}) unstable; urgency=medium

  * Throwaway M3 failing-migration-recovery test build (NEVER committed):
    ships a 003 migration that unconditionally raises.

 -- Sam <s@swh.me>  Sat, 11 Jul 2026 16:05:00 -0600

"
printf '%s' "$CHANGELOG_NEXT2_ENTRY" | cat - "$SRC_NEXT2/debian/changelog" > "$SRC_NEXT2/debian/changelog.new"
mv "$SRC_NEXT2/debian/changelog.new" "$SRC_NEXT2/debian/changelog"

cat > "$SRC_NEXT2/migrations/003-failing.py" <<'EOF'
"""Throwaway M3 failing-migration-recovery test migration -- NEVER
committed to the repo. Unconditionally raises so the runner must abort
the whole chain with every config file left untouched."""

SCHEMA_VERSION = 3


def upgrade_profile(d):
    raise RuntimeError("deliberately broken 003 migration for the M3 failing-migration-recovery test")
EOF

# debian/rules only installs migrations/001-initial.py and 002/003 live
# next to it in the same migrations/ dir -- teach the packaging rules
# about them in each synthetic workspace only (never in the committed
# debian/rules).
for src in "$SRC_NEXT1" "$SRC_NEXT2"; do
  python3 - "$src/debian/rules" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
marker = "install -D -m 0644 migrations/001-initial.py debian/cloudberryos/usr/share/cloudberryos/migrations/001-initial.py\n"
assert marker in text, "expected marker line not found in debian/rules"
extra = ""
import os
migrations_dir = os.path.join(os.path.dirname(path), "..", "migrations")
for name in sorted(os.listdir(migrations_dir)):
    if name in ("001-initial.py",) or not name.endswith(".py"):
        continue
    extra += f"\tinstall -D -m 0644 migrations/{name} debian/cloudberryos/usr/share/cloudberryos/migrations/{name}\n"
text = text.replace(marker, marker + extra)
open(path, "w").write(text)
PY
done

echo "== upgrade stage: building all three .debs (base=$BASE_VERSION real source, next1=$NEXT1_VERSION + next2=$NEXT2_VERSION synthesized) =="
mkdir -p "$WORK/out"
docker run --rm \
  -e BASE_VERSION="$BASE_VERSION" -e NEXT1_VERSION="$NEXT1_VERSION" -e NEXT2_VERSION="$NEXT2_VERSION" \
  -v "$REPO_ROOT":/src:ro \
  -v "$WORK":/work \
  -w /work \
  ubuntu:26.04 bash -c '
    set -euo pipefail
    apt-get update -q
    apt-get install -yq --no-install-recommends build-essential devscripts debhelper

    cp -a /src /work/src-base
    rm -rf /work/src-base/dist

    for d in src-base src-next1 src-next2; do
      echo "-- building $d --"
      ( cd "/work/$d" && dpkg-buildpackage -us -uc -b )
    done

    cp "/work/cloudberryos_${BASE_VERSION}_all.deb" /work/out/
    cp "/work/cloudberryos_${NEXT1_VERSION}_all.deb" /work/out/
    cp "/work/cloudberryos_${NEXT2_VERSION}_all.deb" /work/out/
  '

for v in "$BASE_VERSION" "$NEXT1_VERSION" "$NEXT2_VERSION"; do
  test -f "$WORK/out/cloudberryos_${v}_all.deb" || { echo "build of $v failed to produce a .deb" >&2; exit 1; }
done
echo "== upgrade stage: all three .debs built OK =="

echo
echo "== upgrade stage: direct upgrade + failing-migration recovery (fresh container) =="
docker run --rm \
  -e BASE_VERSION="$BASE_VERSION" -e NEXT1_VERSION="$NEXT1_VERSION" -e NEXT2_VERSION="$NEXT2_VERSION" \
  -v "$WORK/out":/work:ro \
  -v "$REPO_ROOT/ci":/ci:ro \
  -w / \
  ubuntu:26.04 bash -c '
    set -euo pipefail
    apt-get update -q
    bash /ci/upgrade-checks-direct.sh
  '
echo "== upgrade stage: direct upgrade + failing-migration recovery OK =="

echo
echo "== upgrade stage: signed-repo upgrade (fresh container) =="
docker run --rm \
  -e BASE_VERSION="$BASE_VERSION" -e NEXT1_VERSION="$NEXT1_VERSION" \
  -v "$WORK/out":/work:ro \
  -v "$REPO_ROOT/ci":/ci:ro \
  -w / \
  ubuntu:26.04 bash -c '
    set -euo pipefail
    apt-get update -q
    bash /ci/upgrade-checks-signed-repo.sh
  '
echo "== upgrade stage: signed-repo upgrade OK =="

echo
echo "=== M3 acceptance gate: ALL FORMS PASSED (direct upgrade, failing-migration recovery, signed-repo upgrade) ==="
