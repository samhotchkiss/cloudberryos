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
sudo ./install.sh --student "Noah"
```

For a locked student account while keeping the parent account unlocked:

```bash
sudo ./install.sh --student "Noah" --student-user noah
```

For a young child device with no login password:

```bash
sudo ./install.sh --student "Noah" --student-user noah --no-student-password --autologin
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

Edit [config/resources.json](config/resources.json), then reinstall from the
source checkout:

```bash
sudo ./install.sh --student "Noah"
```

On an installed laptop, parent/admin users can edit the installed catalog:

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
/usr/local/bin/cloudberryos-browser
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
sudo ./install.sh --student "Noah" --install-policies
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
sudo ./uninstall.sh
```

## Roadmap

See [docs/ROADMAP.md](docs/ROADMAP.md).

For the public install/update plan, see
[docs/PACKAGING.md](docs/PACKAGING.md).

For the proposed child-facing software catalog and setup-wizard app packs, see
[docs/apps.md](docs/apps.md).
