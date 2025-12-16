import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

Iterable<List<int>> _chunk(Uint8List bytes, List<int> sizes) sync* {
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
  test('lz4FrameEncoder transformer encodes chunked input', () async {
    final src = Uint8List.fromList('Hello streaming frame encode'.codeUnits);

    final encodedChunks = await Stream<List<int>>.fromIterable(
      _chunk(src, [1, 2, 3, 1, 5, 8]),
    ).transform(lz4FrameEncoder()).toList();

    final encoded = _concat(encodedChunks);
    final decoded = lz4FrameDecode(encoded);

    expect(decoded, src);
  });

  test('lz4FrameEncoder transformer round-trips via streaming decoder',
      () async {
    final src =
        Uint8List.fromList('Round-trip streaming encode/decode'.codeUnits);

    final outChunks = await Stream<List<int>>.fromIterable(
      _chunk(src, [1, 1, 2, 3, 5, 8]),
    ).transform(lz4FrameEncoder()).transform(lz4FrameDecoder()).toList();

    expect(_concat(outChunks), src);
  });

  test('lz4FrameEncoder transformer encodes empty input', () async {
    final encodedChunks = await const Stream<List<int>>.empty()
        .transform(lz4FrameEncoder())
        .toList();

    final decoded = lz4FrameDecode(_concat(encodedChunks));
    expect(decoded, Uint8List(0));
  });

  test('lz4FrameEncoder validates acceleration', () {
    expect(() => lz4FrameEncoder(acceleration: 0), throwsA(isA<RangeError>()));
  });

  test('lz4FrameEncoderWithOptions encodes with checksums and content size',
      () async {
    final src = Uint8List.fromList('Hello streaming options'.codeUnits);
    final options = Lz4FrameOptions(
      blockSize: Lz4FrameBlockSize.k64KB,
      blockChecksum: true,
      contentChecksum: true,
      contentSize: src.length,
    );

    final encodedChunks = await Stream<List<int>>.fromIterable(
      _chunk(src, [1, 2, 3, 1, 5, 8]),
    ).transform(lz4FrameEncoderWithOptions(options: options)).toList();

    final encoded = _concat(encodedChunks);
    final decoded = lz4FrameDecode(encoded);
    expect(decoded, src);
  });

  test('lz4FrameEncoderWithOptions supports hc compression', () async {
    final src = Uint8List.fromList(List<int>.filled(128 * 1024, 0x41));
    final options = Lz4FrameOptions(
      compression: Lz4FrameCompression.hc,
      blockSize: Lz4FrameBlockSize.k64KB,
    );

    final encodedChunks = await Stream<List<int>>.fromIterable(
      _chunk(src, [1, 7, 3, 13, 5, 8]),
    ).transform(lz4FrameEncoderWithOptions(options: options)).toList();

    final decoded = lz4FrameDecode(_concat(encodedChunks));
    expect(decoded, src);
  });

  test('lz4FrameEncoderWithOptions rejects dependent-block encoding', () {
    expect(
      () => lz4FrameEncoderWithOptions(
        options: Lz4FrameOptions(blockIndependence: false),
      ),
      throwsA(isA<Lz4UnsupportedFeatureException>()),
    );
  });

  test('lz4FrameEncoderWithOptions rejects stream longer than contentSize',
      () async {
    final src = Uint8List.fromList('Hello'.codeUnits);
    final options = Lz4FrameOptions(contentSize: src.length - 1);

    final future = Stream<List<int>>.fromIterable(
      _chunk(src, [1, 1, 1, 1, 1]),
    ).transform(lz4FrameEncoderWithOptions(options: options)).toList();

    await expectLater(future, throwsA(isA<Lz4FormatException>()));
  });

  test('lz4FrameEncoderWithOptions rejects stream shorter than contentSize',
      () async {
    final src = Uint8List.fromList('Hello'.codeUnits);
    final options = Lz4FrameOptions(contentSize: src.length + 1);

    final future = Stream<List<int>>.fromIterable(
      _chunk(src, [2, 3]),
    ).transform(lz4FrameEncoderWithOptions(options: options)).toList();

    await expectLater(future, throwsA(isA<Lz4FormatException>()));
  });
}
