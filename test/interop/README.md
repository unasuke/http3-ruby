# Interoperability checks

The fourth tier of the tests: http3-ruby against other HTTP/3 and QUIC
implementations. They need containers or browsers, so `rake test` does not
run them. `curl.sh` and quic-interop-runner's http3 test case also run in CI
(`.github/workflows/interop.yml`), on every push to main and weekly; the
rest is manual.

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

## Requests held open

`hold_requests.rb` checks that clients holding requests open cannot make the
server use up its memory or its disk. It starts `server.rb` on a temporary
directory and certificate, opens 20 connections, and on each sends 100
requests whose 1,000,000-byte bodies never end (no FIN). With its default
limits the server holds no more than 4 MiB of them in memory per connection
(`max_connection_request_buffer`) and 64 MiB in all
(`max_total_request_buffer`). A body over 64 KiB (`request_body_buffer_size`)
goes to a temporary file, of which it holds no more than 16 MiB and 16 files
per connection (`max_connection_request_spool`,
`max_connection_request_spool_files`) and 1 GiB and 256 files in all
(`max_total_request_spool`, `max_total_request_spool_files`). It answers the
rest with 503 at once.

```sh
bundle exec ruby test/interop/hold_requests.rb [--connections 20] [--streams 100] \
  [--bytes 1_000_000] [--timeout 120] [--request-timeout SECONDS]
```

It prints the server's resident set size before and after, the temporary
files it holds, and how the requests were answered: with the defaults, 256
held open, in 256 files of about 1 MB, and 1744 with 503. It exits non-zero
unless some request got 503, the temporary files stay within 16 files and
16 MiB per connection and 256 files and 1 GiB in all, the server is still
running, and a GET on a new connection gets 200
afterwards, or when it takes more than `--timeout` seconds. The resident set
size should grow by tens of MiB, not by the 2 GB sent; it varies from run to
run, so the script checks no threshold.

`--request-timeout` is passed on to `server.rb` as the server's
`request_timeout` (30 seconds by default, longer than the script waits). With
it, the script also waits for the requests held open to run out of time and
exits non-zero unless every one of them gets 408 and no temporary file is
left open afterwards. With `--request-timeout 5`, 512 got 408: the 256 held
at first, then 256 more whose bodies were still on their way when the first
ones let go of their files.

## Responses not read

`stall_responses.rb` checks that clients that stop reading responses cannot
make the server use up its memory. It starts an `HTTP3::Server` of its own in
a child process, since `server.rb` serves files, which the server reads only
as it sends them. Its `/big` is a 10 MiB `each` body and `/small` a short one.
The script opens 100 connections, and on each asks for `/big` 100 times and
reads none of them. A worker writes an `each` body as the connection takes
it, so the first three `/big` keep the three workers waiting, with no more
than `send_buffer_size` of each queued, and the other requests wait for a
worker; so does a `/small` on another connection, until the connections not
reading have gone. The workers wait with no time limit, as the README's
limitations say.

```sh
bundle exec ruby test/interop/stall_responses.rb [--connections 100] [--streams 100] \
  [--timeout 120]
```

It prints the server's resident set size before and while the workers wait.
It exits non-zero unless the server is still running, a `/small` on a new
connection gets no answer within 2 seconds while the workers wait, and all of
it once the connections not reading have closed; or when a connection fails,
or it takes more than `--timeout` seconds. The resident set size should grow
by about 50 MiB, mostly for the 10,000 requests waiting, not by the 100 GB
asked for. Before the workers, when the thread that drives the connections
read the bodies, the server kept no more than `max_connection_send_buffer`
(1 MiB) of them per connection and `max_total_send_buffer` (64 MiB) in all,
and the resident set size grew by about 64 MiB; without those limits it grew
past 300 MiB, and the connections timed out.

## Requests that keep the workers busy

`slow_requests.rb` checks that requests keeping the workers busy do not hold
up the thread that drives the connections. It starts an `HTTP3::Server` of
its own in a child process, with `threads: 3`. One connection keeps a `/cpu`
(2 seconds of busy loop, which holds Ruby's GVL) and a `/sleep` (5 seconds)
under way all the while, which take two of the workers; on the third,
another connection asks for `/small` again and again, and new connections
are set up in between. One worker is left free, or `/small` would wait for
it and the check measure the queue rather than the GVL.

```sh
bundle exec ruby test/interop/slow_requests.rb [--duration 10] [--max-latency 0.25] \
  [--priority N] [--timeout 120]
```

It prints the median and the largest of the `/small` round trips and of the
handshakes, and exits non-zero when the largest of either is over
`--max-latency` seconds, when a request does not get 200, or when it takes
more than `--timeout` seconds. `--priority` sets the workers' priority
(`HTTP3::WorkerPool::WORKER_PRIORITY`, -3) to compare: on Ruby 4.0.9, a
`/small` took 0.058 seconds at the median and up to 0.14 at -3, 0.30 and up
to 0.60 at 0, the priority of the other threads; a handshake 0.021 and up to
0.06, against 0.10 and 0.30. A round trip waits for the GVL a few times,
each up to the busy worker's time slice, which Ruby 3.4 and later shorten
with `RUBY_THREAD_TIMESLICE`: at 20 (milliseconds), a `/small` took 0.028
and up to 0.05.

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
