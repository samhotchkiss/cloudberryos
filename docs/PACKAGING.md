# CloudberryOS Packaging Plan

This document describes how to turn the current CloudberryOS prototype into an
easy, repeatable install for other families.

The child-facing software catalog and setup-wizard app packs are documented in
[apps.md](apps.md).

## Goals

- Install from an admin account with one package and one setup command.
- Ask the parent for the child name, student username, login choices, and app
  bundle choices.
- Keep the parent/admin account unlocked.
- Create or configure a non-admin child account.
- Apply the curated browser, local homepage, proxy, firewall, GNOME polish, and
  optional app installs idempotently.
- Provide a parent admin panel for adding resources and approved YouTube videos.
- Support updates without overwriting family-specific settings.
- Preserve an uninstall path.

## Recommended Shape

Do not fork Ubuntu for the first public version. Package CloudberryOS as an
Ubuntu overlay:

```text
cloudberryos_0.1.0_all.deb
```

The package should install commands, assets, default config, systemd units, and
documentation. The parent then runs:

```bash
sudo cloudberryos-setup
```

Later, the same package can be included in a full CloudberryOS image or Ubuntu
autoinstall profile.

## Package Layout

Target installed paths:

```text
/usr/bin/cloudberryos-setup
/usr/bin/cloudberryos-admin
/usr/bin/cloudberryos-browser
/usr/bin/cloudberryos-resource
/usr/sbin/cloudberryos-apply
/usr/share/cloudberryos/
/usr/share/cloudberryos/home/
/usr/share/cloudberryos/assets/
/usr/share/cloudberryos/tools/
/usr/share/doc/cloudberryos/
/etc/cloudberryos/
/etc/systemd/system/cloudberryos-firewall.service
/etc/systemd/system/cloudberryos-admin.service
/etc/systemd/system/cloudberryos-home@.service
```

Family/device state should live in `/etc/cloudberryos/`:

```text
/etc/cloudberryos/profile.json
/etc/cloudberryos/resources.json
/etc/cloudberryos/allowed-domains.txt
/etc/cloudberryos/install.env
/etc/cloudberryos/admin-token
```

The package should treat files under `/etc/cloudberryos/` as configuration and
avoid overwriting them on upgrade.

## First-Run Setup

`cloudberryos-setup` should be idempotent and safe to re-run.

Prompt for:

- Child display name: for example `Arlo`.
- Student username: for example `arlo`.
- Create student account if missing.
- Remove student password: yes/no.
- Enable student autologin: yes/no.
- Install recommended apps:
  - GCompris
  - Tux Paint
  - Krita
  - LibreOffice Writer
  - Kiwix
  - Godot or another coding tool
- Install offline Simple English Wikipedia: yes/no.
- Enable local/Tailscale admin panel: local only by default.
- Import starter resource/video catalog: default yes.

The setup command should then:

- Install required OS packages, including Squid and Python runtime dependencies.
- Generate homepage and policy artifacts from `/etc/cloudberryos/resources.json`.
- Configure the child account.
- Copy the homepage into the child home directory.
- Start a loopback homepage server for the child browser.
- Configure Firefox preferences for the child profile.
- Configure Squid allowlist proxy.
- Configure per-UID firewall rules for the child user.
- Apply GNOME dock, wallpaper, hidden app, and project folder settings.
- Start or restart the relevant systemd services.

## Admin Panel

V1 can ship with CLI-only administration. The public-friendly target should add
a local admin web UI:

```text
http://127.0.0.1:8766/admin
```

Optional Tailscale access can bind to the machine's Tailscale IP, but it should
be opt-in.

The admin panel should support:

- View current child profile and setup status.
- Add, edit, remove, and reorder allowed websites.
- Add approved YouTube videos by URL or video ID.
- Show video embed status and thumbnails.
- Add categories such as Learn, Explore, Read, Practice, Watch.
- Rebuild and apply homepage/proxy/firewall config.
- View recent blocked domains from Squid logs.
- Export/import family config.
- Trigger package update checks.

Authentication options:

- V1: bind to `127.0.0.1` only, requiring local admin login or SSH forwarding.
- V1.1: bind to Tailscale IP only with an admin token stored in
  `/etc/cloudberryos/admin-token`.
- Later: integrate with Linux account authentication or a small parent password
  flow.

Do not expose the admin panel on all network interfaces by default.

## YouTube Model

The current V1 model approves specific videos and embeds them with
`youtube-nocookie.com`. Direct `youtube.com` remains blocked.

Known limitation: because the child browser must allow media domains such as
`googlevideo.com` and `ytimg.com`, V1 is interface-level curation rather than a
cryptographic guarantee that only one video ID can ever be fetched.

