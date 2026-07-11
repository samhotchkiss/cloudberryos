#!/usr/bin/env bash
# M4 acceptance gate, Block C: the admin-panel firewall test
# (docs/packaging-goal.md "M4 -- Admin panel", Acceptance section --
# "Firewall (systemd container): from a child-UID process, connecting to
# 127.0.0.1:8766 is refused"). Runs INSIDE a booted systemd container/VM, in
# its own fresh instance (reuses the Block B service environment/tooling,
# not its container instance -- this wants its own clean install so the
# admin panel can be enabled from a clean slate). Requires
# dist/cloudberryos_<version>_all.deb to exist. Destructive -- only ever run
# in a throwaway systemd container or VM.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/ci/version.sh"
VERSION="$(cloudberryos_version "$REPO_ROOT/debian/changelog")"

DEB="dist/cloudberryos_${VERSION}_all.deb"
test -f "$DEB" || { echo "missing $DEB -- build it first (ci/package-stage.sh)" >&2; exit 1; }

step() { echo; echo "=== Block C (admin firewall) step: $1 ==="; }

step "wait for systemd to finish booting"
for _ in $(seq 1 60); do
  state="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done
systemctl is-system-running || true

step "apt-get install ./$DEB"
apt-get update -q
# Install from a container-local copy, not straight off the /src bind mount:
# apt's `_apt` download sandbox cannot always read a bind-mounted file (it
# reports "Unsupported file"). Copying first makes this robust.
LOCAL_DEB="/tmp/$(basename "$DEB")"
cp "$DEB" "$LOCAL_DEB"
apt-get install -yq --no-install-recommends "$LOCAL_DEB"

step "non-interactive cloudberryos-setup --admin-panel local (systemd IS available)"
# No real tailscale in this container -- explicit "local" avoids the M4
# default's tailnet-detection attempt entirely (it would harmlessly degrade
# to local anyway, since 'tailscale' is not on PATH here, but being
# explicit keeps this test's intent obvious).
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel local

step "admin-token exists, is 0600, and the admin service is enabled + active + listening"
test -f /etc/cloudberryos/admin-token
mode="$(stat -c '%a' /etc/cloudberryos/admin-token)"
[[ "$mode" == "600" ]] || { echo "expected /etc/cloudberryos/admin-token mode 600, got $mode" >&2; exit 1; }
systemctl is-enabled cloudberryos-admin.service
systemctl is-active cloudberryos-admin.service

listen_ok=0
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null http://127.0.0.1:8766/admin 2>/dev/null; then
    listen_ok=1
    break
  fi
  sleep 0.5
done
[[ "$listen_ok" -eq 1 ]] || { echo "cloudberryos-admin never answered on 127.0.0.1:8766 (as root)" >&2; systemctl status cloudberryos-admin.service --no-pager || true; exit 1; }
echo "confirmed: admin-token is 0600, cloudberryos-admin.service is enabled+active, and it answers on 127.0.0.1:8766 for root"

step "as the child UID, connecting to 127.0.0.1:8766 is refused by the firewall"
# curl exit 7 = "Failed to connect" (connection refused) -- this is what an
# nft `reject` produces. The M1 firewall rule (usr/libexec/cloudberryos/
# cloudberryos-firewall-apply) rejects the child UID on loopback tcp/8766
# BEFORE the general loopback accept, specifically so the child can never
# reach the admin panel even though it is otherwise allowed to use lo.
set +e
su testkid -s /bin/bash -c 'curl -sS -o /dev/null -m 5 http://127.0.0.1:8766/admin'
child_curl_status=$?
set -e
[[ "$child_curl_status" -eq 7 ]] || {
  echo "expected curl exit 7 (connection refused) for the child UID against 127.0.0.1:8766, got $child_curl_status" >&2
  exit 1
}
echo "confirmed: child UID's connection to 127.0.0.1:8766 was refused (curl exit 7)"

step "sanity: the same child UID CAN still reach the child homepage on 127.0.0.1:8765"
su testkid -s /bin/bash -c 'curl -fsS -o /dev/null -m 5 http://127.0.0.1:8765/home/index.html'
echo "confirmed: 127.0.0.1:8765 (child homepage) remains reachable for the child -- only 8766 is blocked"

echo
echo "=== M4 acceptance gate, Block C (admin-panel firewall test): ALL STEPS PASSED ==="
