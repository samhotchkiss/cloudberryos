# CloudberryOS App Catalog

This document defines the app philosophy, proposed V1 catalog, setup-wizard
choices, and current test-machine findings for CloudberryOS.

## Product Principle

CloudberryOS should curate for safety and comprehensibility, not artificial
simplicity. Children should have access to powerful tools for creating art,
photos, music, writing, software, and games. We should constrain unsafe network
access and destructive system administration, not limit creative depth.

An installed application does not automatically belong in the child launcher.
CloudberryOS should maintain an explicit child-facing catalog and hide
administrative and irrelevant desktop entries from the student account. Parent
accounts remain fully unlocked.

The child interface should describe activities rather than Linux package names:

- Make a Beat
- Edit a Photo
- Animate a Story
- Write a Book
- Code Music
- Build a Game
- Explore the World

## V1 Setup Experience

The setup wizard should present app packs with individual app checkboxes. A
parent can accept the recommended selection or customize it.

The core `.deb` should not declare optional app packs as Debian `Depends` or
`Recommends`; apt normally installs recommended packages before the parent can
choose. Instead, `cloudberryos-setup` should install selected packages, record
the selection in `/etc/cloudberryos/profile.json`, and allow the parent to add
or remove packs later.

Prefer packages from the Ubuntu archive. Use a Snap, Flatpak, or external
repository only when there is no suitable native package and the source,
permissions, maintenance status, and update behavior have been reviewed.

## Recommended Essentials

These should be selected by default in the setup wizard.

| Activity | Application | Ubuntu package | Purpose |
| --- | --- | --- | --- |
| Explore Activities | GCompris | `gcompris-qt` | Broad elementary learning suite |
| Paint and Draw | Tux Paint | `tuxpaint` | Approachable drawing for younger children |
| Practice Math | Tux Math | `tuxmath` | Game-based arithmetic practice |
| Practice Typing | Tux Typing | `tuxtype` | Local typing games and lessons |
| Explore Offline | Kiwix | `kiwix` | Offline reference library |
| Write a Story | LibreOffice Writer | `libreoffice-writer` | Writing and document creation |
| Edit a Photo | GIMP | `gimp` | Photo editing, collage, text, layers, and animation |
| Browse Photos | Shotwell | `shotwell` | Import, organize, crop, rotate, and correct photos |
| Make a Beat | Hydrogen | `hydrogen` | Pattern-based drum machine |
| Build a Song | LMMS | `lmms` | Sequencing, instruments, samples, and automation |
| Record a Sound | Audacity | `audacity` | Recording, editing, layering, and remixing audio |

Files, Calculator, the image viewer, media player, and a basic text editor
should remain available as utilities without prominent homepage tiles.

Kiwix content is separate from the application. The wizard must show download
size and available disk space before installing offline Wikipedia archives.

## Art, Photos, and Publishing

Photo tools are child-facing creative tools, not parent-only utilities.
Complexity alone is not a reason to hide an application from a child.

| Activity | Application | Ubuntu package/source | Default |
| --- | --- | --- | --- |
| Paint and Illustrate | Krita | `krita` | Prominent option |
| Draw Logos and Diagrams | Inkscape | `inkscape` | Optional |
| Make a Book or Magazine | Scribus | `scribus` | Optional |
| Advanced Photography | Darktable | Snap currently installed on Arlo's laptop | Optional |
| Make Pixel Art | KolourPaint | Snap currently installed on Arlo's laptop | Optional |

Tux Paint gives children a quick start, GIMP provides deep photo and collage
capabilities, and Krita provides a path into illustration. Darktable is useful
for a child interested in serious photography or RAW processing, but its
workflow is specialized enough that it should not be preselected.

The camera application should be child-facing when present. Photos and
recordings should remain local unless a parent explicitly enables sharing.

## Music and Beats

Music creation is a first-class category. The starter selection is Hydrogen,
LMMS, and Audacity.

