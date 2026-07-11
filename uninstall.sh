#!/usr/bin/env bash
set -euo pipefail

PREFIX="/usr/share/cloudberryos"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

rm -rf "$PREFIX"
rm -f /etc/firefox/policies/policies.json
rm -f /etc/opt/chrome/policies/managed/cloudberryos.json
rm -f /etc/chromium/policies/managed/cloudberryos.json
rm -f /usr/share/applications/cloudberryos-home.desktop
rm -f /usr/share/applications/cloudberryos-browser.desktop
rm -f /usr/share/applications/cloudberryos-projects.desktop
rm -f /usr/share/applications/cloudberryos-request-shelf.desktop
rm -f /usr/share/backgrounds/cloudberryos.svg
rm -f /usr/share/backgrounds/cloudberryos.png
rm -f /usr/share/icons/hicolor/scalable/apps/cloudberryos-browser.svg
rm -f /usr/share/icons/hicolor/scalable/apps/cloudberryos-projects.svg
rm -f /usr/share/icons/hicolor/scalable/apps/cloudberryos-offline-wikipedia.svg
rm -f /usr/share/icons/hicolor/scalable/apps/cloudberryos-request-shelf.svg

if systemctl list-unit-files cloudberryos-firewall.service >/dev/null 2>&1; then
  systemctl disable --now cloudberryos-firewall.service >/dev/null 2>&1 || true
fi

rm -f /etc/systemd/system/cloudberryos-firewall.service
rm -f /usr/local/sbin/cloudberryos-firewall-apply
rm -f /usr/local/bin/cloudberryos-browser
rm -f /etc/squid/conf.d/cloudberryos.conf
if [[ -f /etc/squid/squid.conf.cloudberryos.bak ]]; then
  cp /etc/squid/squid.conf.cloudberryos.bak /etc/squid/squid.conf
fi
rm -rf /etc/cloudberryos
systemctl daemon-reload

echo "CloudberryOS removed."
