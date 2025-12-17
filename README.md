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
- Compatibility with LZ4 frame format (current) and best-effort legacy frame decode

## Limitations

- Frames with the **Dictionary ID (`dictId`) flag** are not supported.
- **Content sizes > 4GiB** are not supported.

## Security / untrusted input

- Always set a reasonable `maxOutputBytes` when decoding frames (`lz4FrameDecode` / `lz4FrameDecoder`) to mitigate decompression bombs.
- Use `blockChecksum` and/or `contentChecksum` when encoding if you want corruption detection. These checksums are **not** cryptographic authentication.
- For block decompression (`lz4Decompress`), `decompressedSize` must be known and trusted/validated.

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
final compressed = lz4Compress(src, level: Lz4CompressionLevel.hc);
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
