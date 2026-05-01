---
sidebar_position: 1
---

# Your First Compressed Stream

Streaming allows you to compress or decompress massive files or network streams without loading everything into memory.

`dart_lz4` provides fully integrated `Converter`s that plug right into Dart's `dart:convert` streaming ecosystem.

## Encoding a Stream

```dart
import 'dart:io';
import 'package:dart_lz4/dart_lz4.dart';

Future<void> main() async {
  final input = File('large_data.json').openRead();
  final output = File('large_data.json.lz4').openWrite();

  // Pipe the raw stream through the LZ4 encoder
  await input
      .transform(lz4FrameEncoder())
      .pipe(output);
      
  print('Compression complete!');
}
```

## Decoding a Stream

```dart
import 'dart:io';
import 'package:dart_lz4/dart_lz4.dart';

Future<void> main() async {
  final input = File('large_data.json.lz4').openRead();
  final output = File('large_data.json.restored').openWrite();

  // Pipe the compressed stream through the LZ4 decoder
  await input
      .transform(lz4FrameDecoder())
      .pipe(output);
      
  print('Decompression complete!');
}
```

The streaming frame encoders automatically handle chunking and manage memory using our internal Zero-Allocation Buffer Pool, ensuring excellent performance and minimal garbage collection pressure.