| Activity | Application | Ubuntu package | Default |
| --- | --- | --- | --- |
| Make a Beat | Hydrogen | `hydrogen` | Selected |
| Build a Song | LMMS | `lmms` | Selected |
| Record or Remix Audio | Audacity | `audacity` | Selected |
| DJ and Mix | Mixxx | `mixxx` | Optional |
| Code Music | Sonic Pi | `sonic-pi` | Prominent option |
| Write Sheet Music | MuseScore | `musescore` | Optional |
| Record a Band | Ardour | `ardour` | Advanced |
| Compose with MIDI | Rosegarden | `rosegarden` | Advanced |
| Build a Modular Studio | Carla and synth plugins | `carla`, `drumkv1`, `samplv1`, `synthv1` | Advanced |

Chrome Music Lab is a strong candidate for the curated web catalog. Before it
ships, its required domains and media requests must be tested with the
CloudberryOS proxy and firewall. Account-based social music platforms should
not be enabled by default.

## Animation and Filmmaking

This is a particularly valuable creative pathway because it combines writing,
art, photography, sound, performance, and editing.

| Activity | Application | Ubuntu package | Default |
| --- | --- | --- | --- |
| Draw an Animation | Pencil2D | `pencil2d` | Prominent option |
| Make Stop Motion | Stopmotion | `stopmotion` | Prominent option |
| Edit a Movie | Kdenlive | `kdenlive` | Optional |
| Make a Simple Movie | OpenShot | `openshot-qt` | Alternative to Kdenlive |
| Record the Screen | OBS Studio | `obs-studio` | Optional |

CloudberryOS should normally recommend one video editor, not install both.
OpenShot is simpler; Kdenlive has more room to grow. Sample projects and a
CloudberryOS media folder would make these much more approachable.

## Coding and Making

| Activity | Application | Ubuntu package | Default |
| --- | --- | --- | --- |
| Learn with a Turtle | KTurtle | `kturtle` | Optional |
| Learn Python | Thonny | `thonny` | Prominent option |
| Make a Python Game | Pygame with Thonny | `python3-pygame` | Optional |
| Build a Game | Godot | `godot3` on Ubuntu 26.04 | Optional |
| Code Music | Sonic Pi | `sonic-pi` | Optional |

CloudberryOS should ship starter projects rather than opening programming tools
into an empty workspace. Scratch is not currently available as a native Ubuntu
26.04 package; its browser experience or another packaging source needs a
separate network, privacy, and maintenance review.

## Science, Geography, and Mathematics

| Activity | Application | Ubuntu package | Default |
| --- | --- | --- | --- |
| Explore Earth and Maps | Marble | `marble` | Prominent option |
| Learn Countries | KGeography | `kgeography` | Optional |
| Explore the Sky | KStars | `kstars` | Optional |
| Explore the Night Sky | Stellarium | `stellarium` | Optional |
| Explore Chemistry | Kalzium | `kalzium` | Optional |
| Experiment with Geometry | Kig | `kig` | Optional |
| Build Physics Experiments | Step | `step` | Optional |
| Explore Molecules | Avogadro | `avogadro` | Advanced |
| Plot Equations | Grapher | currently Snap on Arlo's laptop | Optional |

Stellarium must never start automatically. Its previous repeated appearance on
Noah's laptop made the machine difficult to use. It remains a worthwhile tool
when selected deliberately and its launcher behavior has been verified.

## Electronics and 3D Making

These tools become especially useful when a family or school has access to
Arduino boards, a 3D printer, or a makerspace.

| Activity | Application | Ubuntu package | Default |
| --- | --- | --- | --- |
| Program an Arduino | Arduino IDE | `arduino` | Optional |
| Design a Circuit | Fritzing | `fritzing` | Optional |
| Design in 3D with Code | OpenSCAD | `openscad` | Optional |
| Prepare a 3D Print | PrusaSlicer | `prusa-slicer` | Optional |
| Model and Animate in 3D | Blender | `blender` | Advanced |

Hardware-oriented packs should explain what physical equipment is expected and
should not be preselected on a general-purpose installation.

