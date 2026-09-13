# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

- **Security**: Added default `maxOutputBytes` (256 MiB) to the streaming frame decoder (`lz4FrameDecoder`), closing a decompression bomb vector (CWE-400) that contradicted the project's stated "bounds-safe decoding" goal. The sync decoder already had this default.
- **Security**: Documented `lz4BlockDecompressInto` partial-output behavior — truncated blocks that end after a literal-only sequence produce partial output without error. Callers should verify `writer.length` against expected size.
- **API**: Exposed `bufferPool` parameter on the public `lz4FrameDecode` and `lz4FrameDecoder` APIs, matching the internal implementation.
- **API**: Added `Lz4Codec` — a `dart:convert` `Codec<List<int>, List<int>>` wrapper for LZ4 frame encode/decode, enabling composition with the Dart conversion ecosystem (e.g. `json.fuse(Lz4Codec())`). Enforces a 256 MiB default `maxOutputBytes` per Safety mandate.
- **Refactor**: Extracted shared LZ4 frame constants (`lz4FrameMagic`, `lz4SkippableMagicBase`, `lz4LegacyFrameMagic`, `decodeBlockMaxSize`, `isLegacyBoundary`) into `lib/src/internal/lz4_frame_constants.dart`, eliminating duplication across 5 files.
- **Refactor**: Extracted shared block codec helpers (`writeSequence`, `writeLastLiterals`, `writeLength`) into `lib/src/internal/lz4_block_codec.dart`, eliminating duplication between fast and HC block encoders.
- **Fix**: Removed dead if/else in `lz4LegacyFrameEncode` — both branches were identical.
- **Fix**: Fixed `lz4_sized_block.dart` upward import from the public barrel — now imports internal block encoder/decoder directly.
- **Fix**: Reset hash table state between `compress()` calls in both fast and HC engines to prevent stale entries leaking across blocks during frame encoding.
- **Performance**: Replaced manual byte loop in `_appendHistory` with `List.copyRange`.
- **Performance**: Changed `_descriptorBytes` from `List<int>` to `Uint8List` to avoid checksum copy overhead.
- **Docs**: Documented `Xxh32.digest()` lifecycle — internal state is not reset after `digest()`.
- **Docs**: Replaced README "Limitations: None" with an honest list (no FFI, single-threaded, Web precision, non-cryptographic checksums, dictionary allocation).
- **CI**: Added frame fuzzing to the fuzzing workflow (`fuzz/frame_fuzzer.dart`), covering random frame decompression, bitflip corruption, streaming chunk decoding, and `maxOutputBytes` enforcement.
- **Maintenance**: Removed unused `analyzer` dev dependency.

## [1.3.0] - 2026-09-12

- **Feature**: Introduced zero-copy decompression API `lz4DecompressInto(Uint8List src, Uint8List dst, {int dstOffset = 0})` and `lz4BlockDecompressIntoBuffer` for decompressing directly into pre-allocated destination buffers without intermediary allocations.
- **Memory**: Exposed public `Lz4BufferPool` architecture (`SimpleLz4BufferPool`, `SecureLz4BufferPool`) featuring power-of-two slab bucketing (64B to 8MB), capacity limits, decompression bomb defenses, and secure zeroization mitigating CWE-226 memory disclosure.
- **Streaming**: Integrated `Lz4BufferPool` into `Lz4FrameOptions`, `lz4FrameDecoder`, `lz4FrameStreamDecoder`, and `lz4FrameStreamEncoder` for zero-allocation streaming pipelines.
- **Performance**: Modularized 64-bit VM wildcopy and 32-bit Web wildcopy via conditional imports (`_wildcopy_vm.dart` and `_wildcopy_web.dart`), optimizing decompression speed across all runtime targets.
- **Quality & Testing**: Achieved 100.0% code line test coverage (1527 / 1527 lines) verified on both Dart VM and Web/Chrome environments with 366+ passing test cases.
- **Supply Chain**: Pinned all GitHub Actions workflow actions to immutable commit SHAs with least-privilege permissions, achieving 10/10 OSSF Scorecard supply-chain hardening.

## [1.2.0] - 2026-05-01

- **Performance**: Implemented "Guarded Wildcopy" decompression (8-byte chunk copies), providing ~45–117% throughput gains on random data.
- **Performance**: Implemented VM-specialized `xxHash32` multiplication (via conditional imports), yielding 20–40% checksumming speedups on the VM.
- **Architecture**: Refactored block/HC encoders into a `Polymorphic Engine Interface`, future-proofing the library for FFI support.
- **Memory**: Added `Lz4BufferPool` for zero-allocation streaming, eliminating garbage collection pressure in high-throughput pipelines.
- **API**: Standardized HC levels (1–12) to match C-reference ergonomics.
- **Security**: Added continuous fuzzing (ClusterFuzzLite) and buffer leakage security tests to prevent stale memory exposure.
- **Compatibility**: Fixed critical Web compatibility issue (Uint64 unsupported on Web) by implementing a robust 32-bit wildcopy fallback for browser environments.
- **Maintenance**: Fully remediated OSSF Scorecard gaps (Fuzzing, Best Practices, Branch Protection).

- **Fix**: Triggered an automated release workflow to ensure a clean publish to pub.dev after fixing release pipeline configuration.

## [1.1.0] - 2026-04-17

- **Security**: Hardened legacy and skippable frame decoders against memory exhaustion (DoS) by enforcing strict sizing bounds (8MB max for legacy, 2GB ceiling for skippable).
- **Security**: Hardened block decoders against CPU exhaustion via malformed extended length sequences.
- **Security**: Added robust `try-catch` boundaries around block decoders to prevent fuzzing data from leaking internal VM exceptions (`RangeError`, `StateError`).
- **Compliance**: Enforced strict LZ4 specification compliance in both standard and HC encoders: the last 5 bytes must be literals, and the last match must end at least 12 bytes before the block end.
- **Performance**: Fixed an `O(N^2)` buffer compaction trap in the streaming frame decoder, significantly improving throughput on heavily fragmented streams.
- **Performance**: Optimized HC encoder match searching to immediately break when candidates exceed the 65,535 sliding window, eliminating deep-search CPU stalls on sparse data.
- **Fix**: Prevented "circular chain" logic poisoning in the HC encoder that could lead to infinite loops.
- **Fix**: Implemented Web (JavaScript) precision loss safeguards for 64-bit content size integers exceeding 53 bits.
- **Maintenance**: Resolved all static analysis warnings.

## [1.0.0] - 2025-12-19

- **Feature**: Added `lz4SkippableEncode` for encoding skippable frames (user-defined metadata).
- **Feature**: Added `lz4LegacyEncode` for encoding legacy LZ4 frames (`lz4 -l` format).
- **Complete**: All LZ4 frame formats now have full encode/decode support.
- **Milestone**: First stable release with 100% LZ4 frame specification coverage.

## [0.0.9] - 2025-12-18

- **Feature**: Added support for encoding LZ4 frames with a dictionary (`dictId`). This allows for significantly better compression ratios on small payloads when sharing a dictionary.
- **Feature**: Added support for encoding LZ4 frames with 64-bit `contentSize` (previously limited to 4GiB).
- **Performance**: Optimized `xxHash32` (streaming) to use aligned memory access for better throughput.

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
