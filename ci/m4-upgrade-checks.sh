#!/usr/bin/env bash
# M4 acceptance gate addition -- companion to ci/m4-upgrade-stage.sh. Runs
# INSIDE a fresh ubuntu:26.04 container that has already `apt-get update`d,
# with /work bind-mounted read-only containing:
#   /work/cloudberryos_${PRE_M4_VERSION}_all.deb  -- built from a git worktree
#                                                     at the pinned pre-M4
#                                                     commit (no admin panel
#                                                     at all)
#   /work/cloudberryos_${CURRENT_VERSION}_all.deb -- built from the current
#                                                     working tree (M4: adds
#                                                     the admin panel)
# PRE_M4_VERSION/CURRENT_VERSION are passed in via the environment by
# ci/m4-upgrade-stage.sh (docker run -e ...).
#
# Destructive to the container -- never run outside a throwaway container.
set -euo pipefail

: "${PRE_M4_VERSION:?PRE_M4_VERSION must be set (passed in by ci/m4-upgrade-stage.sh)}"
: "${CURRENT_VERSION:?CURRENT_VERSION must be set (passed in by ci/m4-upgrade-stage.sh)}"

DEB_PRE="/work/cloudberryos_${PRE_M4_VERSION}_all.deb"
DEB_CURRENT="/work/cloudberryos_${CURRENT_VERSION}_all.deb"
for f in "$DEB_PRE" "$DEB_CURRENT"; do
  test -f "$f" || { echo "missing $f -- run ci/m4-upgrade-stage.sh's build step first" >&2; exit 1; }
done

