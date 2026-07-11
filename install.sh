#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$PROJECT_DIR/config/resources.json"
STUDENT=""
STUDENT_USER=""
PREFIX="/usr/share/cloudberryos"
INSTALL_POLICIES=0
INSTALL_STUDENT_LOCK=0
NO_STUDENT_PASSWORD=0
AUTOLOGIN=0

usage() {
  cat <<'USAGE'
Usage: sudo ./install.sh [options]

Options:
  --student NAME        Student name to show on the homepage.
  --student-user USER   Configure a locked browser/network experience for USER.
  --no-student-password Remove the student account password.
  --autologin           Configure GDM to automatically log in as the student.
  --config PATH         Resource catalog JSON. Defaults to config/resources.json.
  --prefix PATH         Install assets here. Defaults to /usr/share/cloudberryos.
  --install-policies    Install machine-wide browser policies. This locks all users.
  --no-policies         Generate assets but do not install browser policies.
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --student)
      STUDENT="${2:?Missing value for --student}"
      shift 2
      ;;
    --config)
      CONFIG="${2:?Missing value for --config}"
      shift 2
      ;;
    --student-user)
      STUDENT_USER="${2:?Missing value for --student-user}"
      INSTALL_STUDENT_LOCK=1
      INSTALL_POLICIES=0
      shift 2
      ;;
    --no-student-password)
      NO_STUDENT_PASSWORD=1
      shift
      ;;
    --autologin)
      AUTOLOGIN=1
      shift
      ;;
    --prefix)
      PREFIX="${2:?Missing value for --prefix}"
      shift 2
      ;;
    --no-policies)
      INSTALL_POLICIES=0
      shift
      ;;
    --install-policies)
      INSTALL_POLICIES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run with sudo so CloudberryOS can install system files." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

install -d "$PREFIX" "$PREFIX/config" "$PREFIX/tools" "$PREFIX/home" "$PREFIX/generated" "$PREFIX/assets"
install -m 0644 "$CONFIG" "$PREFIX/config/resources.json"
install -m 0755 "$PROJECT_DIR/tools/build.py" "$PREFIX/tools/build.py"
install -m 0755 "$PROJECT_DIR/tools/polish_user.sh" "$PREFIX/tools/polish_user.sh"
install -m 0755 "$PROJECT_DIR/tools/cloudberryos-apply.sh" "$PREFIX/tools/cloudberryos-apply.sh"
install -m 0755 "$PROJECT_DIR/tools/cloudberryos-resource.py" "$PREFIX/tools/cloudberryos-resource.py"
install -d /usr/share/backgrounds
install -m 0644 "$PROJECT_DIR/assets/cloudberryos-wallpaper-3840.png" "$PREFIX/assets/cloudberryos-wallpaper-3840.png"
install -m 0644 "$PROJECT_DIR/assets/cloudberryos-home.css" "$PREFIX/assets/cloudberryos-home.css"
install -d "$PREFIX/assets/icons"
install -m 0644 "$PROJECT_DIR/assets/icons/cloudberryos-browser.svg" "$PREFIX/assets/icons/cloudberryos-browser.svg"
install -m 0644 "$PROJECT_DIR/assets/cloudberryos-wallpaper-3840.png" /usr/share/backgrounds/cloudberryos.png
install -d /usr/share/icons/hicolor/scalable/apps
install -m 0644 "$PROJECT_DIR/assets/icons/cloudberryos-browser.svg" /usr/share/icons/hicolor/scalable/apps/cloudberryos-browser.svg
install -m 0644 "$PROJECT_DIR/assets/icons/cloudberryos-projects.svg" /usr/share/icons/hicolor/scalable/apps/cloudberryos-projects.svg
install -m 0644 "$PROJECT_DIR/assets/icons/cloudberryos-offline-wikipedia.svg" /usr/share/icons/hicolor/scalable/apps/cloudberryos-offline-wikipedia.svg
install -m 0644 "$PROJECT_DIR/assets/icons/cloudberryos-request-shelf.svg" /usr/share/icons/hicolor/scalable/apps/cloudberryos-request-shelf.svg

BUILD_ARGS=(--config "$PREFIX/config/resources.json" --target "$PREFIX")
if [[ -n "$STUDENT" ]]; then
  BUILD_ARGS+=(--student "$STUDENT")
fi

python3 "$PREFIX/tools/build.py" "${BUILD_ARGS[@]}"

install -d /etc/cloudberryos
install -m 0644 "$PREFIX/generated/allowed-domains.txt" /etc/cloudberryos/allowed-domains.txt
install -m 0644 "$PREFIX/generated/squid-cloudberryos.conf" /etc/cloudberryos/squid-cloudberryos.conf
install -m 0755 "$PREFIX/generated/cloudberryos-browser" /usr/local/bin/cloudberryos-browser
install -m 0644 "$PREFIX/generated/cloudberryos-browser.desktop" /usr/share/applications/cloudberryos-browser.desktop
install -m 0755 "$PREFIX/tools/cloudberryos-apply.sh" /usr/local/sbin/cloudberryos-apply
install -m 0755 "$PREFIX/tools/cloudberryos-resource.py" /usr/local/bin/cloudberryos-resource

