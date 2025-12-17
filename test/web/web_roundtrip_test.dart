import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

Uint8List _payload({required int size, required int seed}) {
  final r = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < out.length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

Iterable<List<int>> _chunk(Uint8List bytes) sync* {
  const sizes = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610];
  var offset = 0;
  var i = 0;
  while (offset < bytes.length) {
    final size = sizes[i % sizes.length];
    final end = (offset + size) > bytes.length ? bytes.length : (offset + size);
    yield bytes.sublist(offset, end);
    offset = end;
    i++;
  }
}

Uint8List _concat(List<List<int>> chunks) {
  final builder = BytesBuilder(copy: false);
  for (final c in chunks) {
    builder.add(c);
  }
  return builder.takeBytes();
}

void main() {
  test('block round-trips', () {
    final src = _payload(size: 64 * 1024 + 7, seed: 1);

    final compressed = lz4Compress(src, level: Lz4CompressionLevel.fast);
    final decoded = lz4Decompress(compressed, decompressedSize: src.length);

    expect(decoded, src);
  });

  test('frame round-trips with dependent blocks', () {
    final src = _payload(size: 128 * 1024 + 123, seed: 2);

    final frame = lz4FrameEncodeWithOptions(
      src,
      options: Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k64KB,
        blockIndependence: false,
        blockChecksum: true,
        contentChecksum: true,
        contentSize: src.length,
        compression: Lz4FrameCompression.fast,
        acceleration: 1,
      ),
    );

    final decoded = lz4FrameDecode(frame, maxOutputBytes: src.length);
    expect(decoded, src);
  });

  test('streaming frame encode/decode round-trips', () async {
    final src = _payload(size: 96 * 1024 + 11, seed: 3);

    final encodedChunks = await Stream<List<int>>.fromIterable(_chunk(src))
        .transform(
          lz4FrameEncoderWithOptions(
            options: Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: false,
              contentChecksum: true,
            ),
          ),
        )
        .toList();

    final decodedChunks = await Stream<List<int>>.fromIterable(encodedChunks)
        .transform(lz4FrameDecoder(maxOutputBytes: src.length))
        .toList();

    expect(_concat(decodedChunks), src);
  });
}
