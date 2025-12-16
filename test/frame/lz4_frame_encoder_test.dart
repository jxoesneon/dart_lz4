import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

void main() {
  test('lz4FrameEncode round-trips empty input', () {
    final src = Uint8List(0);
    final encoded = lz4FrameEncode(src);
    final decoded = lz4FrameDecode(encoded);
    expect(decoded, src);
  });

  test('lz4FrameEncode round-trips small input', () {
    final src = Uint8List.fromList('Hello world'.codeUnits);
    final encoded = lz4FrameEncode(src);
    final decoded = lz4FrameDecode(encoded);
    expect(decoded, src);
  });

  test('lz4FrameEncode round-trips >4MiB input (multi-block)', () {
    const size = (4 * 1024 * 1024) + 123;

    final rng = Random(1);
    final src = Uint8List(size);
    for (var i = 0; i < src.length; i++) {
      src[i] = rng.nextInt(256);
    }

    final encoded = lz4FrameEncode(src, acceleration: 1);
    final decoded = lz4FrameDecode(encoded);
    expect(decoded, src);
  });
}
