# Interoperability checks

The fourth tier of the tests: http3-ruby against other HTTP/3 and QUIC
implementations. They need containers, so `rake test` does not run them.
`curl.sh` also runs weekly in CI (`.github/workflows/interop.yml`).

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
