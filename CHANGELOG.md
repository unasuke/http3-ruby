## [Unreleased]

### Fixed
- `GC.compact` could move a connection while nghttp3 held its address for callbacks. nghttp3 now gets a pointer to the C struct instead.
- `Connection.client_new` and `.server_new` raise `TypeError` for callbacks that are not an `Nghttp3::Callbacks`, instead of crashing in the first callback.

## [0.1.0] - 2025-12-19

- Initial release
