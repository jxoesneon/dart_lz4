# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

## [0.0.8] - 2025-12-18

- **Performance**: Significant reduction in allocations for LZ4 frame encoding (sync and streaming) by reusing internal buffers.
- **Performance**: Optimized `xxHash32` calculation using typed data views for ~1.5x speedup on aligned data.
- **API**: Exposed `Lz4HcOptions` in `lz4Compress` to allow tuning LZ4HC compression (e.g. `maxSearchDepth`).
- **Example**: Added comprehensive CLI example (`example/lz4_cli.dart`).

## [0.0.7] - 2025-12-18

- **Feature Parity**: Achieved feature parity with LZ4 frame specification and other language implementations.
- Add `lz4FrameInfo` to inspect frame metadata (flags, content size, dictionary ID, etc.) without decoding.
- Add support for LZ4 frames with Dictionary ID (`dictId`) via `dictionaryResolver` callback in `lz4FrameDecode` and `lz4FrameDecoder`.
- Add support for 64-bit `contentSize` in frame headers (previously limited to 4GiB).
- Add convenience helpers `lz4CompressWithSize` and `lz4DecompressWithSize` for simple size-prepended block compression.

## [0.0.6] - 2025-12-18

- Fix xxHash32 parity on dart2js by enforcing strict 32-bit arithmetic and updating vectors.
- Reduce allocations in LZ4 block and LZ4HC encoders by reusing scratch buffers.
- Optimize streaming frame encoder history window shifting.
- Make CLI interop tests VM-only so `dart test -p chrome` can run without `dart:io` failures.
- Add benchmark baseline snapshot and a helper tool to compare benchmark output to baseline.
- Run full test suite on Chrome in CI.

## [0.0.5] - 2025-12-17

- Add legacy LZ4 frame decode support (`lz4 -l` / magic `0x184C2102`) for sync and streaming decoders.
- Add additional frame interop vectors and streaming boundary tests.
- Add benchmark methodology docs and optional scheduled CI benchmark workflow.
- Add security/supply-chain workflows and maintainer documentation updates.

## [0.0.4] - 2025-12-16

- Add streaming LZ4 frame encode (`lz4FrameEncoder`) alongside streaming decode.
- Add CI enforcement for `dart doc` and `pana 0.23.3`.
- Improve public API Dartdoc coverage.
- Update README and example for streaming frame encode usage.

## [0.0.3] - 2025-12-16

- Implement LZ4 block encode/decode.
- Implement LZ4 frame encode/decode and streaming frame decode.
- Add xxHash32 implementation, including incremental (streaming) support.
- Implement initial LZ4HC block compression and wire `lz4Compress(level: hc)`.
- Add unit tests and benchmarks covering block/frame/LZ4HC.

## [0.0.2] - 2025-12-15

- Prepare v0.0.2 to validate automated publishing via GitHub Actions.

## [0.0.1] - 2025-12-15

- Initial repository scaffolding.
- Add core internal primitives (ByteReader/ByteWriter) and unit tests.
