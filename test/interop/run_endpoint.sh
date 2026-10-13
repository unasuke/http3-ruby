#!/bin/bash
# The quic-interop-runner endpoint (server role). The runner sets ROLE and
# TESTCASE, serves /www, puts the certificate in /certs and may set
# QLOGDIR. Only the http3 test case is implemented: the others use the
# hq-interop ALPN (HTTP/0.9), which HTTP3::Server does not speak, and exit
# 127 as the runner expects for an unsupported case.
set -e

/setup.sh

if [ "$ROLE" != "server" ]; then
  echo "only the server role is implemented"
  exit 127
fi

case "$TESTCASE" in
  http3) ;;
  *) exit 127 ;;
esac

# The simulator's server address. HTTP3::Server serves one address and
# refuses 0.0.0.0.
args=(--root /www --bind 193.167.100.100:443 --certificate /certs/cert.pem --private-key /certs/priv.key)
if [ -n "$QLOGDIR" ]; then
  args+=(--qlog-dir "$QLOGDIR")
fi
cd /http3
exec bundle exec ruby test/interop/server.rb "${args[@]}"
