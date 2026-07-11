#!/usr/bin/env bash
# M2 acceptance gate, Block B, part 1 (docs/packaging-goal.md "M2 -- Debian
# packaging and lifecycle", service-level checks). Runs INSIDE a booted
# systemd container/VM with dist/cloudberryos_0.1.0_all.deb already built.
# Destructive -- only ever run in a throwaway systemd container or VM.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEB="dist/cloudberryos_0.1.0_all.deb"
test -f "$DEB" || { echo "missing $DEB -- build it first (ci/package-stage.sh)" >&2; exit 1; }

step() { echo; echo "=== Block B (live) step: $1 ==="; }

step "wait for systemd to finish booting"
for _ in $(seq 1 60); do
  state="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done
systemctl is-system-running || true

step "apt-get install ./dist/cloudberryos_0.1.0_all.deb"
apt-get update -q
apt-get install -yq --no-install-recommends "./$DEB"

step "non-interactive cloudberryos-setup (systemd IS available -- no deferral)"
SETUP_LOG="$(mktemp)"
cloudberryos-setup --non-interactive --child-name Test --student-user testkid \
  --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off \
  2>&1 | tee "$SETUP_LOG"
if grep -qi 'deferred' "$SETUP_LOG"; then
  echo "expected NO service-deferral warnings under a live systemd" >&2
  exit 1
fi
grep -q '"deferred_service_setup": false' /etc/cloudberryos/profile.json

step "units enabled + active after setup"
systemctl is-enabled cloudberryos-firewall.service
systemctl is-active cloudberryos-firewall.service
systemctl is-enabled "cloudberryos-home@testkid.service"
systemctl is-active "cloudberryos-home@testkid.service"

step "nft ruleset shows table inet cloudberryos with the student UID rules"
uid_testkid="$(id -u testkid)"
# Capture into a variable first: `nft ... | grep -q` makes grep close the pipe
# on its first match, nft then takes SIGPIPE, and pipefail+set -e would abort
# on that (exit 141) even though the assertion passed.
ruleset="$(nft list ruleset)"
grep -q 'table inet cloudberryos' <<<"$ruleset"
grep -q "meta skuid ${uid_testkid}" <<<"$ruleset"
echo "nft ruleset OK:"
sed -n '/table inet cloudberryos/,/^}/p' <<<"$ruleset"

step "squid restarted with the managed config"
systemctl is-active squid
cmp -s /etc/squid/squid.conf /var/lib/cloudberryos/generated/squid-cloudberryos.conf || {
  echo "note: squid.conf differs from the just-generated candidate text (unexpected)" >&2
  diff -u /var/lib/cloudberryos/generated/squid-cloudberryos.conf /etc/squid/squid.conf || true
  exit 1
}

step "curl the child homepage over the cloudberryos-home@testkid unit"
# `systemctl enable --now` returns as soon as a Type=simple unit's process
# forks -- an instant before python3 -m http.server actually binds 8765 --
# so poll briefly rather than assuming the socket is up the moment setup
# exits.
curl_ok=0
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8765/home/index.html > /tmp/home.html 2>/dev/null; then
    curl_ok=1
    break
  fi
  sleep 0.5
done
[[ "$curl_ok" -eq 1 ]] || { echo "homepage never answered on 127.0.0.1:8765" >&2; systemctl status "cloudberryos-home@testkid.service" --no-pager || true; exit 1; }
grep -qi 'CloudberryOS' /tmp/home.html
echo "curl OK: homepage served on 127.0.0.1:8765"

step "stopping the firewall unit removes the nftables table"
systemctl stop cloudberryos-firewall.service
if grep -q 'table inet cloudberryos' <<<"$(nft list ruleset)"; then
  echo "table inet cloudberryos still present after systemctl stop" >&2
  exit 1
fi
echo "confirmed: no cloudberryos table after stop"

step "restarting the firewall unit re-creates the table (sanity before the remove test below)"
systemctl start cloudberryos-firewall.service
grep -q 'table inet cloudberryos' <<<"$(nft list ruleset)"

step "cloudberryos-setup --remove-student-config testkid disables cloudberryos-home@testkid"
cloudberryos-setup --remove-student-config testkid
if systemctl is-enabled "cloudberryos-home@testkid.service" 2>/dev/null; then
  echo "cloudberryos-home@testkid.service is still enabled after --remove-student-config" >&2
  exit 1
fi
echo "confirmed: cloudberryos-home@testkid.service is disabled"

step "package remove leaves no cloudberryos table (prerm autoscript ExecStop)"
apt-get remove -yq cloudberryos
if grep -q 'table inet cloudberryos' <<<"$(nft list ruleset)"; then
  echo "table inet cloudberryos still present after apt-get remove" >&2
  exit 1
fi
echo "confirmed: no cloudberryos table after package remove"
apt-get purge -yq cloudberryos || true

echo
echo "=== M2 acceptance gate, Block B (live service checks): ALL STEPS PASSED ==="
