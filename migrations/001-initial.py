#!/usr/bin/env python3
"""CloudberryOS migration 001 -- initial schema_version baseline.

This is an intentional no-op placeholder. The full migrations-runner
semantics (ascending NNN-*.py execution above the current schema_version,
atomic temp-file+rename per step, abort-on-failure) are an M3 task per
docs/packaging-goal.md Locked Decisions ("Migrations"). `cloudberryos-apply
--migrate` (usr/sbin/cloudberryos-apply) does not yet execute migration
files at all in 0.1.0 -- it only detects their presence and no-ops,
including the required fresh-install ("neither profile.json nor
resources.json exists") case. This file exists so the shipped
/usr/share/cloudberryos/migrations/ directory is not empty and so M3 has a
concrete "version 1 is the starting baseline" script to build the runner
against.
"""


def migrate(profile, resources):
    """No-op: schema_version 1 is the baseline every 0.1.0 install starts
    at. Returns (profile, resources) unchanged."""
    return profile, resources


if __name__ == "__main__":
    pass
