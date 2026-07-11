#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: polish_user.sh --user USER --student NAME --prefix PREFIX
USAGE
}

STUDENT_USER=""
STUDENT=""
PREFIX="/usr/share/cloudberryos"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      STUDENT_USER="${2:?Missing value for --user}"
      shift 2
      ;;
    --student)
      STUDENT="${2:?Missing value for --student}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:?Missing value for --prefix}"
      shift 2
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

if [[ -z "$STUDENT_USER" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "$STUDENT" ]]; then
  STUDENT="$STUDENT_USER"
fi

HOME_DIR="$(getent passwd "$STUDENT_USER" | cut -d: -f6)"
if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
  echo "Home directory not found for $STUDENT_USER" >&2
  exit 1
fi

install -d -o "$STUDENT_USER" -g "$STUDENT_USER" \
  "$HOME_DIR/Desktop" \
  "$HOME_DIR/.local/share/applications" \
  "$HOME_DIR/.local/bin" \
  "$HOME_DIR/.config/autostart" \
  "$HOME_DIR/.config/environment.d" \
  "$HOME_DIR/.cloudberryos/site" \
  "$HOME_DIR/CloudberryOS/site" \
  "$HOME_DIR/${STUDENT}'s Projects/Stories" \
  "$HOME_DIR/${STUDENT}'s Projects/Drawings" \
  "$HOME_DIR/${STUDENT}'s Projects/Science" \
  "$HOME_DIR/${STUDENT}'s Projects/Code" \
  "$HOME_DIR/${STUDENT}'s Projects/Questions" \
  "$HOME_DIR/${STUDENT}'s Projects/Typing"

chown -R "$STUDENT_USER:$STUDENT_USER" \
  "$HOME_DIR/.local" \
  "$HOME_DIR/.cloudberryos" \
  "$HOME_DIR/CloudberryOS" \
  "$HOME_DIR/${STUDENT}'s Projects"
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.config"

if [[ -d "$PREFIX/home" ]]; then
  rm -rf "$HOME_DIR/.cloudberryos/site/home"
  cp -a "$PREFIX/home" "$HOME_DIR/.cloudberryos/site/home"
  rm -rf "$HOME_DIR/CloudberryOS/site/home"
  cp -a "$PREFIX/home" "$HOME_DIR/CloudberryOS/site/home"
fi
if [[ -d "$PREFIX/assets" ]]; then
  rm -rf "$HOME_DIR/.cloudberryos/site/assets"
  cp -a "$PREFIX/assets" "$HOME_DIR/.cloudberryos/site/assets"
  rm -rf "$HOME_DIR/CloudberryOS/site/assets"
  cp -a "$PREFIX/assets" "$HOME_DIR/CloudberryOS/site/assets"
fi
chown -R "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.cloudberryos/site"
chown -R "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/CloudberryOS/site"

cat > "$HOME_DIR/${STUDENT}'s Projects/Start Here.txt" <<EOF
${STUDENT}'s Projects

This is where finished things go.

Stories: write something.
Drawings: save art here.
Science: notes, pictures, and questions.
Code: experiments and games.
Questions: things to ask or look up later.
Typing: typing practice notes.
EOF
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/${STUDENT}'s Projects/Start Here.txt"

cat > "$HOME_DIR/.tuxpaintrc" <<EOF
savedir=${HOME_DIR}/${STUDENT}'s Projects/Drawings
autosave=yes
startblank=yes
native=yes
EOF
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.tuxpaintrc"

cat > "$HOME_DIR/.local/bin/cloudberryos-request-shelf" <<EOF
#!/usr/bin/env bash
set -euo pipefail

project_dir="\${HOME}/${STUDENT}'s Projects/Questions"
mkdir -p "\$project_dir"
file="\$project_dir/shelf-request-\$(date +%Y-%m-%d-%H%M).txt"
cat > "\$file" <<REQUEST
I want a new shelf for:

Because I want to:

I think it belongs in CloudberryOS because:

