# dart_lz4

Pure Dart implementation of LZ4 (block + frame) and LZ4HC, including streaming frame encode/decode.

Repository: <https://github.com/jxoesneon/dart_lz4>

## Status

This package is under active development.

Implemented:

- LZ4 block encode/decode
- LZ4 frame encode/decode
- Streaming frame encode/decode (`StreamTransformer`)
- LZ4HC block compression

## Goals

- Pure Dart (no FFI)
- Web-safe core (no `dart:io` in library code)
- Strict, bounds-safe decoding with deterministic errors
- Streaming-friendly APIs with output limits
- Compatibility with LZ4 frame format (current)

## Limitations

- **Encoding** content sizes > 4GiB is not supported (decoding is supported).

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
| Skippable frames (magic `0x184D2A5x`) | Yes | No | Skippable frames are ignored on decode. |
| Independent blocks (`blockIndependence: true`) | Yes | Yes | Default. |
| Dependent blocks (`blockIndependence: false`) | Yes | Yes | Uses a 64KiB history window. |
| Block checksum | Yes | Yes | |
| Content checksum | Yes | Yes | |
| Content size (<= 4GiB) | Yes | Yes | |
| Content size (> 4GiB) | Yes | Yes | |
| Dictionary ID (`dictId`) | Yes | Yes | |
| Legacy `-l` format | Yes | No | Decode supports legacy frame magic `0x184C2102`. |

## Roadmap (high level)

- xxHash32 (streaming) with VM + dart2js parity
- LZ4 block decode/encode
- LZ4 frame decode/encode
- Streaming APIs
- LZ4HC

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
