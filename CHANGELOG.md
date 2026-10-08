## [Unreleased]

### Fixed
- An exception raised by a callback block or a body block no longer unwinds through nghttp3's frames, which left nghttp3 in an inconsistent state. It is kept until nghttp3 returns and then raised from the method that called into it (`#read_stream`, `#writev_stream`, `#add_ack_offset`, ...).
- `GC.compact` could move a connection while nghttp3 held its address for callbacks. nghttp3 now gets a pointer to the C struct instead.
- `Connection.client_new` and `.server_new` raise `TypeError` for callbacks that are not an `Nghttp3::Callbacks`, instead of crashing in the first callback.

## [0.1.0] - 2025-12-19

- Initial release
