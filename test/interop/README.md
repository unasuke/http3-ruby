# Interoperability checks

The fourth tier of the tests: http3-ruby against other HTTP/3 and QUIC
implementations. They need containers or browsers, so `rake test` does not
run them. `curl.sh` also runs weekly in CI (`.github/workflows/interop.yml`);
the rest is manual.

All of them use `server.rb`, which serves a directory with `Rack::Files`:

```sh
bundle exec rake compile
bundle exec ruby test/interop/server.rb --root public --bind 127.0.0.1:4433 \
  --certificate cert.pem --private-key key.pem [--qlog-dir qlog]
```

A certificate for 127.0.0.1 and localhost:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout key.pem -out cert.pem
```

## curl

`curl.sh` starts `server.rb` on a temporary directory and certificate and
fetches from it with `curl --http3-only`, in a container
(`docker.io/alpine/curl-http3`, curl with quiche): GET, a 5 MB body, HEAD and
a 404. It uses docker, or podman when docker is missing
(`CONTAINER_ENGINE` overrides), and exits non-zero when a check fails.

```sh
test/interop/curl.sh
```

## h3i

[h3i](https://github.com/cloudflare/quiche/tree/master/h3i) sends hand-made
HTTP/3 frames, for what a well-behaved client never does: oversized or
malformed header sections, frames on the wrong stream, a request stream
reset half way.

```sh
cargo install --git https://github.com/cloudflare/quiche h3i
h3i 127.0.0.1:4433 --no-verify
```

Things worth checking: a header section over `max_field_section_size`
(64 KiB) gets 431, a body over `max_request_body` (1 MiB) gets 413, and a
protocol error closes only that connection (the server logs
`connection_error` and keeps serving).

## quic-interop-runner

[quic-interop-runner](https://github.com/quic-interop/quic-interop-runner)
runs the server role against other implementations' clients. `Dockerfile`
builds the endpoint and `run_endpoint.sh` implements the `http3` test case;
every other case uses the hq-interop ALPN, which HTTP3::Server does not
speak, so it exits 127 (unsupported).

`run_interop_runner.sh` runs the runner on `quic-interop-runner.yml`, the
runner's compose with a stand-in for its ns-3 network simulator, which
passes no packets under rootless podman. The stand-in (`sim/`) forwards
between the client's and the server's networks with plain Linux routing,
with no emulated delay, bandwidth or loss, and captures both sides, as the
simulator does, for the runner's checks.

```sh
docker build -f test/interop/Dockerfile -t http3-ruby-interop .
git clone https://github.com/quic-interop/quic-interop-runner tmp/quic-interop-runner
python3 -m venv tmp/quic-interop-runner/.venv
tmp/quic-interop-runner/.venv/bin/pip install -r tmp/quic-interop-runner/requirements.txt
# Add to tmp/quic-interop-runner/implementations_quic.json:
#   "http3-ruby": {"image": "http3-ruby-interop", "url": "https://github.com/unasuke/http3-ruby", "role": "server"}
PYTHON=$PWD/tmp/quic-interop-runner/.venv/bin/python \
  test/interop/run_interop_runner.sh -s http3-ruby -c ngtcp2,quic-go -t http3
```

The runner checks the pcaps with tshark, which has to be installed.

The runner brings the compose up again and again but never takes it down,
so a network it made outlives it, and one on the same addresses
(193.167.x.x, which `trace.py` fixes) stops the next run from making its
own, whichever checkout or compose left it. The script makes the networks
afresh: before the run it removes the networks on 193.167.x.x with the
stopped containers on them and those named `sim`, `client` and `server`,
and after the run it removes its own the same way. A container still
running is left alone, and the run does not start. `RUNNER_DIR` points it
at another clone of the runner. Under podman, it also keeps a container of
its own up through the run, so that podman never has to stop the network
helper pasta mid-run, which Ubuntu's AppArmor profile for pasta refuses.

## Browsers

`Rack::Files` serves no index for `/`, so open a file under `--root`, such
as `index.html`.

Chrome, forced onto QUIC for the origin and trusting the certificate by its
public key. Open 127.0.0.1, not localhost: Chrome looks localhost up as ::1
first, where a server bound to 127.0.0.1 does not answer, and fails with
`ERR_QUIC_HANDSHAKE_FAILED`.

```sh
spki=$(openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64)
google-chrome --user-data-dir=$(mktemp -d) --origin-to-force-quic-on=127.0.0.1:4433 \
  --ignore-certificate-errors-spki-list="$spki" https://127.0.0.1:4433/index.html
```

Without `--origin-to-force-quic-on`, Chrome stays on TCP even when Alt-Svc
offers HTTP/3: the SPKI list does not cover QUIC connections found through
Alt-Svc, and their handshake rejects the certificate as unknown.

Firefox moves to HTTP/3 only after a response over TCP carries Alt-Svc.
`openssl s_server -HTTP` sends a file as a whole HTTP response, so it can
send one on the same port over TCP, next to `server.rb`:

```sh
mkdir tcp
printf 'HTTP/1.1 200 OK\r\nAlt-Svc: h3=":4433"\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nAlt-Svc sent\n' \
  > tcp/alt-svc
cd tcp && openssl s_server -accept 127.0.0.1:4433 -cert ../cert.pem -key ../key.pem -HTTP -quiet
```

In `about:config`, set `network.http.http3.disable_when_third_party_roots_found`
to `false` and import `cert.pem` as an authority. Then open
`https://localhost:4433/alt-svc`, which comes over TCP, and after it a file
such as `https://localhost:4433/index.html`, which comes over HTTP/3.

In the developer tools, the Network panel's Protocol column should read h3.