step() { echo; echo "=== M4 real-upgrade step: $1 ==="; }
fail() { echo "FAIL: $1" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------------------
# Install the pre-M4 version (no admin panel exists at all yet).
# ---------------------------------------------------------------------------
step "install pre-M4 version $PRE_M4_VERSION"
test ! -e /etc/cloudberryos
apt-get install -yq --no-install-recommends "$DEB_PRE"
dpkg -s cloudberryos | grep -q "^Version: ${PRE_M4_VERSION}\$"
test ! -f /usr/bin/cloudberryos-admin
echo "confirmed: $PRE_M4_VERSION installed, cloudberryos-admin does not exist yet"

step "non-interactive setup (pre-M4: --admin-panel local|off only, no tailnet choice yet)"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel local
test ! -e /etc/cloudberryos/admin-token
echo "confirmed: admin-token does not exist under $PRE_M4_VERSION (expected -- it is an M4 feature)"

step "parent edits the catalog by hand before the upgrade"
python3 - <<'PY'
import json
path = "/etc/cloudberryos/resources.json"
data = json.load(open(path))
data["resources"].append({
    "title": "M4 Real-Upgrade Marker Site",
    "url": "https://m4-real-upgrade-marker.example.org/",
    "category": "Explore",
    "summary": "Added by ci/m4-upgrade-checks.sh before the 0.1.0 -> 0.2.0 upgrade.",
    "allow_domains": ["m4-real-upgrade-marker.example.org"],
})
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
grep -q "M4 Real-Upgrade Marker Site" /etc/cloudberryos/resources.json

step "record pre-upgrade hashes (no admin-token yet)"
profile_before="$(sha /etc/cloudberryos/profile.json)"
resources_before="$(sha /etc/cloudberryos/resources.json)"
squid_before="$(sha /etc/squid/squid.conf)"

# ---------------------------------------------------------------------------
# The real milestone-boundary upgrade: zero stdin interaction, no conffile
# prompts possible (nothing under /etc is shipped as a conffile).
# ---------------------------------------------------------------------------
step "apt-get install $CURRENT_VERSION (the real 0.1.0 -> 0.2.0 upgrade) -- zero stdin interaction"
DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends "$DEB_CURRENT" < /dev/null
dpkg -s cloudberryos | grep -q "^Version: ${CURRENT_VERSION}\$"
dpkg -s cloudberryos | grep -q '^Status: install ok installed$'
test -x /usr/bin/cloudberryos-admin
echo "confirmed: upgraded to $CURRENT_VERSION with zero stdin interaction; cloudberryos-admin now exists"

step "assert profile.json / resources.json preserved, catalog edit survived, artifacts regenerated"
[[ "$(sha /etc/cloudberryos/profile.json)" == "$profile_before" ]] || fail "profile.json changed across the real 0.1.0 -> 0.2.0 upgrade"
[[ "$(sha /etc/cloudberryos/resources.json)" == "$resources_before" ]] || fail "resources.json changed across the real 0.1.0 -> 0.2.0 upgrade"
[[ "$(sha /etc/squid/squid.conf)" == "$squid_before" ]] || fail "squid.conf changed across the real 0.1.0 -> 0.2.0 upgrade"
grep -q "M4 Real-Upgrade Marker Site" /etc/cloudberryos/resources.json || fail "parent's catalog edit did not survive the upgrade"
grep -q "M4 Real-Upgrade Marker Site" /var/lib/cloudberryos/home/index.html || fail "artifacts under /var/lib/cloudberryos were not regenerated"
test ! -e /etc/cloudberryos/admin-token
echo "confirmed: profile.json, resources.json, squid.conf byte-identical; catalog edit survived; artifacts regenerated"
echo "confirmed: admin-token still does not exist immediately after the bare package upgrade (postinst only runs migrate+apply, never setup)"

# ---------------------------------------------------------------------------
# Now run the newly-upgraded (0.2.0) cloudberryos-setup: this is the first
# time anything creates the admin-token (ensure_admin_token, gated on
# admin_panel != "off"; the saved profile already has admin_panel=local from
# the pre-M4 run, so it is reused as-is -- resolve_admin_panel_mode() only
# ever touches tailscale for the "tailnet" case).
# ---------------------------------------------------------------------------
step "run cloudberryos-setup under $CURRENT_VERSION -- creates admin-token for the first time"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia
test -f /etc/cloudberryos/admin-token
mode="$(stat -c '%a' /etc/cloudberryos/admin-token)"
[[ "$mode" == "600" ]] || fail "expected /etc/cloudberryos/admin-token mode 600, got $mode"
admin_token_v1="$(sha /etc/cloudberryos/admin-token)"
profile_v1="$(sha /etc/cloudberryos/profile.json)"
resources_v1="$(sha /etc/cloudberryos/resources.json)"
echo "confirmed: admin-token now exists (mode 600)"

# ---------------------------------------------------------------------------
# admin-token "byte-identical across the upgrade path" -- now that it
# exists, prove a subsequent packaging operation (same-version reinstall,
# which re-runs postinst's migrate+apply exactly as a later point-release
# upgrade would) leaves it, profile.json, and resources.json untouched.
# This is the same idiom ci/lifecycle-checks.sh already uses for
# profile.json/resources.json; it extends naturally to admin-token now
# that M4 has introduced it.
# ---------------------------------------------------------------------------
step "same-version reinstall (simulates a later point-release's postinst) preserves admin-token/profile/resources"
apt-get install -yq --no-install-recommends --reinstall "$DEB_CURRENT"
[[ "$(sha /etc/cloudberryos/admin-token)" == "$admin_token_v1" ]] || fail "admin-token changed across a same-version reinstall"
[[ "$(sha /etc/cloudberryos/profile.json)" == "$profile_v1" ]] || fail "profile.json changed across a same-version reinstall"
[[ "$(sha /etc/cloudberryos/resources.json)" == "$resources_v1" ]] || fail "resources.json changed across a same-version reinstall"
echo "confirmed: admin-token, profile.json, and resources.json are all byte-identical across a postinst-triggered reconfigure"

echo
echo "=== M4 acceptance gate: real ${PRE_M4_VERSION} -> ${CURRENT_VERSION} upgrade (profile.json, resources.json, admin-token, catalog edit, zero conffile prompts): ALL STEPS PASSED ==="
