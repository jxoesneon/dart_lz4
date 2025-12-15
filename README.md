# dart_lz4

Pure Dart implementation of LZ4 (block + frame) with planned LZ4HC support.

Repository: https://github.com/jxoesneon/dart_lz4

## Status

This package is under active development. The public API in `lib/dart_lz4.dart` is currently a stub and will throw `UnimplementedError()`.

## Goals

- Pure Dart (no FFI)
- Web-safe core (no `dart:io` in library code)
- Strict, bounds-safe decoding with deterministic errors
- Streaming-friendly APIs with output limits
- Compatibility with LZ4 frame format (current) and best-effort legacy frame decode

## Roadmap (high level)

- xxHash32 (streaming) with VM + dart2js parity
- LZ4 block decode/encode
- LZ4 frame decode/encode
- Streaming APIs
- LZ4HC

## License

Apache-2.0. See `LICENSE`.