V2 channel support should not allow the YouTube homepage. Instead:

- Parent adds a channel URL or ID.
- CloudberryOS fetches channel metadata through the YouTube Data API or RSS
  feeds.
- Parent approves the whole channel or selected videos.
- CloudberryOS stores resulting video IDs in its local catalog.
- The child sees CloudberryOS video cards only.
- Optional time limits are enforced by the local CloudberryOS service using the
  iframe API where possible.

## Update Strategy

Use apt as the long-term update mechanism.

Early private releases can be installed directly:

```bash
sudo apt install ./cloudberryos_0.1.0_all.deb
```

Public releases should use a signed apt repository or a signed GitHub release
artifact. The parent update path becomes:

```bash
sudo apt update
sudo apt upgrade
sudo cloudberryos-apply
```

Package upgrades must:

- Preserve `/etc/cloudberryos/profile.json`.
- Preserve `/etc/cloudberryos/resources.json`.
- Preserve parent admin token/settings.
- Migrate config schema when needed.
- Regenerate artifacts after upgrade.
- Restart services safely.

Add a config schema version:

```json
{
  "schema_version": 1
}
```

Provide migration scripts:

```text
/usr/share/cloudberryos/migrations/001-initial.py
/usr/share/cloudberryos/migrations/002-add-video-metadata.py
```

## Debian Package Work

Add a `debian/` directory:

```text
debian/control
debian/rules
debian/changelog
debian/copyright
debian/install
debian/conffiles
debian/cloudberryos.postinst
debian/cloudberryos.prerm
debian/cloudberryos.postrm
```

Initial package dependencies:

```text
Depends:
  python3,
  python3-venv or python3-flask/fastapi dependencies,
  squid,
  firefox | firefox-esr,
  systemd,
  iptables,
  adduser,
  sudo
Recommends:
  gcompris-qt,
  tuxpaint,
  krita,
  libreoffice-writer,
  kiwix
```

Avoid making large creative apps hard dependencies. Let setup install them based
on parent choices.

## Systemd Services

Suggested services:

```text
cloudberryos-firewall.service
  Applies per-student egress rules.

cloudberryos-admin.service
  Runs the parent admin panel.

cloudberryos-home@USER.service
  Serves /home/USER/CloudberryOS/site on 127.0.0.1 for that child.
```

The current browser launcher starts the loopback homepage server directly. That
is acceptable for the prototype, but packaging should move it to a per-user or
templated systemd service so it is observable and restartable.

## Security Model

CloudberryOS should document its safety boundary clearly:

- Parent/admin users are trusted.
- Child users should not be in `sudo`.
- The child browser is curated by local homepage, proxy, and firewall controls.
- This is not a hardened kiosk against physical attacks, boot media, or admin
  access.
- YouTube video curation in V1 is UI-level curation plus domain blocking, not a
  proof that only a specific video can be fetched.
- The admin panel must not bind publicly without authentication.

## Test Plan

Automated tests:

- `tools/build.py` generates valid homepage HTML.
- Resource config validation catches missing fields and invalid domains.
- `cloudberryos-resource add-site` updates JSON correctly.
- `cloudberryos-resource add-video` extracts video IDs correctly.
- Generated Squid allowlist contains expected domains.
- Generated browser launcher passes `bash -n`.
- Debian package builds in a clean container.

Manual fresh-install tests:

- Fresh Ubuntu laptop with existing admin account.
- Create new child user.
- Re-run setup without duplicating state.
- Reboot and verify child autologin.
- Verify homepage loads from loopback.
- Verify approved YouTube video renders.
- Verify direct `youtube.com`, Google, and Reddit are blocked for child user.
- Verify Wikipedia, Khan Academy, NASA, and TypingClub open.
- Verify parent account remains unrestricted.
- Verify uninstall removes services and restores browser/network behavior.

## Implementation Phases

Phase 1: Package the current overlay.

- Move install logic into `cloudberryos-setup`.
- Keep CLI resource management.
- Add Debian packaging.
- Add config schema version.
- Add idempotence checks.

Phase 2: Add admin web panel.

- Build a local service with a minimal HTML interface.
- Store catalog in JSON first; SQLite can come later.
- Add add/edit/remove/reorder flows.
- Add blocked-domain log view.

Phase 3: Improve updates and migrations.

- Add apt repository or signed release workflow.
- Add config migrations.
- Add GitHub Actions package builds.

Phase 4: Optional full image.

- Use the `.deb` package inside an Ubuntu autoinstall or image build.
- Keep the package as the source of truth.
- Avoid maintaining a distro fork until there is strong evidence it is needed.
