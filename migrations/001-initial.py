#!/usr/bin/env python3
"""CloudberryOS migration 001 -- initial schema_version baseline.

Migration-module contract (see usr/sbin/cloudberryos-apply's run_migrate
docstring/comment block for the full runner semantics):

    SCHEMA_VERSION = <N>            -- must equal this file's NNN- prefix

    def upgrade_profile(d: dict) -> dict: ...      (optional)
    def upgrade_resources(d: dict) -> dict: ...    (optional)

The runner calls whichever hook(s) a migration file defines, once per
state file (profile.json / resources.json), only when that file's current
schema_version is below this file's SCHEMA_VERSION, ascending across all
migration files. Hooks receive an in-memory dict and return the upgraded
dict; the runner itself stamps schema_version = SCHEMA_VERSION afterwards.

001 is an intentional no-op baseline: schema_version 1 is where every
0.1.0 install starts (both profile.json and resources.json are written
at schema_version 1 from the day they are created), so this migration
defines neither hook -- there is nothing to transform.
"""

SCHEMA_VERSION = 1


if __name__ == "__main__":
    pass
