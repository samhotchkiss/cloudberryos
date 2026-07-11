#!/usr/bin/env bash
# M1 acceptance gate body (docs/packaging-goal.md "M1 -- Code rework",
# Acceptance section). Runs the 9 numbered steps, in order, inside a single
# ubuntu:26.04 container already `apt-get install`ed with:
#   python3 python3-pytest squid nftables adduser sudo systemd
#   libglib2.0-bin dbus xdg-utils
#
# There is no debian/ packaging yet (that is M2), so this script "fake
# installs" the repo's proposed package layout (usr/bin, usr/sbin,
# usr/libexec/cloudberryos, usr/lib/systemd/system, usr/share/cloudberryos)
# by copying files straight into the real filesystem paths a .deb will
# eventually own (see docs/packaging-goal.md "Package layout"). This is
# what puts `cloudberryos-setup` etc. on PATH by bare name, as the M1 task
# description requires, and it exercises the same path-resolution code
# (cloudberryos_common.py's /usr/share/cloudberryos/... candidates) that
# the real .deb will use in M2.
#
# This script is destructive to the CONTAINER's /usr, /etc, /var, /home --
# never run it outside a throwaway container.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step() { echo; echo "=== Step $1: $2 ==="; }

# ---------------------------------------------------------------------------
# Step 1: pytest, including the new validator tests.
# ---------------------------------------------------------------------------
step 1 "pytest (unit tests, including M1 validator tests)"
python3 -m pytest tests/

# ---------------------------------------------------------------------------
# Step 2: bash -n on every shell script.
# ---------------------------------------------------------------------------
step 2 "bash -n on all shell scripts"
mapfile -t shell_scripts < <(find . \( -path ./.git -o -path ./.pytest_cache -o -path ./.cloudberry-deploy \) -prune -o \
  -type f -print 2>/dev/null | sort | while read -r f; do
    head -c 64 "$f" 2>/dev/null | grep -q '^#!.*bash' && echo "$f"
  done)
for script in "${shell_scripts[@]}"; do
  echo "bash -n $script"
  bash -n "$script"
done

# ---------------------------------------------------------------------------
# "Fake install": stage the proposed package layout onto real paths.
# ---------------------------------------------------------------------------
step "install" "stage the proposed package layout onto real filesystem paths"
install -d /usr/bin /usr/sbin /usr/libexec/cloudberryos /usr/lib/systemd/system \
  /usr/share/cloudberryos/tools /usr/share/cloudberryos/config /usr/share/cloudberryos/assets/icons \
  /usr/share/applications /usr/share/doc/cloudberryos /usr/share/backgrounds \
  /usr/share/icons/hicolor/scalable/apps

install -m 0755 usr/bin/cloudberryos-setup /usr/bin/cloudberryos-setup
install -m 0755 usr/bin/cloudberryos-browser /usr/bin/cloudberryos-browser
install -m 0755 tools/cloudberryos-resource.py /usr/bin/cloudberryos-resource
install -m 0755 usr/sbin/cloudberryos-apply /usr/sbin/cloudberryos-apply
install -m 0755 usr/libexec/cloudberryos/cloudberryos-firewall-apply /usr/libexec/cloudberryos/cloudberryos-firewall-apply
install -m 0644 usr/lib/systemd/system/cloudberryos-firewall.service /usr/lib/systemd/system/cloudberryos-firewall.service
install -m 0644 "usr/lib/systemd/system/cloudberryos-home@.service" "/usr/lib/systemd/system/cloudberryos-home@.service"
install -m 0644 usr/share/applications/cloudberryos-browser.desktop /usr/share/applications/cloudberryos-browser.desktop
install -m 0644 usr/share/applications/cloudberryos-home.desktop /usr/share/applications/cloudberryos-home.desktop

