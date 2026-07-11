"""Shared helpers for cloudberryos-setup and cloudberryos-apply.

Stdlib only (no pip dependencies, matches the rest of the prototype).
This module lives in tools/ next to build.py and cloudberryos-resource.py
so it ships to /usr/share/cloudberryos/tools/ alongside them (see
docs/packaging-goal.md "Package layout"). It is loaded via importlib by
usr/bin/cloudberryos-setup and usr/sbin/cloudberryos-apply, both of which
resolve this directory the same way they resolve build.py.
"""
import importlib.util
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent

ETC_DIR = Path("/etc/cloudberryos")
VAR_DIR = Path("/var/lib/cloudberryos")
PROFILE_PATH = ETC_DIR / "profile.json"
RESOURCES_PATH = ETC_DIR / "resources.json"
ALLOWED_DOMAINS_PATH = ETC_DIR / "allowed-domains.txt"
STUDENT_USERS_PATH = ETC_DIR / "student-users"
INSTALL_ENV_PATH = ETC_DIR / "install.env"
INSTALL_ENV_MIGRATED_PATH = ETC_DIR / "install.env.migrated"
ADMIN_TOKEN_PATH = ETC_DIR / "admin-token"

SQUID_CONF_PATH = Path("/etc/squid/squid.conf")
SQUID_BAK_PATH = Path("/etc/squid/squid.conf.cloudberryos.bak")

GDM_CONF_PATH = Path("/etc/gdm3/custom.conf")

HOMEPAGE_URL = "http://127.0.0.1:8765/home/index.html"

SCHEMA_VERSION = 1

DEFAULT_PROFILE = {
    "schema_version": SCHEMA_VERSION,
    "child_name": None,
    "student_user": None,
    "no_password": False,
    "autologin": False,
    "apps": [],
    "offline_wikipedia": False,
    "admin_panel": "off",
    "install_browser_policies": False,
    "squid_managed": False,
    "deferred_service_setup": False,
}


# ---------------------------------------------------------------------------
# Path resolution (works both from a repo checkout and from an installed
# package layout -- see docs/packaging-goal.md "Package layout").
# ---------------------------------------------------------------------------

def _first_existing(candidates):
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def find_repo_root():
    """Best-effort repo root for dev/CI use: tools/ is directly under it."""
    return TOOLS_DIR.parent


def find_starter_catalog():
    return _first_existing([
        Path("/usr/share/cloudberryos/config/resources.json"),
        find_repo_root() / "config" / "resources.json",
    ])


def find_assets_src():
    return _first_existing([
        Path("/usr/share/cloudberryos/assets"),
        find_repo_root() / "assets",
    ])


def find_apps_doc():
    # NOT /usr/share/doc/cloudberryos/ -- this file is read at runtime (the
    # wizard app-name gate, parse_apps_catalog() below), not just human
    # documentation, and Debian's own Docker base images ship a dpkg
    # path-exclude=/usr/share/doc/* rule (see /etc/dpkg/dpkg.cfg.d/excludes)
    # that silently drops everything there except copyright/changelog.* on
    # every dpkg-based install -- which would make this unreadable in
    # exactly the containers docs/packaging-goal.md mandates for testing.
    return _first_existing([
        Path("/usr/share/cloudberryos/apps.md"),
        find_repo_root() / "docs" / "apps.md",
    ])


# ---------------------------------------------------------------------------
# Module loading (build.py / cloudberryos-resource.py are not importable by
# normal `import` -- same technique as tests/conftest.py).
# ---------------------------------------------------------------------------

_MODULE_CACHE = {}


