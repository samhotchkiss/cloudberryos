#!/usr/bin/env bash
# CloudberryOS container CI gate.
#
# Stages accumulate across milestones:
#   unit     - M0+: run the pytest suite against tools/ (stdlib + pytest only).
#   setup    - M1+: artifact generation + cloudberryos-setup + idempotency checks.
#   package  - M2+: debian package build/lint/lifecycle checks.
#   upgrade  - M3+: local-repo upgrade checks.
#
# Usage:
#   ci/build-and-test.sh                # runs all plain-Docker stages defined so far
#   ci/build-and-test.sh unit           # runs only the unit stage
#   ci/build-and-test.sh --services     # also run service-level checks (Lima/systemd, M2+)
#
# `unit` and `setup` are meant to run *inside* an already-provisioned
# container (see docs/packaging-goal.md "Test environment"), e.g.:
#   docker run --rm -v "$PWD":/src -w /src ubuntu:26.04 bash -c \
#     'apt-get update -q && apt-get install -yq --no-install-recommends python3 python3-pytest && \
#      python3 -m pytest tests/'
# `package`, `upgrade`, and `--services` are different: each needs more than
# one fresh, throwaway container (or the Lima VM) over its lifetime, so
# those stages run on the HOST (wherever Docker/Lima are available) and
# orchestrate their own `docker run`/`limactl` invocations -- see
# ci/package-stage.sh and ci/services-stage.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RUN_SERVICES=0
STAGES=()

for arg in "$@"; do
  case "$arg" in
    --services)
      RUN_SERVICES=1
      ;;
    unit|setup|package|upgrade)
      STAGES+=("$arg")
      ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: $0 [unit|setup|package|upgrade] [--services]" >&2
      exit 1
      ;;
  esac
done

# Default: run every plain-Docker stage implemented so far. Today that is
# just 'unit'; later milestones append to this list as they land.
if [[ ${#STAGES[@]} -eq 0 ]]; then
  STAGES=(unit)
fi

stage_unit() {
  echo "== stage: unit =="
  python3 -m pytest tests/
}

stage_setup() {
  echo "== stage: setup =="
  # M1 acceptance gate (docs/packaging-goal.md "M1 -- Code rework").
  # This stage is destructive to the container's /usr, /etc, /var, /home
  # (it "fake installs" the proposed package layout onto real paths and
  # creates a "testkid" account) -- only ever run it inside a throwaway
  # container, e.g.:
  #   docker run --rm -v "$PWD":/src -w /src ubuntu:26.04 bash -c \
  #     'apt-get update -q && apt-get install -yq --no-install-recommends \
  #        python3 python3-pytest squid nftables adduser sudo systemd \
  #        libglib2.0-bin dbus xdg-utils && \
  #      ci/build-and-test.sh setup'
  bash "$REPO_ROOT/ci/setup-stage.sh"
}

stage_package() {
  echo "== stage: package =="
  # M2 acceptance gate, Block A (docs/packaging-goal.md "M2 -- Debian
  # packaging and lifecycle"). Runs on the HOST: builds the .deb + lintian
  # in one throwaway ubuntu:26.04 container, then exercises the full
  # install/setup/remove-student-config/reinstall/remove/purge lifecycle in
  # a second fresh one. Requires Docker.
  bash "$REPO_ROOT/ci/package-stage.sh"
}

stage_upgrade() {
  echo "== stage: upgrade =="
  echo "upgrade stage not implemented yet (M3)" >&2
  exit 1
}

for stage in "${STAGES[@]}"; do
  case "$stage" in
    unit) stage_unit ;;
    setup) stage_setup ;;
    package) stage_package ;;
    upgrade) stage_upgrade ;;
  esac
done

if [[ "$RUN_SERVICES" -eq 1 ]]; then
  echo "== --services requested =="
  # M2 acceptance gate, Block B (docs/packaging-goal.md "M2 -- Debian
  # packaging and lifecycle", service-level checks). Needs a booted
  # systemd -- tries a derived systemd-in-Docker image first per the
  # doc's Dockerfile, falls back to the Lima VM immediately if that
  # misbehaves. Requires dist/cloudberryos_0.1.0_all.deb to already exist
  # (run the package stage, or ci/package-stage.sh, first).
  bash "$REPO_ROOT/ci/services-stage.sh"
fi