install -m 0755 tools/build.py /usr/share/cloudberryos/tools/build.py
install -m 0755 tools/cloudberryos-resource.py /usr/share/cloudberryos/tools/cloudberryos-resource.py
install -m 0644 tools/cloudberryos_common.py /usr/share/cloudberryos/tools/cloudberryos_common.py
install -m 0755 tools/polish_user.sh /usr/share/cloudberryos/tools/polish_user.sh
install -m 0644 config/resources.json /usr/share/cloudberryos/config/resources.json

install -m 0644 assets/cloudberryos-home.css /usr/share/cloudberryos/assets/cloudberryos-home.css
install -m 0644 assets/cloudberryos-wallpaper-3840.png /usr/share/cloudberryos/assets/cloudberryos-wallpaper-3840.png
install -m 0644 assets/icons/*.svg /usr/share/cloudberryos/assets/icons/
ln -sf /usr/share/cloudberryos/assets/cloudberryos-wallpaper-3840.png /usr/share/backgrounds/cloudberryos.png
for icon in assets/icons/*.svg; do
  install -m 0644 "$icon" "/usr/share/icons/hicolor/scalable/apps/$(basename "$icon")"
done

install -m 0644 docs/apps.md /usr/share/cloudberryos/apps.md

hash_tree() {
  local dir="$1"
  find "$dir" -type f ! -name '*.log' -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}

SETUP_LOG="$(mktemp)"

# ---------------------------------------------------------------------------
# Step 3: non-interactive setup.
# ---------------------------------------------------------------------------
step 3 "non-interactive cloudberryos-setup"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off \
  2>&1 | tee "$SETUP_LOG"

id testkid >/dev/null
for f in profile.json resources.json allowed-domains.txt student-users; do
  test -f "/etc/cloudberryos/$f" || { echo "MISSING /etc/cloudberryos/$f" >&2; exit 1; }
done
test -d /var/lib/cloudberryos/home
test -d /var/lib/cloudberryos/generated
test -d /var/lib/cloudberryos/assets
test -f /etc/squid/squid.conf
test -f /etc/squid/squid.conf.cloudberryos.bak
grep -q '"deferred_service_setup": true' /etc/cloudberryos/profile.json
grep -qi 'skipping enable of cloudberryos-firewall.service' "$SETUP_LOG"
grep -qi 'skipping enable of cloudberryos-home@testkid.service' "$SETUP_LOG"
echo "step 3 OK"

# ---------------------------------------------------------------------------
# Step 4: squid -k parse (must run after step 3).
# ---------------------------------------------------------------------------
step 4 "squid -k parse -f /etc/squid/squid.conf"
squid -k parse -f /etc/squid/squid.conf
echo "step 4 OK"

# ---------------------------------------------------------------------------
# Step 5: policy JSON well-formed, canonical homepage URL, no file://.
# ---------------------------------------------------------------------------
step 5 "policy JSON validity + canonical homepage URL + no file:// anywhere"
python3 -m json.tool /var/lib/cloudberryos/generated/firefox-policies.json >/dev/null
python3 -m json.tool /var/lib/cloudberryos/generated/chrome-policies.json >/dev/null
grep -q 'http://127.0.0.1:8765/home/index.html' /var/lib/cloudberryos/generated/firefox-policies.json
grep -q 'http://127.0.0.1:8765/home/index.html' /var/lib/cloudberryos/generated/chrome-policies.json
if grep -rl 'file://' /etc/cloudberryos /var/lib/cloudberryos 2>/dev/null; then
  echo "found file:// in an artifact (see above)" >&2
  exit 1
fi
echo "step 5 OK"

# ---------------------------------------------------------------------------
# Step 6: systemd-analyze verify (units already staged above).
# ---------------------------------------------------------------------------
step 6 "systemd-analyze verify (firewall unit + instantiated home@testkid unit)"
systemd-analyze verify cloudberryos-firewall.service "cloudberryos-home@testkid.service"
echo "step 6 OK"

# ---------------------------------------------------------------------------
# Step 7: idempotent re-run -- manifests must match.
# ---------------------------------------------------------------------------
step 7 "idempotency: second identical setup run changes nothing"
before_etc="$(hash_tree /etc/cloudberryos)"
before_var="$(hash_tree /var/lib/cloudberryos)"
before_home="$(hash_tree /home/testkid)"
before_squid="$(hash_tree /etc/squid)"

cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off

after_etc="$(hash_tree /etc/cloudberryos)"
after_var="$(hash_tree /var/lib/cloudberryos)"
after_home="$(hash_tree /home/testkid)"
after_squid="$(hash_tree /etc/squid)"

echo "/etc/cloudberryos      before=$before_etc after=$after_etc"
echo "/var/lib/cloudberryos  before=$before_var after=$after_var"
echo "/home/testkid          before=$before_home after=$after_home"
echo "/etc/squid (no *.log)  before=$before_squid after=$after_squid"

[[ "$before_etc" == "$after_etc" ]] || { echo "MISMATCH: /etc/cloudberryos changed on re-run" >&2; exit 1; }
[[ "$before_var" == "$after_var" ]] || { echo "MISMATCH: /var/lib/cloudberryos changed on re-run" >&2; exit 1; }
[[ "$before_home" == "$after_home" ]] || { echo "MISMATCH: /home/testkid changed on re-run" >&2; exit 1; }
[[ "$before_squid" == "$after_squid" ]] || { echo "MISMATCH: /etc/squid changed on re-run" >&2; exit 1; }
echo "step 7 OK: manifests identical across both runs"

# ---------------------------------------------------------------------------
# Step 8: negative / legacy-compat tests.
# ---------------------------------------------------------------------------
step 8 "negative + legacy-compat flag tests"

if cloudberryos-setup --no-password --keep-password 2>/tmp/conflict.err; then
  echo "expected non-zero exit for --no-password --keep-password" >&2
  exit 1
fi
grep -qi 'conflict' /tmp/conflict.err
echo "conflict test OK: $(cat /tmp/conflict.err)"

cloudberryos-setup --non-interactive --student Test --no-student-password \
  --student-user legacykid --no-autologin --apps none --no-offline-wikipedia --admin-panel off
python3 - <<'PY'
import json
profile = json.load(open("/etc/cloudberryos/profile.json"))
assert profile["child_name"] == "Test", profile
assert profile["student_user"] == "legacykid", profile
assert profile["no_password"] is True, profile
print("legacy-flag-mapping test OK:", profile["child_name"], profile["student_user"], profile["no_password"])
PY
echo "step 8 OK"

# ---------------------------------------------------------------------------
# Step 9: app-name gate.
# ---------------------------------------------------------------------------
step 9 "app-name gate (every backticked apps.md Ubuntu package)"
python3 - <<'PY' > /tmp/wizard-apps.txt
import sys
sys.path.insert(0, "tools")
import cloudberryos_common as common
wizard, recommended = common.parse_apps_catalog("docs/apps.md")
for name in sorted(wizard):
    print(name)
PY
echo "checking $(wc -l < /tmp/wizard-apps.txt) package names from docs/apps.md"
failed=0
while IFS= read -r pkg; do
  if ! apt-get install --dry-run --no-install-recommends "$pkg" >/tmp/dryrun-"$pkg".log 2>&1; then
    echo "DRY-RUN FAILED: $pkg" >&2
    cat /tmp/dryrun-"$pkg".log >&2
    failed=1
  fi
done < /tmp/wizard-apps.txt
if [[ "$failed" -ne 0 ]]; then
  echo "app-name gate FAILED -- see above" >&2
  exit 1
fi
echo "step 9 OK: all $(wc -l < /tmp/wizard-apps.txt) package names resolve"

echo
echo "=== M1 acceptance gate: ALL STEPS PASSED ==="
