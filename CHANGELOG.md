## [Unreleased]

### Added
- `Nghttp3::Connection#read_stream` takes `ts:`, the time in nanoseconds for nghttp3's rate limits (CLOCK_MONOTONIC by default), and now calls `nghttp3_conn_read_stream2`. ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))
- `Nghttp3::Connection#shutdown_stream_read`, `#set_max_client_streams_bidi` and `#pending_data`. ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))

### Fixed
- An exception raised by a callback block or a body block no longer unwinds through nghttp3's frames, which left nghttp3 in an inconsistent state. It is kept until nghttp3 returns and then raised from the method that called into it (`#read_stream`, `#writev_stream`, `#add_ack_offset`, ...). ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))
- Body Strings are let go once the peer has acknowledged them, and when their stream closes. Before, a connection kept every body it ever sent. ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))
- A body String is copied and frozen when submitted, and pinned until acknowledged, so neither the application nor `GC.compact` can change the bytes nghttp3 still reads. ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))
- `GC.compact` could move a connection while nghttp3 held its address for callbacks. nghttp3 now gets a pointer to the C struct instead. ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))
- `Connection.client_new` and `.server_new` raise `TypeError` for callbacks that are not an `Nghttp3::Callbacks`, instead of crashing in the first callback. ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))
- The GC could crash collecting a `Nghttp3::QPACK::Decoder`: freeing its stream contexts walked a Hash the GC might already have freed, and read the contexts' addresses wrongly from it. ([#2](https://github.com/unasuke/nghttp3-ruby/pull/2))

## [0.1.0] - 2025-12-19

- Initial release
