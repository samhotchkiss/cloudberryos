# CloudberryOS Packaging Plan

This document is the execution plan for turning the CloudberryOS prototype (an Ubuntu parental-controls overlay: curated homepage, allowlist proxy, per-child firewall, GNOME polish) into an installable, upgradable, removable Debian package plus a `cloudberryos-setup` command. It is written to be executed end-to-end by an autonomous coding agent with no human available. Every previously open choice is resolved in "Locked Decisions"; if something appears ambiguous, the locked decision wins, and anything not listed in the Milestones section is out of scope for the run.

## Using This Document

- Execute milestones **M0 through M4 in order**. A milestone's acceptance criteria must all pass before starting the next.
- The development host is **macOS on Apple Silicon**. Debian packages cannot be built, installed, or tested natively. All build/install/upgrade/purge verification runs in containers (Docker) or the Lima Ubuntu VM. Nothing is verified on the host itself.
- Items on the **Manual Hardware Checklist** can only be verified on a real Ubuntu laptop. They never block a milestone. Record them as deferred; do not attempt them in containers and do not fake their verification.
- Each milestone ends with a passing `ci/build-and-test.sh` run (stage scope per milestone is defined under "Test environment") and a git commit (checkpoint/rollback mechanism).
- The child-facing app catalog and setup-wizard app packs are specified in [apps.md](apps.md); it is the single source of truth for app package names.

## Goal

