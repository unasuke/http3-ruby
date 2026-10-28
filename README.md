# http3-ruby

`http3` serves Rack 3 applications over HTTP/3. It runs QUIC through the
[quic gem](https://github.com/unasuke/quic-ruby) and HTTP/3 through
[nghttp3](https://github.com/ngtcp2/nghttp3), which it builds from source and
links in statically. The nghttp3 bindings are also there to use directly, as
`HTTP3::Nghttp3`.

It is not suited for production yet:

- The application is called on the thread that drives every connection, one
  request at a time, so a slow request holds up all the others.
- Streaming response bodies (`call`) are not supported.
- CI runs it on Ruby 4.0 alone, not on 3.3, the oldest it installs on. It is
  checked against curl and the clients of quic-interop-runner, over links
  with no loss or delay, and has not been run under load or over lossy
  networks.

## Installation

Linux only, Ruby 3.3 or later. Like the quic gem, installing builds C code, so
it needs a C compiler, pkg-config and the OpenSSL development package
(`build-essential pkg-config libssl-dev` on Debian and Ubuntu).

```bash
bundle add http3
```

or, without Bundler:

```bash
gem install http3
```

## Usage

There is no `rackup` handler or command; start the server from a script:

```ruby
# server.rb
require "http3"
require "rack"

app = Rack::Builder.parse_file("config.ru")

HTTP3::Server.new(
  app: app,
  bind: "192.0.2.1:443",
  certificate_path: "/etc/tls/fullchain.pem",
  private_key_path: "/etc/tls/privkey.pem"
).run
```

`bind` is one address, `"host:port"` or `"[2001:db8::1]:443"`. It has to name
the address to serve: `0.0.0.0` and `[::]` are refused. The certificate file
is a PEM chain, leaf first, and the key a PEM key without passphrase.

Other options, with their defaults:

| Option | Default | |
| --- | --- | --- |
| `max_connections:` | `1024` | Connections at once; more are refused with CONNECTION_REFUSED |
| `max_request_body:` | `1_048_576` | Bytes of request body; more gets 413 |
| `max_field_section_size:` | `65_536` | Bytes of request headers (RFC 9114 §4.2.2); more gets 431 |
| `max_connection_request_buffer:` | `4_194_304` | Bytes of memory a connection's requests may hold before they reach the application (headers counted as RFC 9114 §4.2.2 does, and bodies up to `request_body_buffer_size:`); more gets 503 |
| `max_total_request_buffer:` | `67_108_864` | The same over all connections; more gets 503 |
| `request_body_buffer_size:` | `65_536` | Bytes of a request body kept in memory; a longer body goes to a temporary file, all of it |
| `max_connection_request_spool:` | `16_777_216` | Bytes of request bodies a connection may hold in temporary files; more gets 503 |
| `max_total_request_spool:` | `1_073_741_824` | The same over all connections |
| `max_connection_request_spool_files:` | `16` | Request bodies a connection may hold in temporary files at once; more gets 503 |
| `max_total_request_spool_files:` | `256` | The same over all connections |
| `send_buffer_size:` | `65_536` | Bytes of a response body queued but unsent per stream |
| `max_connection_send_buffer:` | `1_048_576` | Bytes of array and `each` response bodies a connection may have queued but unsent; more waits |
| `max_total_send_buffer:` | `67_108_864` | The same over all connections |
| `request_timeout:` | `30` | Seconds a request may take to come in full, counted from its headers; later gets 408. `nil` for no limit |
| `refusal_log_interval:` | `60` | Seconds between the `requests_refused` log lines, which count the requests answered without the application (400, 408, 413, 431, 501, 503) |
| `shutdown_timeout:` | `30` | Seconds a graceful stop waits for the requests under way |
| `qlog_dir:` | `nil` | Directory for one qlog file per connection |
| `transport_params:` | `QUIC::TransportParams.default` | QUIC transport parameters |
| `settings:` | `QUIC::Settings.default` | QUIC settings (the ALPN is always `h3`) |
| `logger:` | `Logger.new($stderr)` | Where failures are logged |

A request body over `request_body_buffer_size:` is written to an unnamed
file in `Dir.tmpdir` (`TMPDIR`, or `/tmp`), on the thread that drives every
connection. Where `/tmp` is a tmpfs, as on Debian 13 and Fedora, that file
is in memory; set `TMPDIR` to a directory on disk. A body still has to
arrive within `request_timeout:`, so raise it together with
`max_request_body:`.

`max_connection_request_buffer:` has to be at least `max_field_section_size:`
plus `max_request_body:`, or `request_body_buffer_size:` if that is smaller;
`max_total_request_buffer:` at least `max_connection_request_buffer:`; when
a body may go to a file, `max_connection_request_spool:` at least
`max_request_body:`; `max_total_request_spool:` at least
`max_connection_request_spool:`; and `max_total_request_spool_files:` at
least `max_connection_request_spool_files:`. That way a request within the
limits never gets 503 from an idle server; otherwise `HTTP3::Server.new`
raises `ArgumentError`. When a body may go to a file, `HTTP3::Server.new`
also makes one in `Dir.tmpdir`, and raises what that raises.

A request gets 413, 431 or 503 as soon as it passes a limit, without waiting
for the rest of it, and the server reads no more of it (STOP_SENDING with
H3_NO_ERROR). The 503 has neither headers nor body.

A request gets 400, without the application seeing it, when its scheme is
not `http` or `https`, its path has a fragment, its authority is not `host`
or `host:port`, or its `:authority` and `host` field differ. `CONNECT` gets
501: the server opens no tunnels.

Response bodies may be files (`to_path`, sent 16 KiB at a time as the
connection takes them), arrays or anything with `each`. These get 500:
streaming bodies (`call`), which are not supported; a status outside
200..599; response headers whose names are not lowercase tokens or whose
values contain NUL, CR or LF; a `content-length` given more than once, not a
number, or not the length of a file or array body; and an array body with a
chunk that is not a String. A body read with `each` is counted as it is
sent, and its stream is aborted (H3_INTERNAL_ERROR) once it goes past
`content-length` or ends short of it. The `content-length` of a 204 is
dropped.

### Signals

- `SIGTERM` or `SIGINT` stops gracefully: every client gets GOAWAY, new
  connections are refused, and the server waits up to `shutdown_timeout`
  seconds for the requests under way before closing every connection. A
  second signal stops the wait.
- `SIGHUP` reads the certificate and key again; new connections use them,
  existing ones keep theirs. If they cannot be loaded, the server keeps the
  old ones and logs `tls_reload_failed`.

### Logging and qlog

Only failures are logged, one line each: the event, then `key=value` pairs.
Query strings and header values never appear. There is no access log; add
`Rack::CommonLogger` to your `config.ru` for one:

```ruby
use Rack::CommonLogger
run MyApp
```

`qlog_dir:` writes `<qlog_dir>/<connection ID>.sqlog` for every connection,
for tools such as [qvis](https://qvis.quictools.info/).

### Browsers

Browsers find HTTP/3 through an `Alt-Svc` header on an HTTP/1.1 or HTTP/2
response from the same host, so a TCP server there has to send

```
alt-svc: h3=":443"
```

That is configured in that server (nginx, Puma, ...), not in this gem.

### HTTP3::Nghttp3

The bindings keep nghttp3's rules for its callers, so that a wrong call
raises instead of crashing the process or reaching freed memory:

- A callback (a `Callbacks` block or a body block) runs while nghttp3 is in
  the middle of a call. Inside the callbacks of `read_stream`, it may call
  `submit_*`, `resume_stream`, `block_stream`, `unblock_stream`,
  `shutdown_stream_read`, `shutdown_stream_write`, `submit_shutdown_notice`,
  `shutdown`, `set_max_client_streams_bidi` and `stream_writable?` on the
  same connection. `close`, `read_stream`, `writev_stream` and the rest
  raise `InvalidStateError` there, and inside any other callback every call
  into nghttp3 does.
- Once nghttp3 reports a connection error, only `#close` can be called; the
  rest raise `InvalidStateError`.
- `NV_FLAG_NO_COPY_NAME` and `NV_FLAG_NO_COPY_VALUE` are ignored: names and
  values are always copied.
- Stream ids are checked for their range and kind, and calls for the role
  and state of the connection, raising `ArgumentError` and
  `InvalidStateError` instead of tripping nghttp3's assertions.
- A `QPACK::Decoder` decodes at most `MAX_STREAMS` (2000) streams at once.

The signatures in `sig/` describe each method.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then,
run `bundle exec rake` to build the extension, run the tests and lint. You can
also run `bin/console` for an interactive prompt.

`test/interop/` holds the checks against other HTTP/3 implementations (curl,
h3i, quic-interop-runner, browsers); see its README.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/unasuke/http3-ruby. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/unasuke/http3-ruby/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT). The licenses of the nghttp3 code built into it are in `LICENSE-DEPENDENCIES.txt`.

## Code of Conduct

Everyone interacting in the http3-ruby project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/unasuke/http3-ruby/blob/main/CODE_OF_CONDUCT.md).
