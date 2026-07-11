#!/usr/bin/env bash
# M3 acceptance gate -- "Direct upgrade" and "Failing-migration recovery"
# forms (docs/packaging-goal.md "M3 -- Upgrades and migrations",
# Acceptance section). Runs INSIDE a fresh ubuntu:26.04 container that has
# already `apt-get update`d, with a directory containing three synthetic
# .deb builds bind-mounted read-only at /work:
#   /work/cloudberryos_0.1.0_all.deb  -- built from the real, committed source
#   /work/cloudberryos_0.1.1_all.deb  -- throwaway upgrade-test build:
#                                        differing starter catalog + a real
#                                        002 migration (never committed)
#   /work/cloudberryos_0.1.2_all.deb  -- throwaway build on top of 0.1.1:
#                                        adds a deliberately-raising 003
#                                        migration (never committed)
#
# Destructive to the container's /usr, /etc, /var, /home -- never run
# outside a throwaway container. Orchestrated by ci/upgrade-stage.sh.
set -euo pipefail

for f in /work/cloudberryos_0.1.0_all.deb /work/cloudberryos_0.1.1_all.deb /work/cloudberryos_0.1.2_all.deb; do
  test -f "$f" || { echo "missing $f -- run ci/upgrade-stage.sh's build step first" >&2; exit 1; }
done