{
  printf 'PREFIX=%q\n' "$PREFIX"
  printf 'STUDENT=%q\n' "$STUDENT"
  printf 'STUDENT_USER=%q\n' "$STUDENT_USER"
  printf 'INSTALL_POLICIES=%q\n' "$INSTALL_POLICIES"
} > /etc/cloudberryos/install.env
chmod 0644 /etc/cloudberryos/install.env

if [[ "$INSTALL_STUDENT_LOCK" -eq 1 ]]; then
  if ! id "$STUDENT_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$STUDENT_USER"
    echo "Created account '$STUDENT_USER'."
  fi

  if [[ "$NO_STUDENT_PASSWORD" -eq 1 ]]; then
    passwd -d "$STUDENT_USER" >/dev/null
  elif passwd -S "$STUDENT_USER" | awk '{exit ($2 == "NP" ? 0 : 1)}'; then
    passwd -l "$STUDENT_USER" >/dev/null
    echo "Locked passwordless account '$STUDENT_USER'. Set a local login password with: sudo passwd $STUDENT_USER"
  fi

  if ! command -v squid >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y squid
  fi

  if [[ -f /etc/squid/squid.conf && ! -f /etc/squid/squid.conf.cloudberryos.bak ]]; then
    cp /etc/squid/squid.conf /etc/squid/squid.conf.cloudberryos.bak
  fi
  install -m 0644 /etc/cloudberryos/squid-cloudberryos.conf /etc/squid/squid.conf

  install -m 0755 "$PREFIX/generated/cloudberryos-firewall-apply" /usr/local/sbin/cloudberryos-firewall-apply
  install -m 0644 "$PREFIX/generated/cloudberryos-firewall.service" /etc/systemd/system/cloudberryos-firewall.service
  printf '%s\n' "$STUDENT_USER" > /etc/cloudberryos/student-users

  systemctl daemon-reload
  systemctl enable --now squid
  systemctl restart squid
  systemctl enable --now cloudberryos-firewall.service

  "$PREFIX/tools/polish_user.sh" --user "$STUDENT_USER" --student "${STUDENT:-$STUDENT_USER}" --prefix "$PREFIX"

  if [[ "$AUTOLOGIN" -eq 1 ]]; then
    if [[ -f /etc/gdm3/custom.conf ]]; then
      cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.cloudberryos.bak.$(date +%Y%m%d%H%M%S)
      cat > /etc/gdm3/custom.conf <<EOF_GDM
# GDM configuration storage
# Managed by CloudberryOS setup.

[daemon]
AutomaticLoginEnable = true
AutomaticLogin = $STUDENT_USER

[security]

[debug]
#Enable=true
EOF_GDM
    else
      echo "Warning: /etc/gdm3/custom.conf not found; autologin was not configured." >&2
    fi
  fi
fi

if [[ "$INSTALL_POLICIES" -eq 1 ]]; then
  install -d /etc/firefox/policies
  install -m 0644 "$PREFIX/generated/firefox-policies.json" /etc/firefox/policies/policies.json

  install -d /etc/opt/chrome/policies/managed
  install -m 0644 "$PREFIX/generated/chrome-policies.json" /etc/opt/chrome/policies/managed/cloudberryos.json

  install -d /etc/chromium/policies/managed
  install -m 0644 "$PREFIX/generated/chrome-policies.json" /etc/chromium/policies/managed/cloudberryos.json
fi

install -m 0644 "$PREFIX/generated/cloudberryos-home.desktop" /usr/share/applications/cloudberryos-home.desktop

cat <<EOF
CloudberryOS installed.

Homepage:
  file://$PREFIX/home/index.html

CloudberryOS Browser:
  http://127.0.0.1:8765/home/index.html

Generated policy artifacts:
  $PREFIX/generated/firefox-policies.json
  $PREFIX/generated/chrome-policies.json
EOF

if [[ "$INSTALL_POLICIES" -eq 1 ]]; then
  cat <<EOF

Machine-wide policies installed:
  /etc/firefox/policies/policies.json
  /etc/opt/chrome/policies/managed/cloudberryos.json
  /etc/chromium/policies/managed/cloudberryos.json
EOF
fi

if [[ "$INSTALL_STUDENT_LOCK" -eq 1 ]]; then
  cat <<EOF

Student lock:
  user: $STUDENT_USER
  proxy: 127.0.0.1:3128
  firewall: cloudberryos-firewall.service
  passwordless: $NO_STUDENT_PASSWORD
  autologin: $AUTOLOGIN

Parent/admin users are not routed through the CloudberryOS proxy.
EOF
fi