## Games and Simulations

Games can be worthwhile creative, strategic, or recreational experiences. They
should be individually selectable.

| Category | Applications | Default |
| --- | --- | --- |
| Building world | Luanti, configured for local/offline play | Optional |
| Strategy and systems | Micropolis, OpenTTD | Optional |
| Puzzles | GNOME Chess, Mines, Sudoku | Optional |
| Platform game | SuperTux | Optional |
| Recreation | Space Cadet Pinball | Optional |

Luanti is especially interesting as an open building and modding environment,
but public servers and online content should be disabled unless a parent
enables them. Climate Trail is not a universal default because of its
post-apocalyptic subject matter and proprietary package.

V2 can add per-category schedules or time budgets for recreational games and
approved video channels. Creative and educational tools should not inherit a
game time limit merely because they are engaging.

## Books and Media

| Activity | Application | Ubuntu package | Default |
| --- | --- | --- | --- |
| Read an Ebook | Foliate | `foliate` | Optional |
| Manage a Large Library | Calibre | `calibre` | Advanced parent/reader option |
| Scan Artwork or Documents | Document Scanner | `simple-scan` | Utility |

A simple child-facing bookshelf backed by local EPUB and PDF files would be
more coherent than exposing Calibre's full library-management interface to
every student. This is a good candidate for later CloudberryOS integration.

## Curated Web Activities

These are browser resources rather than installed applications, but belong in
the same child-facing catalog:

- Wikipedia, with images
- Khan Academy
- NASA
- TypingClub
- Approved individual YouTube videos
- Approved YouTube channels presented inside CloudberryOS
- Chrome Music Lab, pending allowlist testing

The normal YouTube browsing interface remains blocked. Approved media should be
presented through CloudberryOS, with channel time limits planned for V2.

## Hidden from the Student Account

These may remain installed for the parent or operating system, but should not
appear in the student app grid, dock, homepage, or search results:

- Terminals, app stores, package installers, and Software Sources
- Firmware, firewall, disk, user, login, and network administration tools
- Remote desktop clients such as Remmina
- BitTorrent clients such as Transmission
- Email clients unless a parent explicitly enables one
- Duplicate settings panels, file managers, and utilities from another desktop
  environment

Hiding launchers is user-interface curation, not the security boundary. The
student account remains non-admin, and browser/network restrictions are
enforced independently.

## Arlo Laptop Evaluation

Inventory date: 2026-07-11. No changes were made during evaluation.

Arlo's laptop runs Ubuntu 26.04 LTS on an Intel Core Ultra 7 155H with 14 GiB of
RAM and Intel Arc graphics. It has ample performance for every app here.

It already includes Kiwix, KTurtle, LibreOffice, Shotwell, GIMP, Darktable,
KolourPaint, Grapher, Wike, Micropolis, OpenTTD, SuperTux, several puzzle games,
Space Cadet Pinball, Climate Trail, Tux Paint, Tux Math, and Tux Typing. It has
no dedicated music-production application.

Several kid-oriented apps are unofficial Snaps even though Ubuntu 26.04 offers
native packages. The first CloudberryOS package test should prefer native
packages for predictable installation and updates.

The laptop has both Ubuntu GNOME and Ubuntu MATE installed, producing duplicate
launchers and settings tools. CloudberryOS should support stock Ubuntu GNOME
first and apply an explicit child-facing catalog. It should not remove another
desktop environment without a separate parent choice.

The 468 GB root filesystem currently has about 58 GB free. Normal applications
will fit, but offline libraries require a storage check during setup.

## Open Decisions

- Whether essentials are preselected individually or through one recommended
  control.
- Which sample projects, beats, images, stories, and source files should ship.
- Whether deselecting an app uninstalls it or only removes it from the child's
  catalog.
- Which Kiwix libraries to offer and how to obtain reliable size metadata.
- Whether recreational time limits belong in V1 or V2.
- Whether CloudberryOS should eventually provide a single Projects gallery for
  work created across all these applications.
