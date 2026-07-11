#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

STATE_FILE="/etc/cloudberryos/install.env"
PREFIX="/usr/share/cloudberryos"
STUDENT=""
STUDENT_USER=""

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

CONFIG="${PREFIX}/config/resources.json"
if [[ ! -f "$CONFIG" ]]; then
  echo "Missing resource catalog: $CONFIG" >&2
  exit 1
fi

BUILD_ARGS=(--config "$CONFIG" --target "$PREFIX")
if [[ -n "${STUDENT:-}" ]]; then
  BUILD_ARGS+=(--student "$STUDENT")
fi

python3 "$PREFIX/tools/build.py" "${BUILD_ARGS[@]}"

install -m 0644 "$PREFIX/generated/allowed-domains.txt" /etc/cloudberryos/allowed-domains.txt
install -m 0644 "$PREFIX/generated/squid-cloudberryos.conf" /etc/cloudberryos/squid-cloudberryos.conf
install -m 0755 "$PREFIX/generated/cloudberryos-browser" /usr/local/bin/cloudberryos-browser
install -m 0644 "$PREFIX/generated/cloudberryos-browser.desktop" /usr/share/applications/cloudberryos-browser.desktop
install -m 0644 "$PREFIX/generated/cloudberryos-home.desktop" /usr/share/applications/cloudberryos-home.desktop

if [[ -f /etc/squid/squid.conf ]]; then
  install -m 0644 /etc/cloudberryos/squid-cloudberryos.conf /etc/squid/squid.conf
  systemctl restart squid || true
fi

if systemctl list-unit-files cloudberryos-firewall.service >/dev/null 2>&1; then
  install -m 0755 "$PREFIX/generated/cloudberryos-firewall-apply" /usr/local/sbin/cloudberryos-firewall-apply
  install -m 0644 "$PREFIX/generated/cloudberryos-firewall.service" /etc/systemd/system/cloudberryos-firewall.service
  systemctl daemon-reload
  systemctl restart cloudberryos-firewall.service || true
fi

if [[ -n "${STUDENT_USER:-}" && -x "$PREFIX/tools/polish_user.sh" ]]; then
  "$PREFIX/tools/polish_user.sh" --user "$STUDENT_USER" --student "${STUDENT:-$STUDENT_USER}" --prefix "$PREFIX"
fi

echo "CloudberryOS applied from $CONFIG"
