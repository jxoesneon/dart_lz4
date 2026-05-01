---
sidebar_position: 1
---

# Getting Started with dart_lz4

**dart_lz4** is a high-performance, pure Dart implementation of LZ4 and LZ4HC compression. 
It supports block and frame formats, streaming, dictionaries, and HC mode, all while being completely Web-safe and dependency-free.

## Features
- **Guarded Wildcopy:** 8-byte chunk copying with a fast 32-bit fallback for Web environments.
- **Polymorphic Compression Engine:** Zero-allocation architecture designed for both VM speed and FFI future-proofing.
- **Reference Standard Compliance:** 100% compatibility with the official C-reference implementation.
- **Continuous Security:** Fully fuzzed and verified against buffer leaks and DOS vectors.

## Installation

Add it to your `pubspec.yaml`:

```yaml
dependencies:
  dart_lz4: ^1.2.0
```

Or run:
```bash
dart pub add dart_lz4
```

## Quick Start

```dart
import 'dart:convert';
import 'package:dart_lz4/dart_lz4.dart';

void main() {
  final input = utf8.encode('Hello dart_lz4! ' * 10);
  
  // Compress
  final compressed = lz4Compress(input);
  print('Compressed size: ${compressed.length} bytes');

  // Decompress
  final decompressed = lz4Decompress(compressed, input.length);
  print('Original: ${utf8.decode(decompressed)}');
}
```

Explore the Tutorials and Guides for advanced usage.
