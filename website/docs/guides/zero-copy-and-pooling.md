---
sidebar_position: 2
---

# Zero-Copy & Buffer Pooling

`dart_lz4` v1.3.0 introduces zero-copy decompression and power-of-two buffer pooling for high-throughput, low-latency data pipelines in pure Dart.

## Zero-Copy Decompression

In high-concurrency environments (e.g. database engines, networking stacks, cache layers), intermediary heap allocations add significant garbage collection pressure.

`lz4DecompressInto` writes decompressed bytes directly into a pre-allocated destination buffer:

```dart
import 'dart:typed_data';
import 'package:dart_lz4/dart_lz4.dart';

void main() {
  final input = Uint8List.fromList('Zero-copy streaming decompression'.codeUnits);
  final compressed = lz4Compress(input);

  // Pre-allocated destination
  final destination = Uint8List(input.length);
  final written = lz4DecompressInto(compressed, destination);

  print('Decompressed $written bytes directly into destination buffer');
}
```

### Offset Slices & Memory Arenas

`lz4DecompressInto` supports writing to an arbitrary offset within a larger memory arena or slab:

```dart
final arena = Uint8List(1024 * 1024); // 1MB arena
final offset = 128;

final written = lz4DecompressInto(compressed, arena, dstOffset: offset);
```

Security note: The decoder enforces bounds checks to ensure match copy operations never read memory backwards across `dstOffset`, guaranteeing isolation within multi-tenant buffers.

---

## Buffer Pooling

Streaming decompression and compression can leverage `Lz4BufferPool` to reuse power-of-two memory slabs (64B to 8MB):

```dart
import 'package:dart_lz4/dart_lz4.dart';

// Standard buffer pool
final pool = SimpleLz4BufferPool(
  maxTotalBuffers: 128,
  maxBuffersPerBucket: 16,
);

// Stream transformation with pooling
final stream = rawChunkStream.transform(
  lz4FrameDecoder(bufferPool: pool),
);
```

### Secure Sanitization (CWE-226 Mitigation)

For cryptographic or sensitive applications, `SecureLz4BufferPool` performs cryptographic zeroization (`fillRange(0, buffer.length, 0)`) upon buffer check-in:

```dart
final securePool = SecureLz4BufferPool();
```
