# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

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
