#!/usr/bin/env bash
# M2 acceptance gate, Block B, part 2: the prototype-migration test
# (docs/packaging-goal.md "M2 -- Debian packaging and lifecycle", service-
# level checks). Runs INSIDE a booted systemd container/VM, in ITS OWN
# fresh instance (never the same one as ci/services-checks-live.sh --
# this test wants a clean prototype install, not one already carrying
# packaged state). Requires dist/cloudberryos_<version>_all.deb to exist.
# Destructive -- only ever run in a throwaway systemd container or VM.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/ci/version.sh"
VERSION="$(cloudberryos_version "$REPO_ROOT/debian/changelog")"

DEB="dist/cloudberryos_${VERSION}_all.deb"
test -f "$DEB" || { echo "missing $DEB -- build it first (ci/package-stage.sh)" >&2; exit 1; }

step() { echo; echo "=== Block B (prototype migration) step: $1 ==="; }

step "wait for systemd to finish booting"
for _ in $(seq 1 60); do
  state="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done
systemctl is-system-running || true

step "apt-get update + ensure squid/adduser/etc are installable (prototype installer needs them)"
apt-get update -q

step "run tests/fixtures/prototype-install.sh (recreates prototype on-disk state)"
bash tests/fixtures/prototype-install.sh --student Test --student-user testkid --autologin
test -f /usr/local/bin/cloudberryos-browser
test -f /usr/local/sbin/cloudberryos-apply
test -f /usr/local/bin/cloudberryos-resource
test -f /etc/systemd/system/cloudberryos-firewall.service
test -f /etc/cloudberryos/install.env
systemctl is-active cloudberryos-firewall.service

step "edit the catalog via the prototype cloudberryos-resource (prototype default path)"
PROTOTYPE_CATALOG=/usr/share/cloudberryos/config/resources.json
test -f "$PROTOTYPE_CATALOG"
/usr/local/bin/cloudberryos-resource --config "$PROTOTYPE_CATALOG" add-site \
  --title "Migration Marker Site" \
  --url "https://migration-marker.example.org/" \
  --category "Explore" \
  --summary "Added via the prototype cloudberryos-resource before the .deb was installed." \
  --allow-domain migration-marker.example.org

step "install the .deb over the prototype (preinst rescues the prototype catalog first)"
# Copy the .deb into the container's own filesystem before `apt-get install`.
# By this point in the migration test, prototype-install.sh has already run
# apt operations, which arms apt's `_apt` download sandbox; the sandbox user
# then cannot read a .deb straight off the /src bind mount (apt reports it as
# "Unsupported file"). Installing from a container-local path sidesteps that
# entirely. (Block B's live checks install as their first apt op, before the
# sandbox is armed, so they are unaffected -- but copying is harmless there
# too.)
LOCAL_DEB="/tmp/$(basename "$DEB")"
cp "$DEB" "$LOCAL_DEB"
apt-get install -yq --no-install-recommends "$LOCAL_DEB"
test -f /etc/cloudberryos/resources.json
grep -q "Migration Marker Site" /etc/cloudberryos/resources.json
echo "confirmed: preinst rescued the prototype-edited catalog into /etc/cloudberryos/resources.json"

step "install.env migrated to profile.json and renamed .migrated by postinst"
test -f /etc/cloudberryos/install.env.migrated
test ! -e /etc/cloudberryos/install.env
python3 - <<'PY'
import json
profile = json.load(open("/etc/cloudberryos/profile.json"))
assert profile.get("child_name") == "Test", profile
assert profile.get("student_user") == "testkid", profile
print("postinst install.env migration OK:", profile.get("child_name"), profile.get("student_user"))
PY

step "run cloudberryos-setup (first packaged run migrates prototype /usr/local + deletes .migrated)"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off

step "assert: no cloudberryos-* files under /usr/local"
leftover="$(find /usr/local -iname 'cloudberryos-*')"
if [[ -n "$leftover" ]]; then
  echo "found leftover cloudberryos-* files under /usr/local:" >&2
  echo "$leftover" >&2
  exit 1
fi
echo "confirmed: /usr/local is clean of cloudberryos-* files"

step "assert: command -v cloudberryos-apply resolves to the packaged /usr/sbin path"
resolved="$(command -v cloudberryos-apply)"
[[ "$resolved" == "/usr/sbin/cloudberryos-apply" ]] || { echo "cloudberryos-apply resolved to $resolved, expected /usr/sbin/cloudberryos-apply" >&2; exit 1; }
echo "confirmed: cloudberryos-apply -> $resolved"

step "assert: the running firewall unit's ExecStart is the packaged path"
execstart="$(systemctl show cloudberryos-firewall.service -p ExecStart)"
grep -q '/usr/libexec/cloudberryos/cloudberryos-firewall-apply' <<<"$execstart"
test ! -e /etc/systemd/system/cloudberryos-firewall.service
echo "confirmed: cloudberryos-firewall.service now resolves to the packaged unit"

step "assert: the catalog edit survives in /etc/cloudberryos/resources.json"
grep -q "Migration Marker Site" /etc/cloudberryos/resources.json
echo "confirmed: prototype catalog edit survived the whole migration"

step "assert: install.env.migrated was deleted by setup's first successful run"
test ! -e /etc/cloudberryos/install.env.migrated
echo "confirmed: install.env.migrated is gone"

echo
echo "=== M2 acceptance gate, Block B (prototype-migration test): ALL STEPS PASSED ==="
