#!/bin/bash
# The stand-in simulator's entrypoint. The compose sets IP forwarding
# (sysctls), since /proc/sys is read-only in a Docker container.
set -e

mkdir -p /logs
left=$(ip -o -4 addr show | awk '$4 ~ /^193\.167\.0\.2\// {print $2}')
right=$(ip -o -4 addr show | awk '$4 ~ /^193\.167\.100\.2\// {print $2}')

# The simulator's pcaps, under the names the runner reads: the client's
# side and the server's side. -Z root: tcpdump that drops to its own user
# cannot capture under rootless podman. -U writes each packet out at once.
sim-tcpdump -Z root -i "$left" -U -s 0 -w /logs/trace_node_left.pcap &
sim-tcpdump -Z root -i "$right" -U -s 0 -w /logs/trace_node_right.pcap &

# The endpoints start once this port answers (wait-for-it.sh sim:57832).
sim-nc -lk 57832 &

# bash stays PID 1, so that the runtime's SIGTERM reaches tcpdump, which
# then finishes its pcap.
trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM INT
wait
