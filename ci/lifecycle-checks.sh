#!/usr/bin/env bash
# M2 acceptance gate, Block A (docs/packaging-goal.md "M2 -- Debian packaging
# and lifecycle", Acceptance section, the plain-Docker lifecycle block).
#
# Runs INSIDE a fresh ubuntu:26.04 container that has already `apt-get
# update`d. Installs dist/cloudberryos_0.1.0_all.deb (built by
# ci/package-stage.sh's build step) and exercises install -> setup ->
# --remove-student-config -> re-setup -> reinstall -> remove -> purge,
# asserting file-level behavior only (no live systemd/NET_ADMIN here --
# see ci/services-stage.sh for the service-level checks).
#
# Destructive to the container's /usr, /etc, /var, /home -- never run
# outside a throwaway container.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/ci/version.sh"
VERSION="$(cloudberryos_version "$REPO_ROOT/debian/changelog")"

DEB="dist/cloudberryos_${VERSION}_all.deb"
if [[ ! -f "$DEB" ]]; then
  echo "missing $DEB -- run the build step first" >&2
  exit 1
fi

step() { echo; echo "=== Block A step: $1 ==="; }

hash_tree() {
  local dir="$1"
  find "$dir" -type f ! -name '*.log' -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Install on a machine with NO prior /etc/cloudberryos state.
# ---------------------------------------------------------------------------
step "apt-get install ./$DEB (fresh, no prior state)"
test ! -e /etc/cloudberryos
apt-get install -yq --no-install-recommends "./$DEB"
command -v cloudberryos-setup >/dev/null
command -v cloudberryos-apply >/dev/null
command -v cloudberryos-resource >/dev/null
command -v cloudberryos-browser >/dev/null
test -x /usr/sbin/cloudberryos-apply
test -x /usr/libexec/cloudberryos/cloudberryos-firewall-apply
echo "postinst on a fresh install succeeded with no prior /etc/cloudberryos state (migrate no-op)"

# ---------------------------------------------------------------------------
# Non-interactive setup; assert /etc/cloudberryos + /var/lib/cloudberryos.
# ---------------------------------------------------------------------------
step "non-interactive cloudberryos-setup"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off

id testkid >/dev/null
for f in profile.json resources.json allowed-domains.txt student-users; do
  test -f "/etc/cloudberryos/$f" || { echo "MISSING /etc/cloudberryos/$f" >&2; exit 1; }
done
test -d /var/lib/cloudberryos/home
test -d /var/lib/cloudberryos/generated
test -d /var/lib/cloudberryos/assets
test -f /etc/squid/squid.conf
test -f /etc/squid/squid.conf.cloudberryos.bak
test -d "/home/testkid/CloudberryOS/site"
test -d "/home/testkid/Test's Projects"
echo "step OK: /etc/cloudberryos and /var/lib/cloudberryos manifests present"

# ---------------------------------------------------------------------------
# --remove-student-config: file-level un-polish assertions.
# ---------------------------------------------------------------------------
step "cloudberryos-setup --remove-student-config testkid"
HOME_DIR="/home/testkid"
squid_before_removeconfig_hash="$(sha256sum /etc/squid/squid.conf.cloudberryos.bak | awk '{print $1}')"

cloudberryos-setup --remove-student-config testkid

test ! -e "$HOME_DIR/.config/environment.d/cloudberryos-proxy.conf"
test ! -e "$HOME_DIR/.config/autostart/cloudberryos-browser.desktop"
test ! -e "$HOME_DIR/.config/autostart/update-notifier.desktop"
test ! -e "$HOME_DIR/.local/share/applications/cloudberryos-projects.desktop"
test ! -e "$HOME_DIR/.local/share/applications/cloudberryos-request-shelf.desktop"
test ! -e "$HOME_DIR/.local/share/applications/cloudberryos-offline-wikipedia.desktop"
test ! -e "$HOME_DIR/.cloudberryos"
# No GNOME/no hidden apps exist in a plain-Docker base, so polish never wrote
# any hidden-app override desktop files -- assert none leaked through either.
if compgen -G "$HOME_DIR/.local/share/applications/*.desktop" > /dev/null; then
  echo "unexpected leftover desktop file(s) under .local/share/applications:" >&2
  ls "$HOME_DIR/.local/share/applications/" >&2
  exit 1
fi
# mimeapps.list: no pre-existing parent-authored file existed before polish
# ran (fresh adduser home), so polish never took a .bak -- "restored" means
# the managed file it wrote is now gone entirely.
test ! -e "$HOME_DIR/.config/mimeapps.list"
test ! -e "$HOME_DIR/.config/mimeapps.list.cloudberryos.bak"
# squid.conf restored byte-identical to the .bak
cmp -s /etc/squid/squid.conf /etc/squid/squid.conf.cloudberryos.bak
squid_after_removeconfig_hash="$(sha256sum /etc/squid/squid.conf.cloudberryos.bak | awk '{print $1}')"
[[ "$squid_before_removeconfig_hash" == "$squid_after_removeconfig_hash" ]] || { echo "the .bak itself changed -- should never happen" >&2; exit 1; }
# Child account and Projects/CloudberryOS folders are kept, not removed.
id testkid >/dev/null
test -d "$HOME_DIR/CloudberryOS"
test -d "$HOME_DIR/Test's Projects"
echo "step OK: file-level un-polish assertions all passed; account + Projects + CloudberryOS folders kept"

# ---------------------------------------------------------------------------
# Re-run setup: must exit 0 and re-create the polish artifacts.
# ---------------------------------------------------------------------------
step "re-run cloudberryos-setup after --remove-student-config"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off
test -e "$HOME_DIR/.config/environment.d/cloudberryos-proxy.conf"
test -e "$HOME_DIR/.cloudberryos"
echo "step OK: re-run setup exited 0 and restored child-home polish"

# ---------------------------------------------------------------------------
# Reinstall the same version.
# ---------------------------------------------------------------------------
step "apt-get install --reinstall (same version, profile.json now exists)"
before_etc="$(hash_tree /etc/cloudberryos)"
apt-get install -yq --no-install-recommends --reinstall "./$DEB"
after_etc="$(hash_tree /etc/cloudberryos)"
[[ "$before_etc" == "$after_etc" ]] || { echo "MISMATCH: /etc/cloudberryos changed across a same-version reinstall" >&2; exit 1; }
id testkid >/dev/null
echo "step OK: reinstall succeeded, /etc/cloudberryos unchanged"

# ---------------------------------------------------------------------------
# Remove (not purge): /etc/cloudberryos must remain.
# ---------------------------------------------------------------------------
step "apt-get remove cloudberryos (plain remove)"
apt-get remove -yq cloudberryos
test -e /etc/cloudberryos/profile.json
test -e /etc/cloudberryos/resources.json
echo "step OK: plain remove left /etc/cloudberryos in place"

# ---------------------------------------------------------------------------
# Purge: /etc/cloudberryos and /var/lib/cloudberryos must both be gone.
# ---------------------------------------------------------------------------
step "apt-get purge cloudberryos"
apt-get purge -yq cloudberryos
test ! -e /etc/cloudberryos
test ! -e /var/lib/cloudberryos
echo "step OK: purge removed /etc/cloudberryos and /var/lib/cloudberryos"

echo
echo "=== M2 acceptance gate, Block A: ALL STEPS PASSED ==="
