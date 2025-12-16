# dart_lz4

Pure Dart implementation of LZ4 (block + frame) and LZ4HC, including streaming frame decode.

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

## License

Apache-2.0. See `LICENSE`.
