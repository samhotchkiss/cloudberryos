#!/usr/bin/env bash
# Applies CloudberryOS child-account "polish": project folders, curated
# desktop entries, autostart, mimeapps defaults, proxy environment, Firefox
# user.js, hidden-app overrides, and GNOME gsettings. Stays a bash script in
# 0.1.0 (not ported to Python; see docs/packaging-goal.md Current State).
#
# M1 fixes (see docs/packaging-goal.md "Known prototype defects"):
#   #7  per-child desktop entries (Projects, Ask for a Shelf, Offline
#       Wikipedia) now go to ~/.local/share/applications/, never
#       /usr/share/applications (which baked one child's home path into a
#       machine-wide file); Offline Wikipedia is now keyed off the literal
#       glob wikipedia_en_simple_all_maxi_*.zim (newest match wins), not a
#       hardcoded dated filename.
#   --   the dead ~/.cloudberryos/site copy is dropped (CloudberryOS/site is
#       the one and only on-disk copy; the homepage is served over loopback
#       by cloudberryos-home@.service, never opened as a local copy).
#   #10  Firefox user.js points at the canonical
#       http://127.0.0.1:8765/home/index.html, never a file:// URI.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: polish_user.sh --user USER --student NAME --prefix PREFIX [--no-desktop]
USAGE
}

STUDENT_USER=""
STUDENT=""
PREFIX="/var/lib/cloudberryos"
NO_DESKTOP=0
HOME_URL="http://127.0.0.1:8765/home/index.html"
USERJS_MARKER="// Managed by CloudberryOS -- edits here are overwritten by cloudberryos-apply."

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
    --no-desktop)
      NO_DESKTOP=1
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
  "$HOME_DIR/CloudberryOS/site" \
  "$HOME_DIR/${STUDENT}'s Projects/Stories" \
  "$HOME_DIR/${STUDENT}'s Projects/Drawings" \
  "$HOME_DIR/${STUDENT}'s Projects/Science" \
  "$HOME_DIR/${STUDENT}'s Projects/Code" \
  "$HOME_DIR/${STUDENT}'s Projects/Questions" \
  "$HOME_DIR/${STUDENT}'s Projects/Typing"

chown -R "$STUDENT_USER:$STUDENT_USER" \
  "$HOME_DIR/.local" \
  "$HOME_DIR/CloudberryOS" \
  "$HOME_DIR/${STUDENT}'s Projects"
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.config"

# The one and only on-disk site copy the homepage server (User=%i,
# WorkingDirectory=/home/%i/CloudberryOS/site) actually serves from. There
# is no second copy under ~/.cloudberryos/site (that duplicate was dead:
# nothing ever read it).
if [[ -d "$PREFIX/home" ]]; then
  rm -rf "$HOME_DIR/CloudberryOS/site/home"
  cp -a "$PREFIX/home" "$HOME_DIR/CloudberryOS/site/home"
fi
if [[ -d "$PREFIX/assets" ]]; then
  rm -rf "$HOME_DIR/CloudberryOS/site/assets"
  cp -a "$PREFIX/assets" "$HOME_DIR/CloudberryOS/site/assets"
fi
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

# Per-child desktop entries: fix #7. These bake this child's home path, so
# they must live per-user (~/.local/share/applications), never machine-wide
# under /usr/share/applications.
PROJECTS_DIR="${HOME_DIR}/${STUDENT}'s Projects"
LOCAL_APPS_DIR="$HOME_DIR/.local/share/applications"

cat > "$LOCAL_APPS_DIR/cloudberryos-projects.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${STUDENT}'s Projects
Comment=Open the CloudberryOS projects folder
Exec=nautilus "${PROJECTS_DIR}"
Icon=cloudberryos-projects
Terminal=false
Categories=Education;
EOF

cat > "$LOCAL_APPS_DIR/cloudberryos-request-shelf.desktop" <<EOF
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

# Offline Wikipedia detection: fix #7. Upstream Kiwix renames/prunes dated
# archive files, so key off the literal glob (underscores literal, newest
# match wins) instead of a hardcoded dated filename.
MAXI_ZIM=""
if [[ -d "$HOME_DIR/Kiwix" ]]; then
  MAXI_ZIM="$(find "$HOME_DIR/Kiwix" -maxdepth 1 -type f -name 'wikipedia_en_simple_all_maxi_*.zim' 2>/dev/null | sort | tail -n 1)"
