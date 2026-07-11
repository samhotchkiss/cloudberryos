# CloudberryOS

A small Ubuntu setup for kids who should use a computer as a workshop and library,
not as an open feed.

CloudberryOS installs:

- a local browser homepage with curated resources
- a Wikipedia search box
- embedded, parent-approved YouTube videos
- a Cloudberry browser launcher for the student account
- a local allowlist proxy
- per-student network rules that block direct web access
- a CloudberryOS wallpaper, curated dock, and student project folders

The first target is Ubuntu with Firefox. Browser policy files are still generated
for future packaging, but the default install keeps the parent account unlocked.

## Quick Install

On the target laptop:

```bash
sudo apt install ./cloudberryos_0.1.0_all.deb
sudo cloudberryos-setup
```

`cloudberryos-setup` with no flags runs an interactive wizard (child name,
student username, login choices, app packs). Every wizard question also has a
flag, for example:

```bash
sudo cloudberryos-setup --child-name "Noah" --student-user noah
```

For a young child device with no login password and automatic login:

```bash
sudo cloudberryos-setup --child-name "Noah" --student-user noah --no-password --autologin
```

Recommended creative/offline apps:

```bash
sudo apt install gcompris-qt tuxpaint stellarium krita kiwix godot3
```

Recommended offline library:

```text
Simple English Wikipedia for Kiwix
https://download.kiwix.org/zim/wikipedia/
```

Then open the student browser:

```text
CloudberryOS Browser
```

For student accounts, CloudberryOS Browser serves a readable copy of the
homepage on loopback:

```text
http://127.0.0.1:8765/home/index.html
```

The student files live at `/home/noah/CloudberryOS/site/`. The local HTTP
server is used because YouTube embeds need a normal web origin; direct
`youtube.com` remains blocked by the student proxy.

## Add A Resource

Parent/admin users edit the installed catalog with `cloudberryos-resource`,
then regenerate and re-apply artifacts with `cloudberryos-apply`:

```bash
sudo cloudberryos-resource list
sudo cloudberryos-resource add-site \
  --title "Example Museum" \
  --url "https://example.org/kids" \
  --category "Explore" \
  --summary "A short parent-written description." \
  --allow-domain example.org
sudo cloudberryos-apply
```

Each resource can declare:

- `title`
- `url`
- `category`
- `summary`
- `allow_domains`
- optional `search`

Approved YouTube videos can be added under `youtube.videos`:

```bash
sudo cloudberryos-resource add-video \
  --title "Why Do Stars Twinkle?" \
  --video "https://www.youtube.com/watch?v=exampleId11" \
  --summary "A short astronomy video."
sudo cloudberryos-apply
```

CloudberryOS embeds videos with `youtube-nocookie.com` and keeps `youtube.com`
itself blocked.

The homepage and browser allowlist are generated from the same file.

## Network Model

CloudberryOS keeps parent/admin accounts unlocked. Student web traffic is routed
through a local Squid proxy on `127.0.0.1:3128`; direct student-owned TCP web
traffic is blocked by a small systemd-managed firewall rule.

Generated allowlist:

```text
/etc/cloudberryos/allowed-domains.txt
```

Cloudberry browser launcher:

```text
/usr/bin/cloudberryos-browser
```

Firewall service:

```text
cloudberryos-firewall.service
```

## Browser Policy Notes

Machine-wide browser policy files are generated as artifacts, but installing
them globally would also lock the parent account. They are not enabled by the
default student-user install.

To intentionally install machine-wide policies:

```bash
sudo cloudberryos-setup --install-browser-policies
```

Firefox policies are written to:

```text
/etc/firefox/policies/policies.json
```

Chrome policies are written to:

```text
/etc/opt/chrome/policies/managed/cloudberryos.json
```

Chromium policies are written to:

```text
/etc/chromium/policies/managed/cloudberryos.json
```

If enabled, these policies block all URLs by default and then allow curated
domains. This is not a hardened security boundary against a user with
administrator access or boot media access. Use a non-admin child account.

## Uninstall

```bash
sudo cloudberryos-setup --remove-student-config USER
sudo apt purge cloudberryos
```

The first step reverses the child-account polish (proxy environment,
autostart, curated desktop entries, Firefox `user.js`, GNOME settings) and
restores `/etc/squid/squid.conf`; it keeps the child's account and
`Projects`/`CloudberryOS` folders. The second step removes the package itself
and the family catalog/state under `/etc/cloudberryos`. A plain
`sudo apt remove cloudberryos` (without `purge`) leaves `/etc/cloudberryos` in
place.

## Roadmap

See [docs/ROADMAP.md](docs/ROADMAP.md).

For the public install/update plan, see
[docs/PACKAGING.md](docs/PACKAGING.md).

For the proposed child-facing software catalog and setup-wizard app packs, see
[docs/apps.md](docs/apps.md).
