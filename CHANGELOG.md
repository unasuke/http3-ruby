## [Unreleased]

### Fixed
- `GC.compact` could move a connection while nghttp3 held its address for callbacks. nghttp3 now gets a pointer to the C struct instead.

## [0.1.0] - 2025-12-19

- Initial release