fi
if [[ -n "$MAXI_ZIM" && -f "$MAXI_ZIM" ]]; then
  cat > "$LOCAL_APPS_DIR/cloudberryos-offline-wikipedia.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Offline Wikipedia
Comment=Open Simple English Wikipedia in Kiwix
Exec=kiwix-desktop ${MAXI_ZIM}
Icon=cloudberryos-offline-wikipedia
Terminal=false
Categories=Education;
EOF
else
  rm -f "$LOCAL_APPS_DIR/cloudberryos-offline-wikipedia.desktop"
fi
chown "$STUDENT_USER:$STUDENT_USER" "$LOCAL_APPS_DIR"/cloudberryos-*.desktop 2>/dev/null || true

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

if [[ "$NO_DESKTOP" -eq 0 ]]; then
  sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/cloudberryos.png" || true
  sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.background picture-uri-dark "file:///usr/share/backgrounds/cloudberryos.png" || true
  sudo -u "$STUDENT_USER" dbus-run-session -- gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" || true
  favorites="['cloudberryos-browser.desktop', 'cloudberryos-projects.desktop', 'cloudberryos-request-shelf.desktop'"
  if [[ -f "$LOCAL_APPS_DIR/cloudberryos-offline-wikipedia.desktop" ]]; then
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
fi

MIMEAPPS="$HOME_DIR/.config/mimeapps.list"
MIMEAPPS_BAK="$HOME_DIR/.config/mimeapps.list.cloudberryos.bak"
MIMEAPPS_MARKER="# Managed by CloudberryOS"
# Only back up a genuine pre-existing (parent-authored) mimeapps.list, never
# our own prior output -- otherwise every run after the first would see
# "a file exists, no .bak yet" and spuriously back up its own last write,
# breaking idempotency (two consecutive setup runs would no longer produce
# byte-identical /home/<user> trees).
if [[ -f "$MIMEAPPS" && ! -f "$MIMEAPPS_BAK" ]] && ! head -n 1 "$MIMEAPPS" | grep -qF "$MIMEAPPS_MARKER"; then
  cp "$MIMEAPPS" "$MIMEAPPS_BAK"
fi
cat > "$MIMEAPPS" <<EOF
$MIMEAPPS_MARKER
[Default Applications]
x-scheme-handler/http=cloudberryos-browser.desktop
x-scheme-handler/https=cloudberryos-browser.desktop
text/html=cloudberryos-browser.desktop

[Added Associations]
x-scheme-handler/http=cloudberryos-browser.desktop;
x-scheme-handler/https=cloudberryos-browser.desktop;
text/html=cloudberryos-browser.desktop;
EOF
chown "$STUDENT_USER:$STUDENT_USER" "$MIMEAPPS"
if [[ "$NO_DESKTOP" -eq 0 ]]; then
  sudo -u "$STUDENT_USER" xdg-settings set default-web-browser cloudberryos-browser.desktop 2>/dev/null || true
fi

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
  install -d -o "$STUDENT_USER" -g "$STUDENT_USER" "$profile_dir"
  cat > "$profile_dir/user.js" <<EOF
$USERJS_MARKER
user_pref("browser.startup.homepage", "$HOME_URL");
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
for profile_root in "$HOME_DIR/snap/firefox/common/.mozilla/firefox" "$HOME_DIR/.mozilla/firefox"; do
  [[ -d "$profile_root" ]] || continue
  while IFS= read -r profile_dir; do
    [[ -f "$profile_dir/prefs.js" || -f "$profile_dir/times.json" ]] || continue
    write_firefox_userjs "$profile_dir"
    rm -f "$profile_dir/sessionstore.jsonlz4" "$profile_dir/sessionstore-backups"/*.jsonlz4 2>/dev/null || true
  done < <(find "$profile_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
done
chown "$STUDENT_USER:$STUDENT_USER" "$HOME_DIR/.cloudberryos" 2>/dev/null || true
