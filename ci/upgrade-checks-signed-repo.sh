#!/usr/bin/env bash
# M3 acceptance gate -- "Signed-repo upgrade" form (docs/packaging-goal.md
# "M3 -- Upgrades and migrations", Acceptance section + the literal
# apt-ftparchive/throwaway-GPG-key block under "Tasks"). Runs INSIDE a
# fresh ubuntu:26.04 container that has already `apt-get update`d, with a
# directory bind-mounted read-only at /work containing:
#   /work/cloudberryos_${BASE_VERSION}_all.deb
#   /work/cloudberryos_${NEXT1_VERSION}_all.deb   (throwaway upgrade-test build)
# BASE_VERSION/NEXT1_VERSION are passed in via the environment by
# ci/upgrade-stage.sh (docker run -e ...) -- never hardcoded here.
#
# Reproduces the doc's exact local signed-repo commands (apt-ftparchive +
# a throwaway `gpg --quick-generate-key`), installs the base version from
# it, then publishes NEXT1 to the same repo and upgrades via `apt update &&
# apt upgrade`, asserting the same preservation invariants as the direct
# upgrade form.
#
# Destructive to the container -- never run outside a throwaway container.
# Orchestrated by ci/upgrade-stage.sh.
set -euo pipefail

: "${BASE_VERSION:?BASE_VERSION must be set (passed in by ci/upgrade-stage.sh)}"
: "${NEXT1_VERSION:?NEXT1_VERSION must be set (passed in by ci/upgrade-stage.sh)}"

DEB_BASE="/work/cloudberryos_${BASE_VERSION}_all.deb"
DEB_NEXT1="/work/cloudberryos_${NEXT1_VERSION}_all.deb"
for f in "$DEB_BASE" "$DEB_NEXT1"; do
  test -f "$f" || { echo "missing $f -- run ci/upgrade-stage.sh's build step first" >&2; exit 1; }
done

step() { echo; echo "=== M3 signed-repo step: $1 ==="; }
fail() { echo "FAIL: $1" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }

step "install repo tooling + a throwaway GPG key"
apt-get install -yq --no-install-recommends gnupg apt-utils
export GNUPGHOME
GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key repo-test@cloudberryos.invalid default default never

step "build the local signed repo (apt-ftparchive) with $BASE_VERSION only"
mkdir -p /srv/repo
cp "$DEB_BASE" /srv/repo/
(
  cd /srv/repo
  apt-ftparchive packages . > Packages
  apt-ftparchive release . > Release
  gpg --batch --yes --clearsign -o InRelease Release
  gpg --export > /srv/repo/pubkey.gpg
)
echo 'deb [signed-by=/srv/repo/pubkey.gpg] copy:/srv/repo ./' > /etc/apt/sources.list.d/cloudberryos-test.list
apt-get update -q

step "apt-get install cloudberryos from the signed repo"
test ! -e /etc/cloudberryos
apt-get install -yq --no-install-recommends cloudberryos
dpkg -s cloudberryos | grep -q "^Version: ${BASE_VERSION}\$"

step "non-interactive setup + catalog edit"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel local
python3 - <<'PY'
import json
path = "/etc/cloudberryos/resources.json"
data = json.load(open(path))
data["resources"].append({
    "title": "Signed Repo Marker Site",
    "url": "https://signed-repo-marker.example.org/",
    "category": "Explore",
    "summary": "A site the parent added by hand before the signed-repo upgrade.",
    "allow_domains": ["signed-repo-marker.example.org"],
})
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY

step "record pre-upgrade hashes"
profile_before="$(sha /etc/cloudberryos/profile.json)"
squid_before="$(sha /etc/squid/squid.conf)"
if [[ -e /etc/cloudberryos/admin-token ]]; then
  admin_token_before="$(sha /etc/cloudberryos/admin-token)"
  had_admin_token=1
else
  had_admin_token=0
fi

step "publish $NEXT1_VERSION to the signed repo and re-sign"
cp "$DEB_NEXT1" /srv/repo/
(
  cd /srv/repo
  apt-ftparchive packages . > Packages
  apt-ftparchive release . > Release
  gpg --batch --yes --clearsign -o InRelease Release
)

step "apt update && apt upgrade -- zero stdin interaction"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq < /dev/null
dpkg -s cloudberryos | grep -q "^Version: ${NEXT1_VERSION}\$"
dpkg -s cloudberryos | grep -q '^Status: install ok installed$'

step "assert preservation invariants across the signed-repo upgrade"
[[ "$(sha /etc/cloudberryos/profile.json)" == "$profile_before" ]] || fail "profile.json changed across the signed-repo upgrade"
if [[ "$had_admin_token" -eq 1 ]]; then
  [[ "$(sha /etc/cloudberryos/admin-token)" == "$admin_token_before" ]] || fail "admin-token changed across the signed-repo upgrade"
else
  test ! -e /etc/cloudberryos/admin-token
fi
[[ "$(sha /etc/squid/squid.conf)" == "$squid_before" ]] || fail "squid.conf changed across the signed-repo upgrade"
grep -q "Signed Repo Marker Site" /etc/cloudberryos/resources.json || fail "parent's catalog edit did not survive"
grep -q "Signed Repo Marker Site" /var/lib/cloudberryos/home/index.html || fail "artifacts were not regenerated"
resources_schema_after="$(python3 -c "import json; print(json.load(open('/etc/cloudberryos/resources.json'))['schema_version'])")"
[[ "$resources_schema_after" == "2" ]] || fail "expected resources.json schema_version 2, got $resources_schema_after"
python3 -c "
import json, sys
d = json.load(open('/etc/cloudberryos/resources.json'))
sys.exit(0 if d.get('migrated_by_002') is True else 1)
" || fail "the 002 migration's transform is not visible in resources.json"

echo "profile.json / admin-token / squid.conf byte-identical, catalog edit survived, artifacts regenerated, 002 migration ran: all OK"
echo
echo "=== M3 signed-repo-upgrade form: ALL STEPS PASSED ==="