Ship `cloudberryos_0.1.0_all.deb` for Ubuntu 26.04 LTS: install from an admin account with one package and one setup command; parent answers a short wizard (or passes flags); child account gets the curated homepage, proxy, firewall, and GNOME polish; parents manage the catalog via CLI (and later a local admin panel reachable from the parent's other tailnet devices); `apt upgrade` preserves family settings and regenerates artifacts automatically; `apt remove`/`purge` plus one un-polish command genuinely restores the machine.

## Non-Goals (this run will NOT do these)

- No apt repository hosting, real signing-key custody, or public release publishing. (Building and consuming a *locally* signed test repo with a throwaway key inside a container **is** in scope in M3 — it exercises the upgrade path.)
- No full OS image / Ubuntu autoinstall profile.
- No YouTube channel ingestion, YouTube Data API/RSS polling, or watch-time limits (V2 design context only — see YouTube Model).
- No public-internet exposure of the admin panel (no `tailscale funnel`, no port-forwarding). Tailnet access via `tailscale serve` **is** in scope (M4) and on by default when Tailscale is present — see the Admin panel decision and M4.
- No Kiwix ZIM download automation (setup prints instructions only).
- No real-hardware validation (GNOME polish, GDM autologin, snap Firefox behavior, real IPv6 networks) — deferred manual checklist.
- No license selection by the agent: the license is recorded below as an owner decision.
- No work on `web/` (the public project landing page) or the itsalive.co deployment machinery — committed as-is in M0, never packaged.

## Current State

Not a git repo. No LICENSE, no tests, no `debian/`, no CI. Prototype pieces that **exist**:

- `install.sh` / `uninstall.sh` — root shell installers (plain `install(1)` copies, no dpkg). Superseded by this plan; in M2 `uninstall.sh` is deleted and `install.sh` moves verbatim to `tests/fixtures/prototype-install.sh` (kept only to recreate prototype state for the migration test).
- `tools/build.py` — stdlib-only generator. From `config/resources.json` it produces: homepage `home/index.html`, Firefox/Chrome/Chromium policy JSON, squid config + `allowed-domains.txt`, the `cloudberryos-browser` launcher, firewall apply script, systemd unit, desktop files. **It bakes absolute `--target` paths (file:// URIs, SITE_DIR) into artifacts**, never copies `assets/`, and never sets the executable bit.
- `tools/cloudberryos-resource.py` — catalog editor CLI (`add-site`, `add-video`, `list`). Defaults to editing `/usr/share/cloudberryos/config/resources.json`. No validation, no remove/edit, title-only dedupe, substring `youtu.be` hostname check.
- `tools/cloudberryos-apply.sh` — regenerate-and-repush after catalog edits; sources `/etc/cloudberryos/install.env`; clobbers `/etc/squid/squid.conf` wholesale.
- `tools/polish_user.sh` — all child-home mutations: project folders, site copies, autostart, mimeapps, environment.d proxy, Firefox `user.js`, app hiding, gsettings via `sudo -u ... dbus-run-session` with blanket `|| true`. Stays a bash script in 0.1.0 (not ported to Python).
- `config/resources.json` — catalog (brand, theme, resources[], youtube.videos[], extra_allow_domains). **No `schema_version` field.** The `youtube.channels` key is dead (read by nothing).
- `assets/` — `cloudberryos-home.css` (**load-bearing**: the generated homepage links `../assets/cloudberryos-home.css` and its hero background references `../assets/cloudberryos-wallpaper-3840.png`), `cloudberryos-public.css` (landing-page styling), `cloudberryos-wallpaper-3840.png` (10 MB), `cloudberryos-wallpaper.png` (2.6 MB, unused duplicate), `cloudberryos-wallpaper.svg` (unused), and four SVG icons under `icons/`. See Package layout for exactly which of these ship.
- Repo root also contains `web/` (public landing page), `ITSALIVE.md`, `CLAUDE.md`, plus `.cloudberry-deploy/` and `.itsalive` (the latter holds a live itsalive.co deploy token; both are gitignored and **must stay untracked** — asserted in M0). Everything runnable is Python stdlib + bash; no pip dependencies anywhere.

Things that **do not exist and must be built**: `cloudberryos-setup` (wizard + non-interactive mode), config validator, migrations runner, `profile.json`, admin token, nftables firewall, static (non-generated) launcher, systemd `cloudberryos-home@` unit, `debian/` packaging, un-polish command, prototype-migration logic, admin panel (M4), test suite.

**Known prototype defects that must NOT be ported** (fix during M1, do not carry over):

1. IPv4-only firewall (iptables, no ip6tables/nft) — child has completely unfiltered web egress over IPv6.
2. Firewall unit has no `ExecStop`; stopping/disabling leaves the kernel chain and per-UID jumps live until reboot.
3. `install.sh` flag-order bug: `--student-user` resets `INSTALL_POLICIES=0` at parse time, so `--install-policies --student-user kid` silently installs no policies.
4. `install.env` and `/etc/cloudberryos/student-users` are overwritten wholesale each run — re-runs silently erase the student or drop a previous child from firewall enforcement.
5. `--autologin` wholesale-replaces `/etc/gdm3/custom.conf` (destroying e.g. `WaylandEnable=false`) and accumulates a new timestamped backup every run.
6. `uninstall.sh` removes never-created paths (`/etc/squid/conf.d/cloudberryos.conf`, `cloudberryos.svg`), leaves `cloudberryos-apply`/`cloudberryos-resource` binaries, GDM autologin, live iptables rules, an un-restarted squid, and a proxy-broken child session.
7. `polish_user.sh` writes per-child desktop files (projects, request-shelf, offline-wikipedia) machine-wide to `/usr/share/applications` with one user's home path baked in, and keys offline Wikipedia to the hardcoded ZIM filename `wikipedia_en_simple_all_maxi_2026-05.zim`.
8. The launcher self-spawns `python3 -m http.server` with a PID file that is never reaped.
9. Setup never checks whether an existing student account is in `sudo`/`admin`.
10. Three artifacts disagree on the canonical homepage URL (file:// under /usr/share vs loopback vs file:// under $HOME).

## Locked Decisions

Every previously ambiguous choice, resolved. Do not revisit these mid-run.

| Decision | Value | Rationale |
|---|---|---|
| Target release | Ubuntu 26.04 LTS only (`ubuntu:26.04` image) | Deployment target per ROADMAP/apps.md; 24.04 untested and out of scope for 0.1.0 |
| Architecture | `all` | Scripts and data only; arm64 containers on Apple Silicon are valid builders |
| License | MIT (owner decision, recorded here; write `LICENSE` and `debian/copyright` from it) | Permissive so other families can adapt; unblocks debian/copyright |
| Maintainer | `Sam <s@swh.me>` | Used in `debian/control` Maintainer and changelog trailer |
| Source format | `3.0 (native)`, version `0.1.0`, no Debian revision | Repo is upstream; avoids .orig tarball requirement |
| Versions | `0.1.0` = M2 release; `0.1.1` = throwaway upgrade-test build synthesized *inside* the M3 test workspace (its changelog entry is never committed); `0.2.0` = M4 admin-panel release | Removes the "next version" guess point |
| debhelper | `debhelper-compat (= 13)`, `Rules-Requires-Root: no`, `Standards-Version: 4.7.4`, minimal `dh` rules (`%: dh $@`) | Standard modern scaffolding; 4.7.4 is current as of 2026-07 — a newer point release only yields an ignorable lintian info tag, never `--fail-on error` |
| Depends | `${misc:Depends}, python3 (>= 3.10), squid, nftables, adduser, sudo, libglib2.0-bin, dbus, xdg-utils` | stdlib-only Python; nftables per firewall decision; sudo/gsettings/dbus/xdg used by polish. No `systemd` (init-system-helpers via misc:Depends), no `iptables` |
| Firefox | NOT in Depends/Recommends. `cloudberryos-setup` verifies at runtime: `snap list firefox` is the **authoritative** check; `command -v firefox` alone is not proof (Ubuntu's `firefox` deb is a snap-transition stub that installs `/usr/bin/firefox` without the snap). A bare stub hit without the snap counts as missing; setup prints `snap install firefox` guidance | The stub needs snapd+network (fails in Docker, breaking our own CI); `firefox-esr` is not in the Ubuntu archive |
| App packs | NOT in Depends or Recommends (`Suggests` at most). Setup installs the parent's selections and records them in `profile.json` | apps.md forbids Recommends (apt installs them by default, preempting the wizard) |
| Wizard app catalog | Wizard/`--apps` package names = **backticked entries in apps.md "Ubuntu package" columns only**. Rows without a backticked package (the snap-only rows: Darktable, KolourPaint, Grapher; the entire Games table) are excluded from the V1 wizard. Recommended default selection = the 11 backticked "Recommended Essentials" packages. Coding tool = `godot3` per apps.md | Makes the app-name gate evaluable; all backticked names verified resolvable on ubuntu:26.04 as of 2026-07 |
| Python packaging | Standard library only (http.server, json, argparse). Never venv/pip at build or install time (PEP 668 blocks it anyway on modern Ubuntu). If templating is ever needed: `python3-flask` from the archive | Matches the zero-dependency prototype |
| Systemd unit location | `/usr/lib/systemd/system/`, installed via `dh_installsystemd --name=<unit>` per unit; `--no-enable --no-start` for firewall; template unit not auto-enabled | `/etc/systemd/system` is admin territory; shipping there is a lintian error and collides with prototype leftovers |
| Firewall tech | nftables `table inet cloudberryos` (one ruleset covers IPv4+IPv6, `meta skuid` per-UID match), applied atomically via `nft -f`; `ExecStop` deletes the table | Closes the IPv6 bypass; nft is Ubuntu's default backend |
| Squid integration | Whole-file replacement of `/etc/squid/squid.conf` by **cloudberryos-setup/apply only** (never maintainer scripts): single backup to `squid.conf.cloudberryos.bak`, `squid -k parse` before install, `systemctl restart squid` after, `"squid_managed": true` recorded in profile.json, restore+restart on un-setup. Apply must be an **idempotent no-op on squid.conf when content is unchanged** (write + restart only on diff) so the postinst-triggered apply doesn't churn another package's conffile on routine upgrades. Do NOT use conf.d drop-ins | Debian Policy 10.7.4 bars maintainer scripts from another package's conffile; the conf.d route is broken (stock `http_access allow localhost` precedes the include, so drop-in denies never fire for localhost clients) |
| Generated artifacts | **Never generated at package build time.** Produced on-device by setup/apply into `/var/lib/cloudberryos/{home,generated}`, with `assets/` copied alongside. The .deb ships only static inputs | build.py bakes absolute paths; building in the debhelper sandbox ships broken artifacts; regenerating into /usr/share violates FHS and dpkg -V |
| Live catalog | `/etc/cloudberryos/resources.json`, seeded by setup from the read-only shipped copy `/usr/share/cloudberryos/config/resources.json` if absent. The package ships **nothing** under `/etc/cloudberryos/`; no `debian/conffiles` file at all | Program-modified config must not be conffiles (Policy 10.7.3); debhelper auto-marks shipped /etc files as conffiles |
| State file | `/etc/cloudberryos/profile.json` is the single source of truth (schema below). Prototype `install.env` lifecycle: postinst migrates it into profile.json on first configure and renames it to `install.env.migrated` (rollback safety); `cloudberryos-setup` deletes the `.migrated` file at the end of its first successful run. `cloudberryos-apply` reads only profile.json and fails loudly if required fields are missing | One state file, one migration moment, one deletion moment — no guess points |
| Canonical homepage URL | `http://127.0.0.1:8765/home/index.html` everywhere: Firefox/Chrome policies, desktop files, user.js, launcher | Removes baked file:// paths; snap Firefox confinement cannot open file:// under /usr/share or hidden dot-dirs anyway |
| Ports | 8765 child homepage server, 8766 admin panel (M4), 3128 squid. ROADMAP's 8737 is superseded. V1 is single-child; 8765 is fixed | One registry, no collisions |
| Setup interface | Every prompt has a flag; `--non-interactive` errors on any unanswered required question; setup fails fast (never hangs) when stdin is not a TTY and answers are missing. Two independent auto-degrade axes (service-ops and desktop) are specified under "cloudberryos-setup interface" | Container tests and unattended re-runs depend on it |
| Browser policies (machine-wide) | Opt-in `cloudberryos-setup --install-browser-policies` (default off, recorded in profile.json), written by apply, removed on the un-setup path when profile says installed | They lock ALL accounts including the parent; default conflicts with "parent stays unlocked" |
| Migrations | `schema_version` (int, missing = 0) in profile.json and resources.json; runner = `cloudberryos-apply --migrate`, invoked by postinst on `configure`; runs `/usr/share/cloudberryos/migrations/NNN-*.py` ascending for NNN > current version; each idempotent, atomic temp-file+rename, bumps version; failure aborts postinst with configs untouched. **When neither profile.json nor resources.json exists (fresh install), the runner exits 0 as an explicit no-op.** Ship only `001` (or none + runner + test) | Concrete runner semantics; fresh `apt install` must never fail its own postinst |
| Update flow | postinst (configure): run migrations (fail hard), then if profile.json exists run `cloudberryos-apply` (on failure: warn, tell parent to run `sudo cloudberryos-apply`, still exit 0). Parent path is just `sudo apt update && sudo apt upgrade`; `sudo cloudberryos-apply` remains documented only for after catalog edits | Automatic regeneration; a runtime apply problem must not wedge apt |
| Offline Wikipedia | V1: no download. Setup prints kiwix.org instructions plus size (~3.3 GB) and disk-space guidance. Detection via the literal glob `~/Kiwix/wikipedia_en_simple_all_maxi_*.zim` (underscores literal; newest match wins) | Upstream renames/prunes dated files; multi-GB downloads must never run in CI |
| Admin panel | M4 (version 0.2.0). Python stdlib `http.server`, root service, **always binds only `127.0.0.1:8766`**, **token auth mandatory from the first commit** (spec below). `admin_panel` is tri-state (`off`/`local`/`tailnet`). In M1–M3 the panel does not exist, so setup only records the flag, **default `off`**. In M4 the setup default becomes **`tailnet` when Tailscale is installed and up, else `local`** (override with `--admin-panel off\|local\|tailnet`); `tailnet` exposes the loopback port to the tailnet via `tailscale serve`, never the public internet | Owner decision: parents manage from any device on their tailnet. Loopback is reachable by the child and tailnet membership is not auth, so the token is mandatory regardless of exposure |
| Kiwix package name | `kiwix` (desktop binary `kiwix-desktop`) — verify with `apt-get install --dry-run` in-container during M1 (confirmed present in the 26.04 archive as of 2026-07). If the dry-run ever fails, drop Kiwix from the wizard with a warning and continue — never hard-fail the milestone | Names drift; verify, don't trust, don't stall |
| Service-test environment | **Lima VM is the primary path** for all service-level checks: `limactl start template:experimental/ubuntu-26.04` (the `ubuntu-lts` template resolves to 24.04 on this host — do not use it). A derived systemd Docker image (Dockerfile under "Test environment") is an optional alternative; if booting systemd under Docker Desktop misbehaves in any way, fall back to Lima immediately rather than debugging Docker | Stock `ubuntu:26.04` has no systemd/`/sbin/init`; systemd-in-Docker on macOS is fiddly and must never stall the run |

## Package Design

### Package layout (shipped paths only)

```text
/usr/bin/cloudberryos-setup                     (new; M1)
/usr/bin/cloudberryos-browser                   (static script — no longer generated)
/usr/bin/cloudberryos-resource
/usr/sbin/cloudberryos-apply
/usr/libexec/cloudberryos/cloudberryos-firewall-apply   (static; nftables)
/usr/lib/systemd/system/cloudberryos-firewall.service
/usr/lib/systemd/system/cloudberryos-home@.service
/usr/share/cloudberryos/tools/                  (build.py, polish_user.sh — polish stays bash in 0.1.0)
/usr/share/cloudberryos/assets/                 (cloudberryos-home.css, icons/*.svg, cloudberryos-wallpaper-3840.png)
/usr/share/cloudberryos/config/resources.json   (read-only starter catalog)
/usr/share/cloudberryos/migrations/
/usr/share/applications/cloudberryos-browser.desktop
/usr/share/applications/cloudberryos-home.desktop
/usr/share/icons/hicolor/scalable/apps/cloudberryos-*.svg   (4 icons)
/usr/share/backgrounds/cloudberryos.png         (symlink -> ../cloudberryos/assets/cloudberryos-wallpaper-3840.png;
                                                 polish gsettings hardcodes this path; the site copy needs the PNG
                                                 under assets/, so ship the 10 MB file once and symlink)
/usr/share/doc/cloudberryos/
```

NOT shipped from `assets/`: `cloudberryos-public.css` (landing-page styling), `cloudberryos-wallpaper.png` (2.6 MB duplicate), `cloudberryos-wallpaper.svg` (unused). M4 (0.2.0) adds: `/usr/bin/cloudberryos-admin`, `/usr/lib/systemd/system/cloudberryos-admin.service`. Do not ship either in 0.1.0.

Runtime-created (never in the .deb): everything under `/etc/cloudberryos/` (`profile.json`, `resources.json`, `allowed-domains.txt`, `student-users`, `admin-token` 0600 root:root) and `/var/lib/cloudberryos/` (generated site + policies + copied assets). Per-child desktop entries (projects, request-shelf, offline-wikipedia) go to `~/.local/share/applications/`, never `/usr/share/applications`.

### profile.json (schema_version 1)

```json
{
  "schema_version": 1,
  "child_name": "Arlo",
  "student_user": "arlo",
  "no_password": true,
  "autologin": true,
  "apps": ["gcompris-qt", "tuxpaint"],
  "offline_wikipedia": false,
  "admin_panel": "off",
  "install_browser_policies": false,
  "squid_managed": true,
  "deferred_service_setup": false
}
```

Setup **merges** into an existing profile (prompt defaults come from saved values); it never rewrites from scratch. `/etc/cloudberryos/student-users` uses append-or-dedupe semantics, never truncation.

### Systemd units

`cloudberryos-firewall.service`: static packaged unit. `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=/usr/libexec/cloudberryos/cloudberryos-firewall-apply`, `ExecStop=/usr/libexec/cloudberryos/cloudberryos-firewall-apply --teardown`, `After=network-pre.target`. Apply generates a `.nft` file (flush/recreate `table inet cloudberryos`; per UID from `/etc/cloudberryos/student-users`: accept `oif lo` **except reject tcp dport 8766 first** (admin port, M4), reject `tcp dport {80,443}` and `udp dport 443`) and runs `nft -f`. `--teardown` runs `nft delete table inet cloudberryos`. Loopback allowance covers `::1` as well. Shipped with `--no-enable --no-start`; setup runs `systemctl enable --now` after creating the student.

`cloudberryos-home@.service`: template. `[Service] User=%i`, `WorkingDirectory=/home/%i/CloudberryOS/site`, `ConditionPathExists=/home/%i/CloudberryOS/site`, `ExecStart=/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1`, `Restart=on-failure`; `[Install] WantedBy=multi-user.target`. Enabled per child by setup: `systemctl enable --now cloudberryos-home@USER`. `User=%i` is mandatory: http.server follows symlinks, and a root-run server over a child-writable docroot is an arbitrary-file-read-as-root primitive. In the same milestone, delete the launcher's self-spawned `http.server`/PID-file logic — it would race the unit for port 8765; the launcher only health-checks the URL and tells the parent to check `systemctl status cloudberryos-home@<user>` on failure. Setup kills any pre-existing launcher-spawned server holding 8765 before enabling the unit.

### cloudberryos-setup interface

Root-only. Interactive wizard is a thin wrapper over the flag path. Flags (defaults from existing profile.json):

```text
--child-name NAME          --student-user USER
--no-password | --keep-password        (default keep)
--autologin | --no-autologin           (--no-autologin actively reverts AutomaticLoginEnable)
--apps recommended|none|LIST           (LIST = comma-separated package names, validated against the
                                        apps.md backticked set; unknown name = fatal argument error
                                        listing valid names; "recommended" = the 11 Recommended
                                        Essentials packages; installed via apt)
--offline-wikipedia | --no-offline-wikipedia   (default no; prints instructions only)
--admin-panel tailnet|local|off        (records flag only until M4; M4 default = tailnet when Tailscale
                                        is installed and up, else local; tailnet exposes via `tailscale serve`)
--install-browser-policies             (default off)
--import-catalog | --no-import-catalog (default yes; copies starter catalog to /etc if absent; "no" writes a minimal empty catalog)
--non-interactive                      (error on any missing required answer)
--no-desktop                           (see environment detection below)
--remove-student-config USER           (un-polish; see Uninstall)
```

Legacy mapping (renamed, not preserved): `--student` → `--child-name`, `--no-student-password` → `--no-password`. All option interactions are resolved **after** parsing completes; conflicting flags (e.g. `--no-password --keep-password`) produce an explicit non-zero error, never a position-dependent override.

**Environment detection — two independent degrade axes, both exiting 0:**

1. **Service operations** (auto-detected, not a flag): when systemd is not running as PID 1 (`/run/systemd/system` absent), setup skips every `systemctl` call, the nft apply, and the squid restart — it still writes all config files, still runs `squid -k parse` when the squid binary is present, prints one warning per skipped operation, and records `"deferred_service_setup": true` in profile.json. A later run with systemd available completes the deferred operations and clears the flag. This is what makes every plain-Docker acceptance test in M1/M2 executable.
2. **`--no-desktop`**: skips snap/GNOME/GDM/dconf/gsettings/`xdg-settings` work. Auto-enabled when `/usr/bin/gnome-shell` is absent or `systemd-detect-virt -c` reports a container; always available explicitly.

Setup behavior highlights: verify Firefox at runtime (snap-authoritative check per Locked Decisions); if the student username already exists, check `id -nG USER` for `sudo`/`admin` (plus `sudo -l -U USER` / sudoers.d) and **refuse** unless the parent explicitly confirms demotion — never auto-demote the account running setup or the system's only administrator; GDM autologin edits only the `AutomaticLoginEnable`/`AutomaticLogin` keys in `[daemon]` of `/etc/gdm3/custom.conf` in place, keeps at most one `.bak`, and no-ops with a warning if the file is absent; squid per the locked strategy (allowlist file written **before** any squid parse/reload — squid fails to start if the dstdomain file is missing); generate artifacts via build.py `--target /var/lib/cloudberryos` and copy assets alongside; polish the child home (with the M1 fixes); delete `install.env.migrated` after the first successful run.

### Maintainer scripts

Written from the desired end-state — **never ported from uninstall.sh**.

- `preinst`: if `/etc/cloudberryos/resources.json` is absent and a prototype catalog exists at `/usr/share/cloudberryos/config/resources.json`, copy it to `/etc/cloudberryos/resources.json` (preserves parent edits before dpkg overwrites the old path).
- `postinst` (configure): if a prototype `/etc/cloudberryos/install.env` exists, migrate it into profile.json and rename it to `install.env.migrated` (setup deletes the `.migrated` file after its first successful run); run `cloudberryos-apply --migrate` (fail hard; explicit success no-op when no state files exist yet); if profile.json exists, run `cloudberryos-apply` (warn-and-continue on failure; apply's squid write is a no-op when content is unchanged); print a warning if prototype files remain under `/usr/local` (cleanup itself belongs to setup — Policy 9.1.2 bars maintainer scripts from `/usr/local`). Fully non-interactive; tolerate `systemctl` absence in chroots.
- `prerm`: stop units (dh autoscripts; ExecStop makes the firewall stop actually remove kernel rules).
- `postrm` (purge): remove `/etc/cloudberryos` and `/var/lib/cloudberryos`; print a notice if `/etc/squid/squid.conf.cloudberryos.bak` still exists (squid restore belongs to setup's un-setup path, not postrm). Plain remove leaves `/etc/cloudberryos` in place. Maintainer scripts never touch `/home` and never delete user accounts.

### Migration from prototype installs (executed by cloudberryos-setup, first run)

Detect via the prototype's own artifacts (`/usr/local/bin/cloudberryos-browser`, `/usr/local/sbin/cloudberryos-apply`) — install.env presence triggers only postinst's state migration, never this cleanup. Then: (1) remove `/usr/local/bin/cloudberryos-{browser,resource}` and `/usr/local/sbin/cloudberryos-{apply,firewall-apply}` after fingerprinting them as CloudberryOS-generated (marker/shebang grep) — Ubuntu resolves `/usr/local` first, so stale copies otherwise win forever; (2) `systemctl disable --now` the prototype `/etc/systemd/system/cloudberryos-firewall.service`, delete it, `daemon-reload`, enable the packaged unit; (3) restore `/etc/squid/squid.conf` from `squid.conf.cloudberryos.bak` if present, then write the new managed config per the locked strategy and restart squid; (4) preserve all `/etc/cloudberryos` contents as family state. Never direct users to the prototype `uninstall.sh` (it rm -rf's the catalog).

### Uninstall

Documented two-step, in this order (the un-polish tool ships in the package being purged):

```bash
sudo cloudberryos-setup --remove-student-config USER
sudo apt purge cloudberryos
```

`--remove-student-config` reverses polish for that account: delete `~/.config/environment.d/cloudberryos-proxy.conf`, the browser autostart and update-notifier suppressor, hidden-app override desktop files, per-child desktop entries, CloudberryOS `user.js` from `~/.cloudberryos/firefox-profile` and every snap/non-snap Firefox profile, `~/.local/bin/cloudberryos-request-shelf`, `~/.tuxpaintrc`, `~/.cloudberryos`; restore mimeapps defaults; reset gsettings (proxy mode `none`, screensaver lock on, idle-delay default, favorites, notifications, sounds); disable `cloudberryos-home@USER`; revert GDM autologin keys; restore squid from the `.bak` and restart it (per `squid_managed`); keep the child account and Projects/CloudberryOS folders by default (flag to remove). After the sequence, the child account has a working default browser and direct, proxy-free network access. The file-level parts of this path are container-tested in M2; only the desktop/GDM parts are deferred to hardware.

## Milestones

### Test environment (applies to all milestones)

- **Plain Docker (`ubuntu:26.04`)**: package build, lintian, file-level install/upgrade/remove/purge assertions, unit tests, artifact smoke tests, non-interactive setup (service ops auto-deferred, `--no-desktop` auto-enabled). All installs use `apt-get install --no-install-recommends` so snapd is never touched. No live-service or nft assertions here (no systemd PID 1, no NET_ADMIN).
- **Service-level environment — primary: Lima VM** (`limactl start template:experimental/ubuntu-26.04`; the `ubuntu-lts` template resolves to 24.04 on this host — do not use): unit enable/start, squid restart, `nft` ruleset assertions, prototype-migration test. Assert rule *presence* (`nft list ruleset`), not live IPv6 traffic. Optional alternative — a derived systemd image (stock `ubuntu:26.04` has **no** `/sbin/init` or systemd, so it must be built first):

  ```dockerfile
  FROM ubuntu:26.04
  RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus adduser sudo python3 squid nftables libglib2.0-bin xdg-utils \
      && apt-get clean
  CMD ["/sbin/init"]
  ```

  Run with `docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw IMAGE` (`--privileged` grants NET_ADMIN). If systemd fails to boot under Docker Desktop for any reason, switch to Lima immediately — never spend milestone time debugging Docker-systemd.
- Anything needing snapd-in-Docker, a display, or GDM is out of automated scope → Manual Hardware Checklist.
- **`ci/build-and-test.sh` accumulates stages**: `unit` (M0+, pytest in plain Docker), `setup` (M1+, artifact + setup + idempotency checks in plain Docker), `package` (M2+, build/lint/lifecycle in plain Docker), `upgrade` (M3+, local-repo upgrade in plain Docker), and a `--services` flag running the service-level and prototype-migration checks in the Lima VM/systemd container. The default invocation runs all plain-Docker stages defined so far; `--services` is mandatory for each milestone's acceptance gate (M2 onward) but not for every incremental commit.

### M0 — Repo scaffolding

Deliverable: versioned repo with tests and a container CI gate.

Tasks: `git init` + initial commit (a `.gitignore` exists covering `.cloudberry-deploy/`, `.itsalive`, `__pycache__/`, `*.pyc`, `.DS_Store` — verify/extend, don't recreate; `web/`, `ITSALIVE.md`, `CLAUDE.md` are committed as-is and remain out of scope/never packaged); write `LICENSE` (MIT, per Locked Decisions); pytest suite for `tools/build.py` and `tools/cloudberryos-resource.py` (stdlib-only; runnable on macOS and in-container) covering: homepage generation, domain collection/collapse, an explicit assertion that a sample catalog yields the expected **leading-dot dstdomain** entries in `allowed-domains.txt` (subdomain-collapse — the Security Model's whole-domain claim rests on this), add-site/add-video round-trips, video-ID extraction, and **schema_version tolerance** (build.py accepts a catalog containing `schema_version`; resource round-trips preserve it — these assert existing behavior); `ci/build-and-test.sh` with the `unit` stage.

Acceptance: `docker run --rm -v "$PWD":/src -w /src ubuntu:26.04 bash -c 'apt-get update -q && apt-get install -yq --no-install-recommends python3 python3-pytest && python3 -m pytest tests/'` passes; `git ls-files` contains neither `.itsalive` nor anything under `.cloudberry-deploy/` and `git check-ignore` confirms both (the `.itsalive` file holds a live deploy token — it must never be committed); repo committed.

### M1 — Code rework: setup command, firewall, canonical URLs, validator

Deliverable: the runtime code the package will ship, prototype defects fixed.

Tasks:
1. Implement `cloudberryos-setup` per the interface spec (non-interactive mode, both auto-degrade axes, profile merge, sudo-group check, GDM targeted edit, squid strategy, prototype migration, `--remove-student-config`, `--no-desktop`).
2. Replace the generated firewall with the static nftables `cloudberryos-firewall-apply` (+ `--teardown`) and static unit per spec.
3. De-template `cloudberryos-browser` into a static script (site dir/port from config, not baked SYSTEM_SITE_DIR); delete its self-spawned http.server. **Remove these build.py generators entirely** (their outputs become static shipped files): launcher, `cloudberryos-browser.desktop`, `cloudberryos-home.desktop`, firewall script, firewall service. build.py keeps generating only: `home/index.html`, Firefox/Chrome policy JSON, `allowed-domains.txt`, squid config. Canonicalize the homepage URL to `http://127.0.0.1:8765/home/index.html` in the remaining generators, the static desktop files, and polish's user.js. Note: no port changes needed in policy *allowlists* — Firefox match patterns cannot express ports and port-less Chrome entries match all ports; but narrow Chrome's loopback allowlist entry to `127.0.0.1:8765` (Chrome supports ports; Firefox cannot — do not attempt there).
4. Repoint `cloudberryos-resource.py` `DEFAULT_CONFIG` and `cloudberryos-apply` to `/etc/cloudberryos/resources.json`; apply builds into `/var/lib/cloudberryos` and copies assets alongside; apply touches squid only when `squid_managed` is true, and only rewrites/restarts on content diff.
5. Implement `cloudberryos-resource validate` (invoked by setup and apply before build.py): `resources` must be a list; each resource needs non-empty `title` and http(s) `url` with a host; `allow_domains`/`extra_allow_domains` entries must match `^[a-z0-9][a-z0-9.-]*$` after normalization (no scheme/port/path/userinfo); `category` any non-empty string (no enum — categories are extensible); `youtube.videos` entries need `title` + `youtube_id` matching `[A-Za-z0-9_-]{11}`; `search.action` must be a valid http(s) URL; unknown keys tolerated. Fix the `youtu.be` substring hostname check to a strict host match.
6. Polish fixes: per-child desktop files to `~/.local/share/applications/`; the literal ZIM glob `wikipedia_en_simple_all_maxi_*.zim` instead of a dated filename; drop the dead `~/.cloudberryos/site` copy; `student-users` merge semantics.

Acceptance — all inside one `ubuntu:26.04` container prepared with `apt-get install -yq --no-install-recommends python3 python3-pytest squid nftables adduser sudo systemd libglib2.0-bin dbus xdg-utils` (`systemd` provides `systemd-analyze` only; it is **not** PID 1, so setup's service-deferral path is itself under test). In this order:

1. pytest green, including new validator tests.
2. `bash -n` on all shell scripts.
3. `cloudberryos-setup --non-interactive --child-name Test --student-user testkid --keep-password --no-autologin --apps none --no-offline-wikipedia --admin-panel off` exits 0: creates `testkid`, writes `/etc/cloudberryos/{profile.json,resources.json,allowed-domains.txt,student-users}`, generates `/var/lib/cloudberryos/{home,generated}` + copied `assets/`, installs the managed `/etc/squid/squid.conf` (+ single `.bak`), prints per-skip warnings for deferred service ops, and records `"deferred_service_setup": true`.
4. `squid -k parse -f /etc/squid/squid.conf` succeeds (must run **after** step 3 — parse fails if the referenced `/etc/cloudberryos/allowed-domains.txt` doesn't exist yet).
5. `python3 -m json.tool` on generated policy JSONs; both reference only `http://127.0.0.1:8765/home/index.html` as the homepage (no `file://` anywhere in any artifact).
6. Stage units at `/usr/lib/systemd/system/`, then `systemd-analyze verify cloudberryos-firewall.service cloudberryos-home@testkid.service` — the template is verified only as an **instantiated** name; run after step 3 so ExecStart binaries and `/home/testkid/CloudberryOS/site` exist; require exit 0 (stderr warnings acceptable).
7. A second identical setup run exits 0 changing nothing: recursive sha256 manifests of `/etc/cloudberryos`, `/var/lib/cloudberryos`, `/home/testkid`, and `/etc/squid` (excluding `*.log`) are identical across the two runs.
8. Negative/compat tests: `--no-password --keep-password` exits non-zero with a clear conflict message; a legacy invocation using `--student Test --no-student-password` maps to the new flags and yields the expected profile.json.
9. App-name gate: for **every backticked package name in apps.md's "Ubuntu package" columns** (rows without one are excluded from the wizard and from this gate), `apt-get install --dry-run --no-install-recommends NAME` succeeds. On any failure: correct apps.md or record the package as unavailable and exclude it from the wizard in the same change (Kiwix included, per its locked contingency) — never stall the milestone on an archive change.

### M2 — Debian packaging and lifecycle

Deliverable: `cloudberryos_0.1.0_all.deb` passing build, lint, and full lifecycle in containers. In the same change, once lifecycle tests pass: delete `uninstall.sh`; move `install.sh` verbatim to `tests/fixtures/prototype-install.sh` (kept solely to recreate prototype state for the migration test in this and later CI runs); update README and ROADMAP. Concrete doc edits: README — Quick Install becomes `sudo apt install ./cloudberryos_0.1.0_all.deb` + `sudo cloudberryos-setup`, the Uninstall section becomes the two-step sequence, Browser Policy Notes references `--install-browser-policies`, `/usr/local/bin/cloudberryos-browser` becomes `/usr/bin/cloudberryos-browser`, Add-A-Resource drops the reinstall-from-checkout path (keeps `cloudberryos-resource`/`cloudberryos-apply`); ROADMAP — the `sudo ./install.sh --student "Noah"` bullet becomes the package flow, and V2's port 8737 becomes 8766.

Tasks: `debian/` per Locked Decisions (control, rules, changelog, copyright, install, maintainer scripts; **no debian/conffiles**); `dh_installsystemd` overrides with `--name=` per unit and the enable/start flags specified; ship layout per Package Design; maintainer scripts per spec; `package` stage in CI.

Acceptance:

```bash
# Build + lint + extract the artifact (dpkg-buildpackage writes to ../, which is
# ephemeral container filesystem — copy it into the bind mount or it is lost)
docker run --rm -v "$PWD":/src -w /src ubuntu:26.04 bash -c \
  'apt-get update -q && apt-get install -yq --no-install-recommends devscripts debhelper lintian && \
   dpkg-buildpackage -us -uc -b && lintian --fail-on error ../cloudberryos_0.1.0_all.deb && \
   mkdir -p /src/dist && cp ../cloudberryos_0.1.0_all.deb /src/dist/'
# Lifecycle in a fresh plain-Docker container (file-level assertions; setup defers service ops)
#   apt-get install --no-install-recommends ./dist/cloudberryos_0.1.0_all.deb
#     -> postinst succeeds on a machine with NO /etc/cloudberryos state (migrations runner no-ops)
#   non-interactive setup; assert /etc/cloudberryos + /var/lib/cloudberryos manifests
#   cloudberryos-setup --remove-student-config testkid; assert file-level un-polish:
#     environment.d proxy conf, autostart, update-notifier suppressor, hidden-app overrides,
#     per-child desktop entries, ~/.cloudberryos all gone; mimeapps restored;
#     /etc/squid/squid.conf byte-identical to the .bak (squid_managed);
#     child account and Projects/CloudberryOS folders remain
#   re-run setup; reinstall same version; remove; purge
#   assert: purge removes /etc/cloudberryos and /var/lib/cloudberryos; remove keeps /etc/cloudberryos
```

Service-level checks (**Lima VM or systemd container — this whole block, including the prototype-migration test, requires a booted systemd; it cannot run in plain Docker**):

- Units enable/start after setup; `nft list ruleset` shows `table inet cloudberryos` with the student UID rules; `systemctl stop cloudberryos-firewall` (and package remove) leaves **no** cloudberryos table in `nft list ruleset`; squid restarts with the managed config; `curl -fsS http://127.0.0.1:8765/home/index.html` succeeds with `cloudberryos-home@testkid` running; after `--remove-student-config`, `cloudberryos-home@testkid` is disabled.
- Prototype-migration test: run `tests/fixtures/prototype-install.sh --student Test --student-user testkid` (its unconditional `systemctl daemon-reload`/`enable --now` calls under `set -euo pipefail` are exactly why this test is pinned here), edit the catalog via the prototype `cloudberryos-resource`, install the .deb over it, run setup; assert: no `cloudberryos-*` files under `/usr/local`; `command -v cloudberryos-apply` = `/usr/sbin/cloudberryos-apply`; the running firewall unit's ExecStart is the packaged path; the catalog edit survives in `/etc/cloudberryos/resources.json`; `install.env` was migrated into profile.json, renamed `.migrated` by postinst, and deleted by setup's first successful run.

### M3 — Upgrades and migrations

Deliverable: proven upgrade path preserving family state.

Tasks: migrations runner per Locked Decisions (including the fresh-install no-op); postinst wiring; local signed test repo using **apt-ftparchive + a throwaway GPG key** — no other tooling:

```bash
gpg --batch --passphrase '' --quick-generate-key repo-test@cloudberryos.invalid default default never
mkdir -p /srv/repo && cp dist/*.deb /srv/repo/ && cd /srv/repo
apt-ftparchive packages . > Packages && apt-ftparchive release . > Release
gpg --batch --yes --clearsign -o InRelease Release
gpg --export > /srv/repo/pubkey.gpg
echo 'deb [signed-by=/srv/repo/pubkey.gpg] copy:/srv/repo ./' > /etc/apt/sources.list.d/cloudberryos-test.list
```

The `0.1.1` used below is synthesized **inside the test workspace** (temporary changelog entry + differing starter catalog); it is never committed to the repo's changelog.

Acceptance (plain-Docker container): install 0.1.0, run setup, edit `/etc/cloudberryos/resources.json`, record hashes of `profile.json`, `admin-token` (if present), and `/etc/squid/squid.conf`; build 0.1.1 and upgrade with `apt-get -y` — completes with **zero stdin interaction** (no conffile prompt is possible since nothing under /etc is shipped); parent's catalog edit survives; `profile.json` and `admin-token` are byte-identical; artifacts under `/var/lib/cloudberryos` regenerate; `/etc/squid/squid.conf` is byte-identical (apply's unchanged-content no-op path). A failing migration aborts postinst with configs untouched and `dpkg --configure -a` recovers after the fix. The same upgrade also passes end-to-end via the local signed repo (`apt update && apt upgrade`).

### M4 — Admin panel (V1 spec, locked)

Deliverable: `cloudberryos-admin` + service, shipped as **version 0.2.0**, which must re-pass the M2 build/lint/lifecycle acceptance and an M3-style upgrade test from 0.1.0 → 0.2.0.

Spec: Python stdlib `http.server`, run as root by `cloudberryos-admin.service` (`Restart=on-failure`) — root is acceptable for V1 **only because token auth is mandatory on every request from the first commit**; say so in the unit's comments. Bind `127.0.0.1:8766`. Routes: `GET /admin` (single-page login + UI); `GET /api/status` (child profile summary from profile.json, service states, last apply result); `GET/POST/PUT/DELETE /api/resources` (PUT = edit an existing resource, addressed by title); `POST /api/resources/reorder`; `POST /api/videos`; `POST /api/apply` (runs `/usr/sbin/cloudberryos-apply`, returns output); `GET /api/blocked?n=100` (tail TCP_DENIED from `/var/log/squid/cloudberryos-access.log` — the path build.py actually generates); `GET /api/export`, `POST /api/import`. Storage: `/etc/cloudberryos/resources.json` via the same load/save code as `cloudberryos-resource`.

Auth: loopback binding is **not** a boundary — the child is a local user, the firewall's loopback accept, proxy no_proxy, and browser policies all reach 127.0.0.1. Setup generates `/etc/cloudberryos/admin-token` (`python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`, root:root **0600** — never the prototype's 0644 pattern), printed at end of setup and retrievable via `sudo cat`; login form exchanges it for an HttpOnly SameSite=Strict session cookie; CSRF token on all state-changing requests; rotation via re-running setup or `cloudberryos-admin rotate-token`. Defense in depth: the M1 firewall already rejects the child UID on loopback tcp/8766, and its interface-agnostic 443 reject also blocks the child from the `tailscale serve` HTTPS endpoint on the machine's own tailnet address — so no new firewall rule is required for the child (making the 8766 reject interface-agnostic in M4 is optional belt-and-suspenders). **Tailnet access** (`--admin-panel tailnet`, the M4 default when Tailscale is installed and up): the service still binds only `127.0.0.1:8766`; setup runs `tailscale serve` (NOT `funnel`) to publish it to the tailnet over HTTPS at the machine's MagicDNS name — this gives a valid cert and sidesteps any boot-time IP-bind race, since serve config lives in tailscaled and is reapplied automatically. Tailnet membership is **not** authentication (default ACLs are allow-all across a user's own devices and shared nodes), so the token stays mandatory. Prereq: setup checks that MagicDNS + HTTPS certs are enabled for the tailnet and prints one-line guidance if not; if Tailscale is installed-but-down or absent, setup falls back to `local` with a message. Tailscale is NOT a package dependency (it is not in the Ubuntu archive) — it is detected at runtime. Deferred to V1.1: `tailscale funnel` (public-internet exposure), thumbnails, embed-status checks, package-update checks.

Acceptance (container): all endpoints, including `GET /api/status`, reject unauthenticated requests; token file is 0600; from a child-UID process, connecting to 127.0.0.1:8766 is refused by the firewall (nft rule assertion in the service-level environment); add-site → edit via PUT → apply → regenerated allowlist round-trip works; the service binds only 127.0.0.1 (assert no non-loopback listener); with `--admin-panel tailnet` and a mocked/absent `tailscale`, setup invokes the serve configuration (assert the command + args) and degrades cleanly to `local` when Tailscale is down; 0.2.0 passes the M2 gates and the 0.1.0 → 0.2.0 upgrade preserves profile.json, resources.json, and admin-token. Actual tailnet reachability + MagicDNS HTTPS from a second device is on the Manual Hardware Checklist (needs a real tailnet + auth key; not container-testable).

## Manual Hardware Checklist (deferred; never blocks the goal)

On a real Ubuntu 26.04 laptop: GDM autologin and reboot behavior; snap Firefox honors `/etc/firefox/policies/policies.json` (documented location for the snap, but honoring has been historically inconsistent — mozilla/policy-templates#936); GNOME gsettings effects (wallpaper, dock favorites, hidden apps, no screen lock); approved YouTube embed playback; on an IPv6-enabled dual-stack network, `curl -6 https://example.com` fails for the child user while allowlisted sites work; Wikipedia/Khan Academy/NASA/TypingClub open and youtube.com/Google/Reddit are blocked for the child; parent account fully unrestricted; from a second device on the same tailnet, the admin panel loads over HTTPS at the machine's MagicDNS name and rejects any request without the token; after the two-step uninstall, child browsing works direct with no proxy.

## Security Model (honest statement — reuse in parent-facing docs)

- Parent/admin accounts are trusted. The child account must not be in `sudo`/`admin`; setup enforces this check.
- **Enforced boundary**: the firewall service rejects child-UID outbound TCP 80/443 and UDP 443 (QUIC) on **both IPv4 and IPv6** (nftables inet table, after M1), forcing web traffic through the local squid allowlist proxy on 127.0.0.1:3128. The allowlist grants **whole domains including all subdomains** (leading-dot dstdomain); HTTPS is tunneled via CONNECT, so no path- or page-level filtering is possible at the proxy.
- **Not blocked**: all other ports, DNS, loopback (except the admin port for the child UID), and non-web protocols. The squid proxy accepts any local user (src-localhost ACL, no auth) — only the child is *forced* through it; other users are simply unrestricted anyway.
- Browser/profile settings (user.js, environment.d proxy, GNOME proxy, mimeapps) are child-editable convenience defaults, **not** enforcement. The squid+firewall pair is the real control. Machine-wide browser policies are optional, lock every account including the parent, and Chrome's `data:*`/`blob:*` allowlist entries are a known filter-bypass vector.
- The admin panel always binds only 127.0.0.1 and requires token auth on every request, because the child can reach 127.0.0.1 by design. When Tailscale is present it is exposed to the **tailnet** (default on in M4) via `tailscale serve` — tailnet-only, never the public internet, over MagicDNS HTTPS. Tailnet membership is not authentication, so the token is mandatory regardless; the child is blocked from the tailnet-facing endpoint by the same firewall 443 reject.
- This is not a hardened kiosk: no protection against physical attacks, boot media, or an admin-privileged user. Default polkit `allow_active` abilities (mount removable media, join Wi-Fi, power off) remain available to the child.

## YouTube Model

V1 approves specific videos and embeds them via `youtube-nocookie.com`; direct `youtube.com` stays blocked. **Honest limitation**: the proxy allowlists all of `youtube-nocookie.com` (plus `ytimg.com` and `googlevideo.com` — the entire YouTube media CDN), so any `https://www.youtube-nocookie.com/embed/<id>` URL the child navigates to will play. Approved-video curation in V1 is purely what the homepage presents. No layer enforces approved IDs: the generated browser policies contain per-video embed exceptions, but they are redundant today because the same policies also allow the whole domain. (Optional later cleanup: drop the domain-wide `youtube-nocookie.com` browser-policy allowance so the per-ID exceptions become meaningful; squid must keep it for embeds to work at all.)

**V2 — OUT OF SCOPE for this goal; recorded for design continuity only.** Do not implement channel ingestion, the YouTube Data API or RSS polling, or watch-time limits; the `"channels": []` key in resources.json stays empty and unwired. Design sketch preserved: parent adds a channel URL/ID → CloudberryOS resolves uploads to individual video IDs (Data API or RSS) → parent approves all-or-selected → IDs land in the local catalog → child sees CloudberryOS video cards only → optional watch budgets enforced by the local service via the iframe API. This depends on product decisions (approval UX, API-key vs RSS, enforcement) requiring a human.

## Out of Scope / Later

- **Public releases**: signed apt repository or signed GitHub release artifacts; GitHub Actions package builds; real key custody. The M3 local-repo test proves the mechanics.
- **Full image (V3)**: use the .deb inside Ubuntu autoinstall/image customization; keep the package as the source of truth; avoid a distro fork.
- **Dedicated squid instance**: a second instance (`squid -n cloudberryos -f /etc/cloudberryos/squid.conf`) would leave the squid package's conffile untouched entirely, but requires extending the enforcing `usr.sbin.squid` AppArmor profile; revisit if conffile-prompt friction on squid upgrades proves painful.
- **Multi-child support**: per-user home-server ports via `EnvironmentFile=/etc/cloudberryos/home-%i.env`; today V1 is explicitly single-child.
- **Admin panel V1.1+**: `tailscale funnel` (public-internet exposure — M4 does tailnet-only `serve`), thumbnails/embed status, update checks, non-root privilege split (dedicated service user + root oneshot for apply), Linux-account auth.
- **SQLite catalog**, audit log, request-a-shelf workflow, per-child profiles — V2 service territory (ROADMAP).
