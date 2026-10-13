## [Unreleased]

### Added
- `HTTP3::Server` serves a Rack 3 application over HTTP/3 on one UDP address: `HTTP3::Server.new(app:, bind:, certificate_path:, private_key_path:, **options).run`. Options: `transport_params`, `settings`, `qlog_dir`, `max_connections` (1024), `max_request_body` (1 MiB, 413 beyond), `max_field_section_size` (64 KiB, 431 beyond), `send_buffer_size` (64 KiB), `shutdown_timeout` (30 s) and `logger`. SIGTERM or SIGINT sends GOAWAY, refuses new connections and waits for the requests under way (a second signal stops waiting); SIGHUP reloads the certificate and key for new connections. Only failures are logged, as `event key=value ...` lines without query strings or header values. Response bodies may be files (`to_path`, read 16 KiB at a time), arrays (`to_ary`) or anything with `each`; streaming bodies (`call`) are answered with 500. Request fields whose names contain `_` are left out of the Rack env, so that they cannot pass for the dashed name (`x_forwarded_for` for `x-forwarded-for`). A response whose field names are not lowercase tokens, or whose field values contain NUL, CR or LF, is answered with 500. ([#5](https://github.com/unasuke/http3-ruby/pull/5))
- `HTTP3::Session`, HTTP/3 on one `QUIC::Connection::Server` through the quic gem's C function table; `HTTP3::RackAdapter`; and `HTTP3::Request`, `HTTP3::Response` and `HTTP3::Body`, the data passed between them. ([#5](https://github.com/unasuke/http3-ruby/pull/5))
- `HTTP3::Nghttp3::Connection#read_stream` takes `ts:`, the time in nanoseconds for nghttp3's rate limits (CLOCK_MONOTONIC by default), and now calls `nghttp3_conn_read_stream2`. ([#2](https://github.com/unasuke/http3-ruby/pull/2))
- `HTTP3::Nghttp3::Connection#shutdown_stream_read`, `#set_max_client_streams_bidi` and `#pending_data`. ([#2](https://github.com/unasuke/http3-ruby/pull/2))
- Tests of `HTTP3::RackAdapter`, of `HTTP3::Session` over a QUIC loopback connection, and of `HTTP3::Server` serving files and dynamic bodies and handling signals. An HTTP/3 interop check fetches from the server with curl in a container (`test/interop/curl.sh`), weekly in CI; `test/interop/README.md` describes the checks run by hand. ([#6](https://github.com/unasuke/http3-ruby/pull/6))

### Changed
- The gem is now `http3` (`require "http3"`), and the top-level namespace is `HTTP3`. The nghttp3 bindings move from `Nghttp3` to `HTTP3::Nghttp3`. No `Nghttp3` alias is left behind. ([#3](https://github.com/unasuke/http3-ruby/pull/3))
- nghttp3 is no longer taken from the system. Version 1.13.1 is downloaded and built at install time with mini_portile2 and linked statically, so `libnghttp3-dev` is no longer needed. http3.so exports only `Init_http3`; the nghttp3 symbols stay hidden. ([#3](https://github.com/unasuke/http3-ruby/pull/3))
- Ruby 3.3 or later is required, and only Linux is supported. ([#3](https://github.com/unasuke/http3-ruby/pull/3))
- http3 depends on the quic gem (`~> 0.0.3`) and, when loaded, looks up the C function table it publishes in `quic/ext.h`. A quic gem without a compatible table makes `require "http3"` raise `LoadError` naming the ABI version needed and the quic version found. ([#4](https://github.com/unasuke/http3-ruby/pull/4))

### Removed
- The Ruby helpers on the bindings (`Nghttp3::Client`, `Server`, `Request`, `Response`, `Headers` and `StreamManager`). `HTTP3::Server` replaces the server side; the client side lives on in the tests only. ([#5](https://github.com/unasuke/http3-ruby/pull/5))

### Fixed
- An exception raised by a callback block or a body block no longer unwinds through nghttp3's frames, which left nghttp3 in an inconsistent state. It is kept until nghttp3 returns and then raised from the method that called into it (`#read_stream`, `#writev_stream`, `#add_ack_offset`, ...). ([#2](https://github.com/unasuke/http3-ruby/pull/2))
- Body Strings are let go once the peer has acknowledged them, and when their stream closes. Before, a connection kept every body it ever sent. ([#2](https://github.com/unasuke/http3-ruby/pull/2))
- A body String is copied and frozen when submitted, and pinned until acknowledged, so neither the application nor `GC.compact` can change the bytes nghttp3 still reads. ([#2](https://github.com/unasuke/http3-ruby/pull/2))
- `GC.compact` could move a connection while nghttp3 held its address for callbacks. nghttp3 now gets a pointer to the C struct instead. ([#2](https://github.com/unasuke/http3-ruby/pull/2))
- `Connection.client_new` and `.server_new` raise `TypeError` for callbacks that are not an `HTTP3::Nghttp3::Callbacks`, instead of crashing in the first callback. ([#2](https://github.com/unasuke/http3-ruby/pull/2))
- The GC could crash collecting an `HTTP3::Nghttp3::QPACK::Decoder`: freeing its stream contexts walked a Hash the GC might already have freed, and read the contexts' addresses wrongly from it. ([#2](https://github.com/unasuke/http3-ruby/pull/2))

## [0.0.2] - 2026-10-13

- The last release as the `nghttp3` gem: its description says that the gem is no longer maintained. The code is that of 0.0.1.

## [0.0.1] - 2026-01-31

- Initial release, as the `nghttp3` gem
