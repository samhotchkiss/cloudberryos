# CloudberryOS Roadmap

CloudberryOS is a kid-first computing environment: a workshop, a library, and a
small set of intentional doors. It should make creation and curiosity easy while
keeping feeds, dark patterns, and ambient internet drift out of the default
experience.

## Product Shape

The practical path is to start as an Ubuntu overlay and only become a full Ubuntu
derivative if the overlay proves valuable.

V1 should install on top of stock Ubuntu. That gives us fast iteration, normal
security updates, and a setup that other families can actually try.

A future full CloudberryOS image can still be built from the same pieces:

- a Debian package or metapackage
- browser policy templates
- curated homepage/app
- student account setup
- GNOME session defaults
- optional offline content bundles

## V1: Ubuntu Overlay

V1 is the installable foundation.

- Install with `sudo ./install.sh --student "Noah"`.
- Generate a local homepage from `config/resources.json`.
- Show a Wikipedia search box.
- Link only to curated resources like Khan Academy, Wikipedia, NASA, Smithsonian,
  Library of Congress, Project Gutenberg, and OpenStax.
- Support manually approved embedded YouTube videos by video ID.
- Use `youtube-nocookie.com` embeds, while keeping `youtube.com` blocked.
- Keep the parent/admin account fully unlocked.
- Optionally remove the student password and automatically log in to the student
  account on boot.
- Set a CloudberryOS wallpaper, curated dock, and project folders for the student.
- Optionally install Simple English Wikipedia for offline use in Kiwix.
- Route student browser traffic through a local allowlist proxy.
- Block direct student-owned web egress with per-UID firewall rules.
- Generate Firefox, Chrome, and Chromium policy artifacts from the same resource
  file for future packaging.
- Make it easy to reinstall after editing the allowlist.

V1 is deliberately simple: static files plus browser policy.

## V1 Limits

Some things should not be faked in V1.

- Browser policies are not a hard security boundary for a child with admin access.
- YouTube embeds require broad media domains like `googlevideo.com` and `ytimg.com`.
- V1 can present only approved videos, but it cannot cryptographically restrict
  `youtube-nocookie.com` to specific video IDs without HTTPS interception or a
  more specialized playback service.
- Manually approved videos are reasonable in V1, but channel allowlists are not
  enforceable without a local service.
- Time limits cannot be reliably enforced by a static homepage.
- Firefox/Chrome policy behavior needs real-device testing because embedded media
  dependencies change over time.

## V2: Cloudberry App And Local Service

V2 should replace the static homepage with a local Cloudberry service, probably
served at `http://127.0.0.1:8737/`.

Capabilities:

- Parent admin interface protected by the parent account.
- Per-child profiles: Noah, Arlo, etc.
- Resource catalog stored in SQLite or a simple local JSON database.
- "Ask Dad" or "Request a shelf" workflow for new sites.
- Approved YouTube videos shown inside the Cloudberry interface.
- Approved YouTube channels resolved into specific video IDs.
- Daily or weekly watch budgets per child, channel, or category.
- Offline-first cache for the homepage catalog and maybe selected articles/books.
- Audit log: what was opened, watched, requested, or blocked.

YouTube channel support should work by ingesting channel uploads into a local
approved-video catalog. The child should never need the YouTube homepage,
recommendations, comments, shorts, search, or sidebar.

The clean implementation is:

- parent adds a channel URL or ID
- Cloudberry fetches metadata with the YouTube Data API
- parent chooses "allow all from this channel" or approves individual videos
- Cloudberry stores allowed video IDs locally
- the child sees Cloudberry video cards, not YouTube navigation

Time limits need the local service:

- Track playback using the YouTube iframe API where possible.
- Store watch time server-side, per child and per day.
- Stop rendering playable embeds once a budget is exhausted.
- Use browser policy to allow only Cloudberry localhost plus required media
  domains, not arbitrary YouTube browsing.

For stronger enforcement, V2 may also add local firewall/proxy rules, but the
first useful version can enforce limits at the Cloudberry interface layer.

## V3: CloudberryOS Image

If the overlay proves useful, package it as a full install image.

Likely approach:

- Keep Ubuntu as the base.
- Build a `cloudberryos` Debian package.
- Build a `cloudberryos-desktop` metapackage for apps and settings.
- Publish an apt repository or signed release artifacts.
- Use Ubuntu autoinstall or image customization to create a bootable installer.
- Preconfigure GNOME, browser policies, student account creation, and Tailscale
  optional setup.

Avoid a deep Ubuntu fork unless there is a strong reason. Forking the distro means
owning update cadence, image security, hardware enablement, and release testing.
An overlay plus optional image gets most of the product value with much less
maintenance burden.

## What It Will Take

V1:

- Finish the static homepage and policy generator.
- Test Firefox snap policy behavior on Ubuntu 26.04.
- Create a real Noah account and verify non-admin restrictions.
- Validate Khan Academy video playback with YouTube blocked.
- Add a handful of approved YouTube videos and verify embeds.
- Document how parents add sites and videos.

V2:

- Build a local web app/service.
- Add parent authentication and per-child config.
- Add YouTube Data API integration and cached channel ingestion.
- Add watch-time tracking and budget enforcement.
- Package as a `.deb` with systemd units.
- Add migration from V1 JSON config.

Public release:

- Pick a license.
- Add screenshots and a plain-language safety model.
- Add an installer that is idempotent and reversible.
- Add tests for config generation.
- Test on fresh Ubuntu installs.
- Publish the repo and signed releases.

See [PACKAGING.md](PACKAGING.md) for the concrete Debian package, setup wizard,
admin panel, and update plan.
