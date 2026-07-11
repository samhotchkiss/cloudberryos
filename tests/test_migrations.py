"""Unit tests for the M3 migrations runner: usr/sbin/cloudberryos-apply's
run_migrate() (invoked in production as `cloudberryos-apply --migrate`,
called by debian/postinst on every `configure`, including a fresh
install).

Covers the invariants in docs/packaging-goal.md Locked Decisions
("Migrations"):
  - schema_version is an int; missing means 0.
  - fresh install (neither profile.json nor resources.json exists) is an
    explicit no-op, exit 0.
  - migrations run ascending, only NNN above a file's current version.
  - each migration application is atomic (temp-file + rename) and bumps
    schema_version to NNN.
  - a raising migration aborts the whole runner non-zero with every file
    byte-unchanged on disk.
  - re-running is idempotent (no-op once at the latest schema_version).

These tests use a throwaway migrations directory + throwaway profile/
resources paths under tmp_path -- they never touch the real
/usr/share/cloudberryos/migrations or /etc/cloudberryos.
"""
import json

import pytest


def write_json(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_migration(migrations_dir, nnn, name, body):
    path = migrations_dir / f"{nnn:03d}-{name}.py"
    path.write_text(body, encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# Fresh install: neither file exists -> explicit no-op, exit 0.
# ---------------------------------------------------------------------------

def test_fresh_install_is_a_noop(apply_module, tmp_path):
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "bump",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_profile(d):\n"
        "    d['touched'] = True\n"
        "    return d\n",
    )
    profile_path = tmp_path / "profile.json"
    resources_path = tmp_path / "resources.json"

    result = apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=profile_path,
        resources_path=resources_path,
    )

    assert result == 0
    assert not profile_path.exists()
    assert not resources_path.exists()


def test_noop_when_no_migrations_shipped(apply_module, tmp_path):
    migrations_dir = tmp_path / "empty-migrations"
    migrations_dir.mkdir()
    profile_path = tmp_path / "profile.json"
    write_json(profile_path, {"schema_version": 1, "child_name": "Test"})

    result = apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=profile_path,
        resources_path=tmp_path / "resources.json",
    )

    assert result == 0
    assert read_json(profile_path) == {"schema_version": 1, "child_name": "Test"}


# ---------------------------------------------------------------------------
# A fixture migration bumping a temp file, with a real, verifiable
# transform, including the "missing schema_version means 0" invariant.
# ---------------------------------------------------------------------------

def test_migration_bumps_version_and_applies_transform(apply_module, tmp_path):
    """A resources-only migration (no upgrade_profile hook) transforms and
    bumps resources.json but leaves profile.json completely untouched --
    not even written -- which is exactly what the M3 acceptance gate's
    "profile.json byte-identical across an upgrade that also runs a real
    002 migration" assertion depends on."""
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "add-marker",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_resources(d):\n"
        "    d['marker'] = 'added-by-002'\n"
        "    return d\n",
    )

    profile_path = tmp_path / "profile.json"
    resources_path = tmp_path / "resources.json"
    write_json(profile_path, {"child_name": "Test"})  # no schema_version -> means 0
    write_json(resources_path, {"schema_version": 1, "resources": []})
    profile_before = profile_path.read_bytes()

    result = apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=profile_path,
        resources_path=resources_path,
    )

    assert result == 0
    # profile.json has no upgrade_profile hook in this migration -> untouched.
    assert profile_path.read_bytes() == profile_before
    resources_after = read_json(resources_path)
    assert resources_after["schema_version"] == 2
    assert resources_after["marker"] == "added-by-002"


def test_migration_defining_both_hooks_bumps_both_files(apply_module, tmp_path):
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "both",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_profile(d):\n"
        "    d['profile_marker'] = True\n"
        "    return d\n"
        "def upgrade_resources(d):\n"
        "    d['resources_marker'] = True\n"
        "    return d\n",
    )

    profile_path = tmp_path / "profile.json"
    resources_path = tmp_path / "resources.json"
    write_json(profile_path, {"schema_version": 1, "child_name": "Test"})
    write_json(resources_path, {"schema_version": 1, "resources": []})

    apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=profile_path,
        resources_path=resources_path,
    )

    profile_after = read_json(profile_path)
    resources_after = read_json(resources_path)
    assert profile_after["schema_version"] == 2 and profile_after["profile_marker"] is True
    assert resources_after["schema_version"] == 2 and resources_after["resources_marker"] is True


def test_only_migrations_above_current_version_run(apply_module, tmp_path):
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "should-not-run",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_profile(d):\n"
        "    raise AssertionError('002 must not run for a file already at schema_version 3')\n",
    )
    write_migration(
        migrations_dir, 3, "already-applied",
        "SCHEMA_VERSION = 3\n"
        "def upgrade_profile(d):\n"
        "    raise AssertionError('003 must not run either')\n",
    )

    profile_path = tmp_path / "profile.json"
    write_json(profile_path, {"schema_version": 3, "child_name": "Test"})

    result = apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=profile_path,
        resources_path=tmp_path / "resources.json",
    )

    assert result == 0
    assert read_json(profile_path) == {"schema_version": 3, "child_name": "Test"}


def test_ascending_multi_step_chain(apply_module, tmp_path):
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "step-a",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_resources(d):\n"
        "    d.setdefault('log', []).append('002')\n"
        "    return d\n",
    )
    write_migration(
        migrations_dir, 3, "step-b",
        "SCHEMA_VERSION = 3\n"
        "def upgrade_resources(d):\n"
        "    d.setdefault('log', []).append('003')\n"
        "    return d\n",
    )

    resources_path = tmp_path / "resources.json"
    write_json(resources_path, {"resources": []})  # missing schema_version -> 0

    result = apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=tmp_path / "profile.json",
        resources_path=resources_path,
    )

    assert result == 0
    after = read_json(resources_path)
    assert after["schema_version"] == 3
    assert after["log"] == ["002", "003"]


