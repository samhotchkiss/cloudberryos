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
#   ci/build-and-test.sh --services     # (future) also run service-level checks (Lima/systemd)
#
# This script is meant to run *inside* a container (see docs/packaging-goal.md
# "Test environment"), e.g.:
#   docker run --rm -v "$PWD":/src -w /src ubuntu:26.04 bash -c \
#     'apt-get update -q && apt-get install -yq --no-install-recommends python3 python3-pytest && \
#      python3 -m pytest tests/'
# ci/build-and-test.sh itself only assumes python3 + pytest are already on PATH;
# it does not install packages.

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
  echo "package stage not implemented yet (M2)" >&2
  exit 1
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
  echo "service-level checks not implemented yet (require Lima VM or a systemd container, M2+)" >&2
  exit 1
fi