REQUEST
if command -v gnome-text-editor >/dev/null 2>&1; then
  exec gnome-text-editor "\$file"
fi
if command -v xdg-open >/dev/null 2>&1; then
  exec xdg-open "\$file"
fi
printf '%s\n' "\$file"
EOF
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.local/bin/cloudberryos-request-shelf"
chmod 0755 "$HOME_DIR/.local/bin/cloudberryos-request-shelf"

PROJECTS_DIR="${HOME_DIR}/${STUDENT}'s Projects"
cat > /usr/share/applications/cloudberryos-projects.desktop <<EOF
[Desktop Entry]
Type=Application
Name=${STUDENT}'s Projects
Comment=Open the CloudberryOS projects folder
Exec=nautilus "${PROJECTS_DIR}"
Icon=cloudberryos-projects
Terminal=false
Categories=Education;
EOF

cat > /usr/share/applications/cloudberryos-request-shelf.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Ask for a Shelf
Comment=Write a CloudberryOS shelf request
Exec=${HOME_DIR}/.local/bin/cloudberryos-request-shelf
Icon=cloudberryos-request-shelf
Terminal=false
Categories=Education;
EOF

if [[ -f /usr/share/applications/cloudberryos-browser.desktop ]]; then
  install -m 0644 -o "$STUDENT_USER" -g "$STUDENT_USER" /usr/share/applications/cloudberryos-browser.desktop "$HOME_DIR/.config/autostart/cloudberryos-browser.desktop"
fi

cat > "$HOME_DIR/.config/autostart/update-notifier.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Update Notifier
Hidden=true
NoDisplay=true
EOF
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.config/autostart/update-notifier.desktop"

MAXI_ZIM="$HOME_DIR/Kiwix/wikipedia_en_simple_all_maxi_2026-05.zim"
if [[ -f "$MAXI_ZIM" ]]; then
  cat > /usr/share/applications/cloudberryos-offline-wikipedia.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Offline Wikipedia
Comment=Open Simple English Wikipedia in Kiwix
Exec=kiwix-desktop ${MAXI_ZIM}
Icon=cloudberryos-offline-wikipedia
Terminal=false
Categories=Education;
EOF
fi

rm -f "$HOME_DIR/Desktop"/cloudberryos-*.desktop

hide_apps=(
  apport-gtk.desktop
  hplj1020.desktop
  nm-connection-editor.desktop
  org.gnome.DejaDup.desktop
  org.gnome.DiskUtility.desktop
  org.gnome.Logs.desktop
  org.gnome.Settings.desktop
  org.gnome.Shell.Extensions.desktop
  org.gnome.Screenshot.desktop
  org.gnome.Sysprof.desktop
  org.gnome.baobab.desktop
  org.gnome.seahorse.Application.desktop
  org.stellarium.Stellarium.desktop
  org.remmina.Remmina.desktop
  org.remmina.Remmina-file.desktop
  remmina-gnome.desktop
  thunderbird.desktop
  transmission-gtk.desktop
  tuxpaint-config.desktop
  update-manager.desktop
  usb-creator-gtk.desktop
  firefox_firefox.desktop
)

for app in "${hide_apps[@]}"; do
  if [[ -f "/usr/share/applications/$app" || -f "/var/lib/snapd/desktop/applications/$app" ]]; then
    {
      echo "[Desktop Entry]"
      echo "Type=Application"
      echo "Name=Hidden"
      echo "NoDisplay=true"
      echo "Hidden=true"
    } > "$HOME_DIR/.local/share/applications/$app"
    chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.local/share/applications/$app"
  fi
done

sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/cloudberryos.png" || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.background picture-uri-dark "file:///usr/share/backgrounds/cloudberryos.png" || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" || true
favorites="['cloudberryos-browser.desktop', 'cloudberryos-projects.desktop', 'cloudberryos-request-shelf.desktop'"
if [[ -f /usr/share/applications/cloudberryos-offline-wikipedia.desktop ]]; then
  favorites="${favorites}, 'cloudberryos-offline-wikipedia.desktop'"