# ---------------------------------------------------------------------------
# Idempotent re-run.
# ---------------------------------------------------------------------------

def test_idempotent_rerun(apply_module, tmp_path):
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "add-marker",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_resources(d):\n"
        "    d['marker'] = 'added-by-002'\n"
        "    return d\n",
    )

    resources_path = tmp_path / "resources.json"
    write_json(resources_path, {"schema_version": 1, "resources": []})

    apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=tmp_path / "profile.json",
        resources_path=resources_path,
    )
    after_first = resources_path.read_bytes()

    result = apply_module.run_migrate(
        migrations_dir=migrations_dir,
        profile_path=tmp_path / "profile.json",
        resources_path=resources_path,
    )
    after_second = resources_path.read_bytes()

    assert result == 0
    assert after_first == after_second


# ---------------------------------------------------------------------------
# A raising migration aborts the whole runner non-zero, with EVERY file
# byte-unchanged on disk (including a file whose own chain would have
# succeeded, if another file's chain fails).
# ---------------------------------------------------------------------------

def test_raising_migration_aborts_with_files_untouched(apply_module, tmp_path):
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "bad",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_profile(d):\n"
        "    raise RuntimeError('deliberately broken migration')\n",
    )

    profile_path = tmp_path / "profile.json"
    resources_path = tmp_path / "resources.json"
    write_json(profile_path, {"schema_version": 1, "child_name": "Test"})
    write_json(resources_path, {"schema_version": 1, "resources": []})

    profile_before = profile_path.read_bytes()
    resources_before = resources_path.read_bytes()

    with pytest.raises(SystemExit) as excinfo:
        apply_module.run_migrate(
            migrations_dir=migrations_dir,
            profile_path=profile_path,
            resources_path=resources_path,
        )

    assert excinfo.value.code != 0
    assert profile_path.read_bytes() == profile_before
    assert resources_path.read_bytes() == resources_before


def test_raising_migration_leaves_other_files_chain_unwritten(apply_module, tmp_path):
    """resources.json's chain would succeed on its own, but profile.json's
    chain (processed first) fails -- resources.json must still be
    untouched because nothing is written until every targeted file's
    chain has completed."""
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "bad-for-profile-only",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_profile(d):\n"
        "    raise RuntimeError('boom')\n"
        "def upgrade_resources(d):\n"
        "    d['marker'] = 'should-never-appear'\n"
        "    return d\n",
    )

    profile_path = tmp_path / "profile.json"
    resources_path = tmp_path / "resources.json"
    write_json(profile_path, {"schema_version": 1, "child_name": "Test"})
    write_json(resources_path, {"schema_version": 1, "resources": []})
    resources_before = resources_path.read_bytes()

    with pytest.raises(SystemExit):
        apply_module.run_migrate(
            migrations_dir=migrations_dir,
            profile_path=profile_path,
            resources_path=resources_path,
        )

    assert resources_path.read_bytes() == resources_before
    assert "marker" not in read_json(resources_path)


def test_raising_migration_leaves_earlier_successful_file_chain_unwritten(apply_module, tmp_path):
    """profile.json's chain (processed first, and would succeed on its
    own) must NOT be written if resources.json's chain (processed second)
    later fails -- nothing is written until every targeted file's chain
    has completed successfully."""
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    write_migration(
        migrations_dir, 2, "profile-ok-resources-bad",
        "SCHEMA_VERSION = 2\n"
        "def upgrade_profile(d):\n"
        "    d['profile_marker'] = True\n"
        "    return d\n"
        "def upgrade_resources(d):\n"
        "    raise RuntimeError('boom')\n",
    )

    profile_path = tmp_path / "profile.json"
    resources_path = tmp_path / "resources.json"
    write_json(profile_path, {"schema_version": 1, "child_name": "Test"})
    write_json(resources_path, {"schema_version": 1, "resources": []})
    profile_before = profile_path.read_bytes()

    with pytest.raises(SystemExit):
        apply_module.run_migrate(
            migrations_dir=migrations_dir,
            profile_path=profile_path,
            resources_path=resources_path,
        )

    assert profile_path.read_bytes() == profile_before
    assert "profile_marker" not in read_json(profile_path)


def test_schema_version_mismatch_is_a_hard_error(apply_module, tmp_path):
    migrations_dir = tmp_path / "migrations"
    migrations_dir.mkdir()
    # Filename says 002, but SCHEMA_VERSION disagrees -- must be rejected.
    write_migration(migrations_dir, 2, "mismatch", "SCHEMA_VERSION = 5\n")

    profile_path = tmp_path / "profile.json"
    write_json(profile_path, {"schema_version": 1, "child_name": "Test"})
    before = profile_path.read_bytes()

    with pytest.raises(SystemExit):
        apply_module.run_migrate(
            migrations_dir=migrations_dir,
            profile_path=profile_path,
            resources_path=tmp_path / "resources.json",
        )

    assert profile_path.read_bytes() == before


# ---------------------------------------------------------------------------
# Real migrations/ directory sanity: 001-initial.py matches the contract
# and is a genuine no-op against a fresh schema_version-1 file.
# ---------------------------------------------------------------------------

def test_repo_001_initial_matches_contract(apply_module):
    migrations_dir = apply_module.default_migrations_dir()
    assert migrations_dir is not None
    discovered = apply_module._discover_migrations(migrations_dir)
    assert (1, migrations_dir / "001-initial.py") in discovered
    module = apply_module._load_migration_module(1, migrations_dir / "001-initial.py")
    assert module.SCHEMA_VERSION == 1