def _load_module(module_name, file_path):
    if module_name in _MODULE_CACHE:
        return _MODULE_CACHE[module_name]
    spec = importlib.util.spec_from_file_location(module_name, file_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    _MODULE_CACHE[module_name] = module
    return module


def load_build_module():
    return _load_module("cb_build", TOOLS_DIR / "build.py")


def load_resource_module():
    return _load_module("cb_resource", TOOLS_DIR / "cloudberryos-resource.py")


# ---------------------------------------------------------------------------
# systemd / environment detection
# ---------------------------------------------------------------------------

def systemd_available():
    """True when systemd is running as PID 1 (service ops are possible)."""
    return Path("/run/systemd/system").is_dir()


def gnome_shell_present():
    return Path("/usr/bin/gnome-shell").exists()


def running_in_container():
    try:
        result = subprocess.run(
            ["systemd-detect-virt", "-c"],
            capture_output=True, text=True, timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def run(cmd, **kwargs):
    """subprocess.run wrapper; never raises on nonzero exit by default."""
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    try:
        return subprocess.run(cmd, **kwargs)
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(cmd, 127, stdout="", stderr=str(exc))


# ---------------------------------------------------------------------------
# JSON / file helpers
# ---------------------------------------------------------------------------

def load_json(path, default=None):
    path = Path(path)
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def atomic_write(path, content, mode=0o644):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def write_json_atomic(path, data, mode=0o644):
    atomic_write(path, json.dumps(data, indent=2, sort_keys=True) + "\n", mode=mode)


def read_text_or_none(path):
    path = Path(path)
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8")


def backup_once(path, bak_path):
    """Copy path to bak_path only if bak_path does not already exist yet
    (the "single backup" rule -- never overwrite an existing backup)."""
    path = Path(path)
    bak_path = Path(bak_path)
    if path.exists() and not bak_path.exists():
        shutil.copy2(path, bak_path)
        return True
    return False


# ---------------------------------------------------------------------------
# Profile handling
# ---------------------------------------------------------------------------

def load_profile():
    data = load_json(PROFILE_PATH, default=None)
    if data is None:
        return {}
    return data


def save_profile(profile):
    merged = dict(DEFAULT_PROFILE)
    merged.update(profile)
    merged["schema_version"] = SCHEMA_VERSION
    write_json_atomic(PROFILE_PATH, merged, mode=0o644)
    return merged


# ---------------------------------------------------------------------------
# Prototype install.env migration (docs/packaging-goal.md "State file" /
# postinst spec under "Maintainer scripts"). Distinct from the M3
# schema_version migrations runner (cloudberryos-apply --migrate) -- this
# handles the one-time prototype-era install.env -> profile.json move, not
# ascending NNN-*.py schema migrations.
# ---------------------------------------------------------------------------

def migrate_install_env():
    """If a prototype /etc/cloudberryos/install.env exists, fold its
    values into profile.json (never clobbering fields an existing
    profile.json already has) and rename it to install.env.migrated.
    cloudberryos-setup deletes the .migrated file after its first
    successful run. Returns True if a migration was performed, False if
    install.env was absent (a no-op fresh-install is always safe).

    install.env is written by the prototype's install.sh using bash's
    `printf '%q'` quoting, so the only robust way to read it back is to
    source it with bash rather than hand-parse KEY=value lines.
    """
    if not INSTALL_ENV_PATH.exists():
        return False

    script = 'set -a; . "$1"; printf \'%s\\n\' "$STUDENT" "$STUDENT_USER" "$INSTALL_POLICIES"'
    result = subprocess.run(
        ["bash", "-c", script, "bash", str(INSTALL_ENV_PATH)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"cloudberryos: failed to parse {INSTALL_ENV_PATH}: {result.stderr.strip()}"
        )

    lines = result.stdout.splitlines()
    student = lines[0] if len(lines) > 0 else ""
    student_user = lines[1] if len(lines) > 1 else ""
    install_policies = lines[2] if len(lines) > 2 else "0"

    profile = dict(load_profile())
    if student and not profile.get("child_name"):
        profile["child_name"] = student
    if student_user and not profile.get("student_user"):
        profile["student_user"] = student_user
    if install_policies == "1" and not profile.get("install_browser_policies"):
        profile["install_browser_policies"] = True
    save_profile(profile)

    os.replace(INSTALL_ENV_PATH, INSTALL_ENV_MIGRATED_PATH)
    return True


# ---------------------------------------------------------------------------
# resources.json seeding + validation
# ---------------------------------------------------------------------------

MINIMAL_CATALOG = {
    "schema_version": SCHEMA_VERSION,
    "brand": "CloudberryOS",
    "default_student": "Explorer",
    "theme": {"accent": "#2f6f73"},
    "resources": [],
    "youtube": {"videos": [], "channels": []},
    "extra_allow_domains": [],
}


def ensure_resources_catalog(import_catalog):
    """Seed /etc/cloudberryos/resources.json if it does not exist yet.
    Never overwrites an existing (possibly parent-edited) catalog."""
    if RESOURCES_PATH.exists():
        return RESOURCES_PATH, False
    if import_catalog:
        starter = find_starter_catalog()
        if starter is None:
            raise SystemExit("cannot find a starter resources.json to import")
        ETC_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copy2(starter, RESOURCES_PATH)
        os.chmod(RESOURCES_PATH, 0o644)
    else:
        ETC_DIR.mkdir(parents=True, exist_ok=True)
        write_json_atomic(RESOURCES_PATH, MINIMAL_CATALOG, mode=0o644)
    return RESOURCES_PATH, True


def validate_resources(path):
    resource_module = load_resource_module()
    config = resource_module.load_config(Path(path))
    return resource_module.validate_config(config)


# ---------------------------------------------------------------------------
# Artifact build (home/index.html, policies, allowed-domains.txt, squid conf)
# ---------------------------------------------------------------------------

def build_artifacts(resources_path, target_dir, student_name):
    build_module = load_build_module()
    config = build_module.load_config(Path(resources_path))
    target = Path(target_dir)
    student = student_name or config.get("default_student", "Explorer")

    build_module.write_text(target / "home" / "index.html", build_module.render_home(config, target, student))
    build_module.write_json(target / "generated" / "firefox-policies.json", build_module.build_firefox_policy(config))
    build_module.write_json(target / "generated" / "chrome-policies.json", build_module.build_chrome_policy(config))
    allowed_domains_text = "\n".join(build_module.squid_domain_lines(config)) + "\n"
    build_module.write_text(target / "generated" / "allowed-domains.txt", allowed_domains_text)
    squid_conf_text = build_module.build_squid_config()
    build_module.write_text(target / "generated" / "squid-cloudberryos.conf", squid_conf_text)

    return {
        "allowed_domains": allowed_domains_text,
        "squid_conf": squid_conf_text,
    }


def write_browser_policies(var_dir):
    """Install the opt-in machine-wide browser policies (default off; see
    the "Browser policies (machine-wide)" Locked Decision). Never called
    unless the parent explicitly asked for --install-browser-policies."""
    firefox_policy = (Path(var_dir) / "generated" / "firefox-policies.json").read_text(encoding="utf-8")
    chrome_policy = (Path(var_dir) / "generated" / "chrome-policies.json").read_text(encoding="utf-8")
    atomic_write(Path("/etc/firefox/policies/policies.json"), firefox_policy, mode=0o644)
    atomic_write(Path("/etc/opt/chrome/policies/managed/cloudberryos.json"), chrome_policy, mode=0o644)
    atomic_write(Path("/etc/chromium/policies/managed/cloudberryos.json"), chrome_policy, mode=0o644)


def copy_assets(target_dir):
    assets_src = find_assets_src()
    if assets_src is None:
        return False
    dest = Path(target_dir) / "assets"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(assets_src, dest)
    return True


# ---------------------------------------------------------------------------
# Squid conffile management (whole-file replacement; idempotent no-op on an
# unchanged candidate). NEVER called from a maintainer script -- see the
# Squid-integration Locked Decision.
# ---------------------------------------------------------------------------

def apply_squid(new_conf_text, deferred, warn):
    """Write /etc/cloudberryos/allowed-domains.txt (always, unconditionally,
    BEFORE any squid parse) then, if the candidate squid.conf content
    differs from what is currently on disk, parse-validate it, take a
    single backup, install it, and (unless deferred) restart squid.

    Returns True if squid.conf was (re)written.
    """
    squid_binary = shutil.which("squid")
    current = read_text_or_none(SQUID_CONF_PATH)

    if current == new_conf_text:
        return False

    if squid_binary is None:
        warn("squid binary not found -- squid.conf not installed")
        return False

    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as handle:
        handle.write(new_conf_text)
        candidate_path = handle.name
    try:
        parse = run([squid_binary, "-k", "parse", "-f", candidate_path])
        if parse.returncode != 0:
            raise SystemExit(
                "candidate squid.conf failed 'squid -k parse':\n" + (parse.stderr or parse.stdout)
            )
    finally:
        os.unlink(candidate_path)

    backup_once(SQUID_CONF_PATH, SQUID_BAK_PATH)
    atomic_write(SQUID_CONF_PATH, new_conf_text, mode=0o644)

    if deferred:
        warn("systemd unavailable -- skipping 'systemctl restart squid' (deferred)")
    else:
        restart = run(["systemctl", "restart", "squid"])
        if restart.returncode != 0:
            warn(f"systemctl restart squid failed: {restart.stderr.strip()}")
    return True


# ---------------------------------------------------------------------------
# student-users (append-or-dedupe, never truncation -- fixes defect #4)
# ---------------------------------------------------------------------------

def merge_student_users(user):
    existing = []
    if STUDENT_USERS_PATH.exists():
        existing = [
            line.strip() for line in STUDENT_USERS_PATH.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    if user not in existing:
        existing.append(user)
    # stable de-dupe, preserve first-seen order
    seen = set()
    deduped = []
    for entry in existing:
        if entry not in seen:
            seen.add(entry)
            deduped.append(entry)
    atomic_write(STUDENT_USERS_PATH, "\n".join(deduped) + "\n", mode=0o644)
    return deduped


# ---------------------------------------------------------------------------
# GDM targeted autologin edit (fixes defect #5: no wholesale replacement, at
# most one .bak, only touches AutomaticLoginEnable/AutomaticLogin in [daemon])
# ---------------------------------------------------------------------------

_SECTION_RE = re.compile(r"^\s*\[(?P<name>[^\]]+)\]\s*$")
_KEY_RE = re.compile(r"^\s*(?P<key>[A-Za-z0-9_]+)\s*=")


def gdm_set_autologin(user, enable, warn):
    if not GDM_CONF_PATH.exists():
        warn(f"{GDM_CONF_PATH} not found -- autologin was not configured")
        return False

    backup_once(GDM_CONF_PATH, GDM_CONF_PATH.with_name(GDM_CONF_PATH.name + ".cloudberryos.bak"))

    lines = GDM_CONF_PATH.read_text(encoding="utf-8").splitlines()
    out = []
    in_daemon = False
    daemon_seen = False
    wrote_enable = False
    wrote_login = False

    def daemon_insertions():
        insert = []
        if enable:
            insert.append(f"AutomaticLoginEnable = true")
            insert.append(f"AutomaticLogin = {user}")
        else:
            insert.append(f"AutomaticLoginEnable = false")
        return insert

    for line in lines:
        section_match = _SECTION_RE.match(line)
        if section_match:
            if in_daemon:
                # leaving [daemon] without having seen our keys -> insert now
                if not wrote_enable:
                    out.extend(daemon_insertions())
            in_daemon = section_match.group("name").strip().lower() == "daemon"
            if in_daemon:
                daemon_seen = True
            out.append(line)
            continue

        if in_daemon:
            key_match = _KEY_RE.match(line)
            if key_match and key_match.group("key") == "AutomaticLoginEnable":
                out.append(f"AutomaticLoginEnable = {'true' if enable else 'false'}")
                wrote_enable = True
                continue
            if key_match and key_match.group("key") == "AutomaticLogin":
                if enable:
                    out.append(f"AutomaticLogin = {user}")
                    wrote_login = True
                # when disabling, drop the stale AutomaticLogin line entirely
                continue
        out.append(line)

    if in_daemon and not wrote_enable:
        out.extend(daemon_insertions())
    if enable and in_daemon and wrote_enable and not wrote_login:
        out.append(f"AutomaticLogin = {user}")

    if not daemon_seen:
        out.append("")
        out.append("[daemon]")
        out.extend(daemon_insertions())

    atomic_write(GDM_CONF_PATH, "\n".join(out) + "\n", mode=0o644)
    return True


# ---------------------------------------------------------------------------
# apps.md catalog parsing (single source of truth for wizard app names)
# ---------------------------------------------------------------------------

_BACKTICK_RE = re.compile(r"`([A-Za-z0-9][A-Za-z0-9_.+-]*)`")


def _split_table_row(line):
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    return cells


def parse_apps_catalog(doc_path=None):
    """Parse docs/apps.md tables. Returns (wizard_apps: set[str],
    recommended: list[str]).

    Wizard apps = union of every backticked package name found in a table
    that has an "Ubuntu package" (or "Ubuntu package/source") column,
    excluding rows whose cell has no backtick (snap-only rows). The Games
    table is excluded automatically: it has no such column at all.
    """
    if doc_path is None:
        doc_path = find_apps_doc()
    if doc_path is None:
        raise SystemExit("cannot find docs/apps.md")
    text = Path(doc_path).read_text(encoding="utf-8")
    lines = text.splitlines()

    wizard_apps = set()
    recommended = []
    current_heading = None
    i = 0
    while i < len(lines):
        line = lines[i]
        heading_match = re.match(r"^##\s+(.*)$", line)
        if heading_match:
            current_heading = heading_match.group(1).strip()
            i += 1
            continue
        if line.strip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]):
            header_cells = _split_table_row(line)
            pkg_col = None
            for idx, cell in enumerate(header_cells):
                if cell.lower().startswith("ubuntu package"):
                    pkg_col = idx
                    break
            i += 2  # skip header + separator
            if pkg_col is None:
                # not an app-package table (e.g. the Games table) -- skip its rows
                while i < len(lines) and lines[i].strip().startswith("|"):
                    i += 1
                continue
            while i < len(lines) and lines[i].strip().startswith("|"):
                row_cells = _split_table_row(lines[i])
                if pkg_col < len(row_cells):
                    names = _BACKTICK_RE.findall(row_cells[pkg_col])
                    for name in names:
                        wizard_apps.add(name)
                        if current_heading == "Recommended Essentials":
                            if name not in recommended:
                                recommended.append(name)
                i += 1
            continue
        i += 1

    return wizard_apps, recommended


# ---------------------------------------------------------------------------
# Prototype-install artifact fingerprinting (Migration from prototype installs)
# ---------------------------------------------------------------------------

def looks_like_cloudberryos_artifact(path):
    path = Path(path)
    if not path.is_file():
        return False
    try:
        head = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    return "cloudberryos" in head.lower()


# ---------------------------------------------------------------------------
# Admin panel (M4): admin-token lifecycle + tailnet exposure via `tailscale
# serve`. Shared between cloudberryos-setup (creates/enables) and
# cloudberryos-admin (reads for auth, rotate-token for rotation).
# ---------------------------------------------------------------------------

def ensure_admin_token(force=False):
    """Generate /etc/cloudberryos/admin-token if absent, or unconditionally
    when force=True (rotation): secrets.token_urlsafe(32), root:root 0600
    -- never the prototype's 0644 pattern (see the Admin panel Locked
    Decision). Returns (token: str, created_or_rotated: bool). Sessions in
    cloudberryos-admin are bound to a hash of the token's content taken at
    login time, so simply replacing this file (which is all "rotation"
    does) invalidates every existing session on its next request -- no
    cross-process signaling needed.
    """
    if ADMIN_TOKEN_PATH.exists() and not force:
        existing = read_text_or_none(ADMIN_TOKEN_PATH) or ""
        return existing.strip(), False
    token = secrets.token_urlsafe(32)
    ETC_DIR.mkdir(parents=True, exist_ok=True)
    atomic_write(ADMIN_TOKEN_PATH, token + "\n", mode=0o600)
    try:
        os.chown(ADMIN_TOKEN_PATH, 0, 0)
    except (PermissionError, OSError):
        pass  # non-root dev/test environments; the 0600 mode still holds
    return token, True


def tailscale_bin():
    """Resolve the tailscale binary: CLOUDBERRYOS_TAILSCALE_BIN lets tests
    (and admins) point this at a mock/alternate binary; otherwise
    shutil.which. Tailscale is never a package Depends (not in the Ubuntu
    archive) -- always detected at runtime."""
    override = os.environ.get("CLOUDBERRYOS_TAILSCALE_BIN")
    if override:
        return override
    return shutil.which("tailscale")


def tailscale_is_up(tbin):
    """True when `tailscale status` succeeds (tailscaled running and the
    node is logged in) -- the "installed and up" half of the M4 default."""
    result = run([tbin, "status"])
    return result.returncode == 0


def tailscale_status_json(tbin):
    result = run([tbin, "status", "--json"])
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except (ValueError, TypeError):
        return None


def tailscale_check_magicdns_https(tbin, warn):
    """Best-effort, non-fatal check that MagicDNS + HTTPS certs are
    enabled for the tailnet before `tailscale serve` can hand out a valid
    cert at the machine's MagicDNS name. Real end-to-end verification
    (does a second device actually see a valid cert) is Manual-Hardware-
    Checklist territory -- this only inspects `tailscale status --json`
    and prints one-line guidance when the fields it looks for are
    missing; it never blocks setup."""
    status = tailscale_status_json(tbin)
    if status is None:
        warn("could not read 'tailscale status --json' to verify MagicDNS/HTTPS-cert settings -- continuing anyway")
        return
    magicdns_enabled = bool(status.get("MagicDNSEnabled"))
    cert_domains = status.get("CertDomains") or []
    if not magicdns_enabled or not cert_domains:
        warn(
            "MagicDNS and/or HTTPS certificates do not appear to be enabled for this tailnet -- "
            "enable both in the Tailscale admin console (DNS settings) so the admin panel's "
            "tailnet endpoint gets a valid HTTPS certificate at its MagicDNS name"
        )


def tailscale_serve_publish(tbin, port, warn):
    """Publish 127.0.0.1:<port> to the tailnet over HTTPS via `tailscale
    serve` (never `funnel` -- funnel is public-internet exposure and is
    explicitly out of scope). `tailscale serve --bg PORT` is the short
    form: it maps the tailnet HTTPS endpoint (443, at the machine's
    MagicDNS name) to http://127.0.0.1:PORT, and --bg detaches immediately
    instead of holding a foreground connection. Serve config lives in
    tailscaled itself and is reapplied automatically on boot, sidestepping
    any boot-time bind race. Returns True on success."""
    result = run([tbin, "serve", "--bg", str(port)])
    if result.returncode != 0:
        warn(f"'tailscale serve --bg {port}' failed: {(result.stderr or result.stdout).strip()}")
        return False
    return True


def resolve_admin_panel_mode(requested_mode, warn):
    """Resolve the tri-state --admin-panel value, applying the M4 tailnet
    fallback (docs/packaging-goal.md "Admin panel" Locked Decision).
    "off"/"local" pass through unchanged without ever touching tailscale.
    "tailnet" -- whether the parent passed --admin-panel tailnet
    explicitly, or cloudberryos-setup defaulted to attempting it because
    neither a flag nor a saved profile value was present -- is verified:
    if tailscale is absent or installed-but-down, this degrades to
    "local" with a one-line warning and never fails setup."""
    if requested_mode != "tailnet":
        return requested_mode
    tbin = tailscale_bin()
    if not tbin:
        warn("--admin-panel tailnet requested (or defaulted), but no 'tailscale' binary was found on PATH -- falling back to 'local'")
        return "local"
    if not tailscale_is_up(tbin):
        warn("--admin-panel tailnet requested (or defaulted), but 'tailscale status' failed (installed but not up/logged in) -- falling back to 'local'")
        return "local"
    return "tailnet"
