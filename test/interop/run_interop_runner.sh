#!/usr/bin/env bash
#
# Runs quic-interop-runner on quic-interop-runner.yml, the runner's compose
# with the stand-in simulator, with its network made afresh.
#
# The runner brings the compose up again and again but never takes it
# down, so its containers and network outlive it. The compose pins its
# networks to 193.167.0.0/24 and 193.167.100.0/24, as trace.py fixes the
# addresses of the client and the server; a network another run left on
# 193.167.x.x, of this checkout or another, of this compose or another, is
# in the way of the next run's. So before the run, the networks on
# 193.167.x.x go, with the stopped containers on them and those of the
# names the compose gives (sim, client, server), and after it, those of
# this run go the same way. A container still running is left alone, and
# the run does not start.
#
# Under podman, a container on a network of its own stays up through the
# run. When the last container on bridge networks goes, rootless podman
# stops pasta, which carries them; Ubuntu's AppArmor profile for pasta
# refuses that signal, and the runner's next `up`, which first removes the
# old simulator, fails with "rootless netns: kill network process:
# permission denied". With that container up, the last one never goes
# during the run.
#
# Usage, from anywhere:
#   test/interop/run_interop_runner.sh <arguments of run.py>
# RUNNER_DIR is the clone of quic-interop-runner (tmp/quic-interop-runner
# by default) and PYTHON the command that runs Python there (python by
# default). This builds the stand-in simulator; the endpoints' images are
# built beforehand (README.md).
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
runner=${RUNNER_DIR:-$repo/tmp/quic-interop-runner}
read -r -a python <<< "${PYTHON:-python}"
compose=docker-compose.http3-ruby.yml
keeper=http3-ruby-interop-keeper

# Removes the stopped container `$1`; fails when it is running.
remove_stopped() {
  local state
  state=$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null) || return 0
  if [ "$state" = running ]; then
    echo "container $1 is running: another run is going on" >&2
    return 1
  fi
  docker rm "$1" >/dev/null
}

# Removes the networks on 193.167.x.x and the containers of the compose's
# names, with the containers on those networks.
clear_addresses() {
  local info network name
  for name in sim client server; do
    remove_stopped "$name"
  done
  for network in $(docker network ls --format '{{.Name}}'); do
    info=$(docker network inspect "$network")
    grep -qE '"[Ss]ubnet": *"193\.167\.' <<< "$info" || continue
    for name in $(docker ps -a --filter "network=$network" --format '{{.Names}}'); do
      remove_stopped "$name"
    done
    docker network rm "$network" >/dev/null
  done
}

podman=false
if docker --version 2>/dev/null | grep -qi podman; then
  podman=true
fi

start_keeper() {
  $podman || return 0
  remove_stopped "$keeper"
  docker network inspect "$keeper" >/dev/null 2>&1 || docker network create "$keeper" >/dev/null
  docker run -d --name "$keeper" --network "$keeper" --entrypoint sleep \
    http3-ruby-interop-sim infinity >/dev/null
}

stop_keeper() {
  $podman || return 0
  docker rm -f "$keeper" >/dev/null 2>&1 || true
  docker network rm "$keeper" >/dev/null 2>&1 || true
}

docker build -q -t http3-ruby-interop-sim "$repo/test/interop/sim" >/dev/null
cp "$repo/test/interop/quic-interop-runner.yml" "$runner/$compose"
cd "$runner"
clear_addresses
start_keeper
# The runner's containers go first, while the keeper still holds the
# network up.
trap 'clear_addresses || true; stop_keeper' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
COMPOSE_FILE=$compose "${python[@]}" run.py "$@"