fi
favorites="${favorites}, 'org.gnome.Nautilus.desktop', 'org.kde.gcompris.desktop', 'tuxpaint.desktop', 'libreoffice-writer.desktop', 'org.kde.krita.desktop']"
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell favorite-apps "$favorites" || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.dash-to-dock show-trash false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.dash-to-dock show-mounts false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.dash-to-dock show-show-apps-button false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.dash-to-dock show-running false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 52 || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.ding show-home false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.ding show-trash false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.shell.extensions.ding show-volumes false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.notifications show-banners false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.sound event-sounds false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.screensaver lock-enabled false || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.session idle-delay 0 || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.system.proxy mode "manual" || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.system.proxy.http host "127.0.0.1" || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.system.proxy.http port 3128 || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.system.proxy.https host "127.0.0.1" || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.system.proxy.https port 3128 || true
sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.0.0.0/8', '::1']" || true

cat > "$HOME_DIR/.config/mimeapps.list" <<EOF
[Default Applications]
x-scheme-handler/http=cloudberryos-browser.desktop
x-scheme-handler/https=cloudberryos-browser.desktop
text/html=cloudberryos-browser.desktop

[Added Associations]
x-scheme-handler/http=cloudberryos-browser.desktop;
x-scheme-handler/https=cloudberryos-browser.desktop;
text/html=cloudberryos-browser.desktop;
EOF
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.config/mimeapps.list"
sudo -u "$STUDENT_USER" xdg-settings set default-web-browser cloudberryos-browser.desktop 2>/dev/null || true

cat > "$HOME_DIR/.config/environment.d/cloudberryos-proxy.conf" <<'EOF'
http_proxy=http://127.0.0.1:3128
https_proxy=http://127.0.0.1:3128
HTTP_PROXY=http://127.0.0.1:3128
HTTPS_PROXY=http://127.0.0.1:3128
no_proxy=localhost,127.0.0.1,::1
NO_PROXY=localhost,127.0.0.1,::1
EOF
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.config/environment.d/cloudberryos-proxy.conf"

write_firefox_userjs() {
  local profile_dir="$1"
  local homepage="file://${HOME_DIR}/CloudberryOS/site/home/index.html"
  if [[ ! -f "$HOME_DIR/CloudberryOS/site/home/index.html" ]]; then
    homepage="file://${PREFIX}/home/index.html"
  fi
  install -d -o "$STUDENT_USER" -g "$STUDENT_USER" "$profile_dir"
  cat > "$profile_dir/user.js" <<EOF
user_pref("browser.startup.homepage", "$homepage");
user_pref("browser.startup.page", 1);
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("browser.sessionstore.max_windows_undo", 0);
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
user_pref("extensions.getAddons.showPane", false);
user_pref("extensions.htmlaboutaddons.recommendations.enabled", false);
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "127.0.0.1");
user_pref("network.proxy.http_port", 3128);
user_pref("network.proxy.ssl", "127.0.0.1");
user_pref("network.proxy.ssl_port", 3128);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1");
user_pref("signon.rememberSignons", false);
EOF
  chown "$STUDENT_USER:$STUDENT_USER" "$profile_dir/user.js"
}

write_firefox_userjs "$HOME_DIR/.cloudberryos/firefox-profile"
if [[ -d "$HOME_DIR/snap/firefox/common/.mozilla/firefox" ]]; then
  while IFS= read -r profile_dir; do
    [[ -f "$profile_dir/prefs.js" || -f "$profile_dir/times.json" ]] || continue
    write_firefox_userjs "$profile_dir"
    rm -f "$profile_dir/sessionstore.jsonlz4" "$profile_dir/sessionstore-backups"/*.jsonlz4 2>/dev/null || true
  done < <(find "$HOME_DIR/snap/firefox/common/.mozilla/firefox" -mindepth 1 -maxdepth 1 -type d)
fi
