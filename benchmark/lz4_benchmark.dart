import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';

void main() {
  final random1MiB = _randomBytes(1024 * 1024, seed: 1234);
  final repeat1MiB = _repeatingBytes(1024 * 1024);

  _bench('random 1MiB', random1MiB);
  _bench('repeating 1MiB', repeat1MiB);
}

void _bench(String name, Uint8List input) {
  final compressed = lz4Compress(input);
  final decompressed =
      lz4Decompress(compressed, decompressedSize: input.length);
  if (!_bytesEqual(decompressed, input)) {
    throw StateError('roundtrip mismatch');
  }

  final ratio = input.isEmpty ? 1.0 : compressed.length / input.length;
  print('--- $name ---');
  print('input: ${input.length} bytes');
  print(
      'compressed: ${compressed.length} bytes (ratio: ${ratio.toStringAsFixed(3)})');

  final compressMbPerSec = _throughput(
    () => lz4Compress(input),
    bytesProcessed: input.length,
  );

  final decompressMbPerSec = _throughput(
    () => lz4Decompress(compressed, decompressedSize: input.length),
    bytesProcessed: input.length,
  );

  print('compress: ${compressMbPerSec.toStringAsFixed(1)} MiB/s');
  print('decompress: ${decompressMbPerSec.toStringAsFixed(1)} MiB/s');
  print('');
}

double _throughput(
  Uint8List Function() fn, {
  required int bytesProcessed,
}) {
  const warmupIters = 8;
  const targetMs = 500;

  for (var i = 0; i < warmupIters; i++) {
    fn();
  }

  var iters = 1;
  while (true) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < iters; i++) {
      fn();
    }
    sw.stop();

    final elapsedMs = sw.elapsedMicroseconds / 1000.0;
    if (elapsedMs >= targetMs) {
      final bytesTotal = bytesProcessed * iters;
      final mib = bytesTotal / (1024.0 * 1024.0);
      final seconds = sw.elapsedMicroseconds / 1e6;
      return mib / seconds;
    }

    iters *= 2;
  }
}

Uint8List _randomBytes(int length, {required int seed}) {
  final r = Random(seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

Uint8List _repeatingBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = i & 0x1f;
  }
  return out;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
