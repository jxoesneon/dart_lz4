import 'dart:typed_data';
import 'package:dart_lz4/src/xxhash/xxh32.dart';

void main() {
  final size = 1024 * 1024;
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = i & 0xff;
  }

  print('Benchmarking xxHash32 on ${size / (1024 * 1024)} MiB buffer...');

  // Warmup
  for (var i = 0; i < 100; i++) {
    xxh32(data, seed: 0);
  }

  final sw = Stopwatch()..start();
  const iterations = 500;
  var sum = 0;
  for (var i = 0; i < iterations; i++) {
    sum += xxh32(data, seed: 0);
  }
  sw.stop();

  final totalBytes = size * iterations;
  final mb = totalBytes / (1024 * 1024);
  final seconds = sw.elapsedMicroseconds / 1000000;
  final speed = mb / seconds;

  print('Checksum: $sum (ensure not optimized away)');
  print('Speed: ${speed.toStringAsFixed(2)} MiB/s');
}
