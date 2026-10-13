#!/bin/sh
# Fetch from test/interop/server.rb with curl --http3-only, which speaks
# HTTP/3 through quiche: a QUIC and HTTP/3 stack other than ngtcp2 and
# nghttp3. curl runs in a container (docker or podman) so that the host's
# curl needs no HTTP/3 support.
#
#   test/interop/curl.sh
#
# Exits non-zero when a check fails. Needs the extension compiled
# (bundle exec rake compile) and openssl on PATH.
set -eu

CURL_IMAGE=${CURL_IMAGE:-docker.io/alpine/curl-http3}
PORT=${PORT:-4433}
ENGINE=${CONTAINER_ENGINE:-$(command -v docker || command -v podman)}

work=$(mktemp -d)
server_pid=
cleanup() {
  [ -n "$server_pid" ] && kill -TERM "$server_pid" 2>/dev/null && wait "$server_pid" || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/www" "$work/certs"
echo "hello from http3-ruby" > "$work/www/index.html"
head -c 5000000 /dev/urandom > "$work/www/large.bin"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1" \
  -keyout "$work/certs/key.pem" -out "$work/certs/cert.pem" 2>/dev/null

bundle exec ruby "$(dirname "$0")/server.rb" --root "$work/www" --bind "127.0.0.1:$PORT" \
  --certificate "$work/certs/cert.pem" --private-key "$work/certs/key.pem" &
server_pid=$!
sleep 2

curl_h3() {
  "$ENGINE" run --rm --network host -v "$work/certs:/certs:ro" "$CURL_IMAGE" \
    curl -sS --http3-only --cacert /certs/cert.pem "$@"
}

fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected $3, got $2"
    fail=1
  fi
}

check "GET over HTTP/3" "$(curl_h3 -o /dev/null -w '%{http_code} %{http_version}' "https://127.0.0.1:$PORT/index.html")" "200 3"
check "body" "$(curl_h3 "https://127.0.0.1:$PORT/index.html")" "hello from http3-ruby"
check "large body" "$(curl_h3 "https://127.0.0.1:$PORT/large.bin" | sha256sum | cut -d' ' -f1)" \
  "$(sha256sum "$work/www/large.bin" | cut -d' ' -f1)"
check "HEAD" "$(curl_h3 -I -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/index.html")" "200"
check "missing file" "$(curl_h3 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/missing")" "404"

exit "$fail"
