# Stands in for quic-interop-runner's network simulator
# (martenseemann/quic-network-simulator), whose ns-3 datapath passes no
# packets under rootless podman. It forwards between leftnet and rightnet
# with plain Linux routing, at the simulator's addresses, captures both
# sides as the simulator does, and opens the port the endpoints wait for.
# There is no emulated delay, bandwidth or loss. Build from the repository
# root:
#
#   docker build -t http3-ruby-interop-sim test/interop/sim
FROM martenseemann/quic-network-simulator-endpoint:latest
# The host's AppArmor profiles for /usr/bin/nc.openbsd and /usr/bin/tcpdump
# (Ubuntu ships both) attach inside the container too, and refuse the
# runtime's signals, so that the container cannot be stopped. The copies
# under other paths run unconfined.
RUN apt-get update \
  && apt-get install -y --no-install-recommends netcat-openbsd \
  && rm -rf /var/lib/apt/lists/* \
  && cp /usr/bin/nc.openbsd /usr/local/bin/sim-nc \
  && cp /usr/bin/tcpdump /usr/local/bin/sim-tcpdump
COPY run.sh /run.sh
ENTRYPOINT ["/bin/bash", "/run.sh"]
