#!/usr/bin/env bash
# M2 acceptance gate, Block B (docs/packaging-goal.md "M2 -- Debian
# packaging and lifecycle", service-level checks + the prototype-migration
# test). Needs a booted systemd -- plain ubuntu:26.04 Docker has neither
# systemd nor NET_ADMIN. Tries the derived systemd-in-Docker image first
# (docs/packaging-goal.md's Dockerfile, here ci/systemd.Dockerfile); if
# systemd does not reach "running"/"degraded" within a short timeout (the
# doc's explicit "misbehaves in any way -> fall back to Lima immediately"
# instruction), tears the container down and switches to the Lima VM
# (`limactl start template:experimental/ubuntu-26.04`) instead.
#
# Runs on the HOST (needs Docker and/or limactl). Requires
# dist/cloudberryos_0.1.0_all.deb to already exist (run ci/package-stage.sh
# first).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEB="dist/cloudberryos_0.1.0_all.deb"
test -f "$DEB" || { echo "missing $DEB -- run ci/package-stage.sh first" >&2; exit 1; }

IMAGE=cloudberryos-systemd-test
READY_TIMEOUT=60

wait_for_systemd() {
  local cid="$1"
  local i
  for ((i = 0; i < READY_TIMEOUT; i++)); do
    state="$(docker exec "$cid" systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
      running|degraded) return 0 ;;
    esac
    sleep 1
  done
  return 1
}

run_in_fresh_container() {
  # run_in_fresh_container <script-path> -- boots a fresh systemd container,
  # waits for readiness, execs the given script inside it, always tears the
  # container down afterward. Returns the script's exit status; returns 99
  # if systemd itself never became ready (the Docker-misbehaving signal).
  local script="$1"
  local cid
  cid="$(docker run -d --privileged --cgroupns=host -v "$REPO_ROOT":/src -w /src "$IMAGE")"
  local status=0
  if wait_for_systemd "$cid"; then
    docker exec "$cid" bash "$script" || status=$?
  else
    echo "systemd never reached running/degraded in ${READY_TIMEOUT}s inside Docker" >&2
    status=99
  fi
  docker logs "$cid" > "/tmp/cloudberryos-systemd-test-$$.log" 2>&1 || true
  docker rm -f "$cid" >/dev/null 2>&1 || true
  return "$status"
}

try_docker_systemd() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found on PATH" >&2
    return 99
  fi
  echo "== Block B: building the systemd-in-Docker test image =="
  if ! docker build -q -t "$IMAGE" -f ci/systemd.Dockerfile . ; then
    echo "docker build of the systemd test image failed" >&2
    return 99
  fi

  echo "== Block B: live service-level checks (systemd-in-Docker) =="
  run_in_fresh_container ci/services-checks-live.sh
  local live_status=$?
  if [[ "$live_status" -eq 99 ]]; then
    return 99
  elif [[ "$live_status" -ne 0 ]]; then
    echo "live service-level checks FAILED (exit $live_status) -- this is a real test failure, not a Docker-systemd misbehavior; not falling back to Lima" >&2
    exit "$live_status"
  fi

  echo "== Block B: prototype-migration test (systemd-in-Docker) =="
  run_in_fresh_container ci/services-checks-migration.sh
  local migration_status=$?
  if [[ "$migration_status" -eq 99 ]]; then
    return 99
  elif [[ "$migration_status" -ne 0 ]]; then
    echo "prototype-migration test FAILED (exit $migration_status) -- this is a real test failure, not a Docker-systemd misbehavior; not falling back to Lima" >&2
    exit "$migration_status"
  fi

  echo
  echo "=== M2 acceptance gate, Block B: ALL STEPS PASSED (systemd-in-Docker) ==="
  return 0
}

try_lima() {
  echo "== Block B: falling back to Lima (systemd-in-Docker misbehaved) ==" >&2
  if ! command -v limactl >/dev/null 2>&1; then
    echo "limactl not found on PATH -- cannot fall back to Lima" >&2
    return 1
  fi

  local instance=cloudberryos-test
  if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$instance"; then
    echo "starting Lima instance '$instance' (template:experimental/ubuntu-26.04) -- this downloads an image and can take several minutes" >&2
    limactl start --name "$instance" --tty=false template:experimental/ubuntu-26.04
  fi

  limactl shell "$instance" -- sudo bash -c "cd $REPO_ROOT && bash ci/services-checks-live.sh"
  limactl shell "$instance" -- sudo bash -c "cd $REPO_ROOT && bash ci/services-checks-migration.sh"

  echo
  echo "=== M2 acceptance gate, Block B: ALL STEPS PASSED (Lima) ==="
}

if try_docker_systemd; then
  exit 0
fi

try_lima
