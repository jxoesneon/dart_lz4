# dart_lz4

Pure Dart implementation of LZ4 (block + frame) and LZ4HC, including streaming frame encode/decode.

Repository: <https://github.com/jxoesneon/dart_lz4>

## Status

This package provides a **feature-complete** pure Dart implementation of the LZ4 frame format.

Implemented:

- LZ4 block encode/decode
- LZ4 frame encode/decode (including skippable and legacy frames)
- Streaming frame encode/decode (`StreamTransformer`)
- LZ4HC block compression
- Dictionary support (encode + decode)
- 64-bit content size (encode + decode)
- xxHash32 with VM + Web parity

## Goals

- Pure Dart (no FFI)
- Web-safe core (no `dart:io` in library code)
- Strict, bounds-safe decoding with deterministic errors
- Streaming-friendly APIs with output limits
- Compatibility with LZ4 frame format (current)

## Limitations

None. This package provides complete encode/decode support for all LZ4 frame formats.

## Security / untrusted input

- Always set a reasonable `maxOutputBytes` when decoding frames (`lz4FrameDecode` / `lz4FrameDecoder`) to mitigate decompression bombs.
- Use `blockChecksum` and/or `contentChecksum` when encoding if you want corruption detection. These checksums are **not** cryptographic authentication.
- For block decompression (`lz4Decompress`), `decompressedSize` must be known and trusted/validated.

## Interop / compatibility

Tested against the reference `lz4` CLI (`lz4 v1.10.0`) via embedded decode vectors and a CLI decode test.

| Feature | Decode | Encode | Notes |
| --- | --- | --- | --- |
| Current LZ4 frame (magic `0x184D2204`) | Yes | Yes | |
| Concatenated frames | Yes | N/A | You can concatenate multiple encoded frames yourself. |
| Skippable frames (magic `0x184D2A5x`) | Yes | Yes | Skipped on decode; use `lz4SkippableEncode` to create. |
| Independent blocks (`blockIndependence: true`) | Yes | Yes | Default. |
| Dependent blocks (`blockIndependence: false`) | Yes | Yes | Uses a 64KiB history window. |
| Block checksum | Yes | Yes | |
| Content checksum | Yes | Yes | |
| Content size (<= 4GiB) | Yes | Yes | |
| Content size (> 4GiB) | Yes | Yes | |
| Dictionary ID (`dictId`) | Yes | Yes | |
| Legacy `-l` format | Yes | Yes | Use `lz4LegacyEncode` for legacy frame magic `0x184C2102`. |

## Usage

### Block

Block decompression requires the decompressed size.

```dart
import 'dart:typed_data';
import 'package:dart_lz4/dart_lz4.dart';

final src = Uint8List.fromList('hello'.codeUnits);
final compressed = lz4Compress(src);
final decoded = lz4Decompress(compressed, decompressedSize: src.length);
```

### LZ4HC

```dart
final compressed = lz4Compress(
  src,
  level: Lz4CompressionLevel.hc,
  hcOptions: Lz4HcOptions(maxSearchDepth: 64), // Optional tuning
);
```

### Frame

```dart
final frame = lz4FrameEncode(src);
final decoded = lz4FrameDecode(frame);
```

### Frame with options

```dart
final frame = lz4FrameEncodeWithOptions(
  src,
  options: Lz4FrameOptions(
    blockSize: Lz4FrameBlockSize.k64KB,
    blockChecksum: true,
    contentChecksum: true,
    contentSize: src.length,
    compression: Lz4FrameCompression.fast,
    acceleration: 1,
  ),
);
final decoded = lz4FrameDecode(frame);
```

Dependent blocks are supported by setting `blockIndependence: false`. When enabled,
blocks may reference up to 64KiB of history from prior blocks.

### Frame Inspection

Inspect a frame header without decoding the payload:

```dart
final info = lz4FrameInfo(frameBytes);
print('Content Size: ${info.contentSize}');
print('Dictionary ID: ${info.dictId}');
```

### Dictionary Support

To decode frames that use a preset dictionary (identified by `dictId`):

```dart
final decoded = lz4FrameDecode(
  frameBytes,
  dictionaryResolver: (dictId) {
    if (dictId == 0x123456) return myDictionaryBytes;
    return null; // Dictionary not found
  },
);
```

### Skippable Frames

Embed custom metadata in an LZ4 stream using skippable frames:

```dart
import 'dart:convert';

final metadata = Uint8List.fromList(utf8.encode('{"version": 1}'));
final skippable = lz4SkippableEncode(metadata, index: 0);

// Concatenate with a regular frame
final combined = Uint8List.fromList([...skippable, ...lz4FrameEncode(data)]);

// Decoders will skip the metadata and decode only the payload
final decoded = lz4FrameDecode(combined);
```

### Legacy Frames

Encode data using the legacy LZ4 format (compatible with `lz4 -l`):

```dart
final frame = lz4LegacyEncode(src);
final decoded = lz4FrameDecode(frame);
```

### Sized Blocks

Simple helper for block compression with prepended 4-byte length header:

```dart
final compressed = lz4CompressWithSize(src);
final decoded = lz4DecompressWithSize(compressed);
```

### Streaming frame decode

```dart
final decodedChunks = byteChunksStream.transform(
  lz4FrameDecoder(maxOutputBytes: 128 * 1024 * 1024),
);
```

### Streaming frame encode

```dart
final encodedChunks = byteChunksStream.transform(
  lz4FrameEncoder(),
);
```

Streaming encoding also supports `Lz4FrameOptions`:

```dart
final encodedChunks = byteChunksStream.transform(
  lz4FrameEncoderWithOptions(
    options: Lz4FrameOptions(
      blockSize: Lz4FrameBlockSize.k64KB,
      blockIndependence: false,
    ),
  ),
);
```

## Benchmarks

Run:

```sh
dart run benchmark/lz4_benchmark.dart
```

It reports throughput (MiB/s) and ratio for:

- **Block** compress/decompress (fast + hc)
- **Frame (sync)** encode/decode (fast + hc)
- **Frame (streaming)** encode/decode (fast + hc)

## License

Apache-2.0. See `LICENSE`.