step() { echo; echo "=== M3 direct-upgrade step: $1 ==="; }
fail() { echo "FAIL: $1" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------------------
# Install 0.1.0 (the committed source), non-interactive setup, catalog edit.
# ---------------------------------------------------------------------------
step "install 0.1.0"
test ! -e /etc/cloudberryos
apt-get install -yq --no-install-recommends /work/cloudberryos_0.1.0_all.deb
dpkg -s cloudberryos | grep -q '^Version: 0.1.0$'

step "non-interactive setup"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off

step "edit /etc/cloudberryos/resources.json (parent adds a marker site)"
python3 - <<'PY'
import json
path = "/etc/cloudberryos/resources.json"
data = json.load(open(path))
data["resources"].append({
    "title": "Parent Added Marker Site",
    "url": "https://parent-added.example.org/",
    "category": "Explore",
    "summary": "A site the parent added by hand before the upgrade.",
    "allow_domains": ["parent-added.example.org"],
})
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
grep -q "Parent Added Marker Site" /etc/cloudberryos/resources.json
# Not yet regenerated (we edited the catalog directly, bypassing apply) --
# proves the later "artifacts regenerated" assertion is real.
if grep -q "Parent Added Marker Site" /var/lib/cloudberryos/home/index.html; then
  fail "home/index.html already contains the marker before any apply ran -- test setup is wrong"
fi

step "record pre-upgrade hashes"
profile_before="$(sha /etc/cloudberryos/profile.json)"
squid_before="$(sha /etc/squid/squid.conf)"
if [[ -e /etc/cloudberryos/admin-token ]]; then
  admin_token_before="$(sha /etc/cloudberryos/admin-token)"
  had_admin_token=1
else
  had_admin_token=0
  echo "admin-token absent (expected in 0.1.x -- M4 not implemented yet)"
fi
resources_schema_before="$(python3 -c "import json; print(json.load(open('/etc/cloudberryos/resources.json')).get('schema_version', 0))")"
# The shipped starter catalog (config/resources.json) has no schema_version
# key at all -- "missing means 0" per the Migrations Locked Decision -- so a
# freshly-seeded /etc/cloudberryos/resources.json starts at 0, not 1.
[[ "$resources_schema_before" == "0" ]] || fail "expected resources.json schema_version 0 before upgrade (missing key), got $resources_schema_before"

# ---------------------------------------------------------------------------
# Upgrade to the synthesized 0.1.1: zero stdin interaction (no conffiles
# exist under /etc at all, so no conffile prompt is even possible).
# ---------------------------------------------------------------------------
step "apt-get install 0.1.1 (upgrade) -- must complete with zero stdin interaction"
DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends /work/cloudberryos_0.1.1_all.deb < /dev/null
dpkg -s cloudberryos | grep -q '^Version: 0.1.1$'
dpkg -s cloudberryos | grep -q '^Status: install ok installed$'

step "assert preservation invariants across the upgrade"
profile_after="$(sha /etc/cloudberryos/profile.json)"
[[ "$profile_before" == "$profile_after" ]] || fail "profile.json changed across the upgrade"
echo "profile.json byte-identical: OK ($profile_after)"

if [[ "$had_admin_token" -eq 1 ]]; then
  admin_token_after="$(sha /etc/cloudberryos/admin-token)"
  [[ "$admin_token_before" == "$admin_token_after" ]] || fail "admin-token changed across the upgrade"
  echo "admin-token byte-identical: OK ($admin_token_after)"
else
  test ! -e /etc/cloudberryos/admin-token
  echo "admin-token still absent post-upgrade: OK (expected pre-M4)"
fi

squid_after="$(sha /etc/squid/squid.conf)"
[[ "$squid_before" == "$squid_after" ]] || fail "squid.conf changed across the upgrade (apply's unchanged-content no-op path did not hold)"
echo "squid.conf byte-identical: OK ($squid_after)"

grep -q "Parent Added Marker Site" /etc/cloudberryos/resources.json || fail "parent's catalog edit did not survive the upgrade"
echo "parent's catalog edit survived: OK"

grep -q "Parent Added Marker Site" /var/lib/cloudberryos/home/index.html || fail "/var/lib/cloudberryos artifacts were not regenerated to reflect the live catalog"
echo "artifacts under /var/lib/cloudberryos regenerated: OK"

resources_after="$(python3 -c "import json; print(json.load(open('/etc/cloudberryos/resources.json')))")"
resources_schema_after="$(python3 -c "import json; print(json.load(open('/etc/cloudberryos/resources.json'))['schema_version'])")"
[[ "$resources_schema_after" == "2" ]] || fail "expected resources.json schema_version 2 after the 002 migration, got $resources_schema_after"
python3 -c "
import json, sys
d = json.load(open('/etc/cloudberryos/resources.json'))
sys.exit(0 if d.get('migrated_by_002') is True else 1)
" || fail "the 002 migration's transform (migrated_by_002) is not visible in resources.json"
echo "002 migration ran: schema_version bumped to 2 and its transform (migrated_by_002) is visible: OK"

echo
echo "=== M3 direct-upgrade form: ALL STEPS PASSED ==="

# ---------------------------------------------------------------------------
# Failing-migration recovery: install 0.1.2, which ships a 003 migration
# that unconditionally raises. Postinst must abort non-zero with every
# config file untouched; removing the bad migration + `dpkg --configure -a`
# must then recover cleanly.
# ---------------------------------------------------------------------------
step "record pre-0.1.2-attempt hashes"
profile_before_bad="$(sha /etc/cloudberryos/profile.json)"
resources_before_bad="$(sha /etc/cloudberryos/resources.json)"
squid_before_bad="$(sha /etc/squid/squid.conf)"

step "apt-get install 0.1.2 (ships a deliberately-raising 003 migration) -- must fail"
if DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends /work/cloudberryos_0.1.2_all.deb < /dev/null; then
  fail "installing 0.1.2 was expected to fail (raising 003 migration) but apt-get exited 0"
fi
echo "apt-get install 0.1.2 failed as expected (exit non-zero)"

step "assert dpkg left the package half-configured, and every config file untouched"
dpkg -s cloudberryos | grep -qE '^Status: install ok (half-configured|unpacked)$' \
  || fail "expected cloudberryos to be half-configured/unpacked after the failed postinst, got: $(dpkg -s cloudberryos | grep '^Status:')"
test -f /usr/share/cloudberryos/migrations/003-failing.py

[[ "$(sha /etc/cloudberryos/profile.json)" == "$profile_before_bad" ]] || fail "profile.json changed despite the aborted migration"
[[ "$(sha /etc/cloudberryos/resources.json)" == "$resources_before_bad" ]] || fail "resources.json changed despite the aborted migration"
[[ "$(sha /etc/squid/squid.conf)" == "$squid_before_bad" ]] || fail "squid.conf changed despite the aborted migration"
echo "profile.json, resources.json, squid.conf all byte-unchanged after the aborted migration: OK"

step "fix: remove the bad migration, then dpkg --configure -a must recover"
rm -f /usr/share/cloudberryos/migrations/003-failing.py
dpkg --configure -a
dpkg -s cloudberryos | grep -q '^Status: install ok installed$' || fail "dpkg --configure -a did not leave cloudberryos fully configured"
dpkg -s cloudberryos | grep -q '^Version: 0.1.2$'
echo "dpkg --configure -a recovered cleanly after removing the bad migration: OK"

# Config files must still reflect the earlier, correctly-migrated state
# (only the artifacts regenerate; profile/resources content is untouched
# by a plain 'cloudberryos-apply' run).
[[ "$(sha /etc/cloudberryos/profile.json)" == "$profile_before_bad" ]] || fail "profile.json changed during recovery"
[[ "$(sha /etc/cloudberryos/resources.json)" == "$resources_before_bad" ]] || fail "resources.json changed during recovery"
[[ "$(sha /etc/squid/squid.conf)" == "$squid_before_bad" ]] || fail "squid.conf changed during recovery (apply's no-op path should hold: 0.1.2 ships the same catalog/build.py as 0.1.1)"
echo "post-recovery config files still byte-identical: OK"

echo
echo "=== M3 failing-migration-recovery form: ALL STEPS PASSED ==="
