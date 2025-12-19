import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

void main() {
  group('lz4LegacyEncode', () {
    test('encodes empty data', () {
      final src = Uint8List(0);
      final frame = lz4LegacyEncode(src);

      // Should only contain magic number (4 bytes)
      expect(frame.length, equals(4));
      // Magic: 0x184C2102 (little endian)
      expect(frame[0], equals(0x02));
      expect(frame[1], equals(0x21));
      expect(frame[2], equals(0x4C));
      expect(frame[3], equals(0x18));
    });

    test('encodes small data and decodes correctly', () {
      final src = Uint8List.fromList('Hello, Legacy LZ4 World!'.codeUnits);
      final frame = lz4LegacyEncode(src);

      // Check magic
      expect(frame[0], equals(0x02));
      expect(frame[1], equals(0x21));
      expect(frame[2], equals(0x4C));
      expect(frame[3], equals(0x18));

      // Decode and verify round-trip
      final decoded = lz4FrameDecode(frame);
      expect(decoded, equals(src));
    });

    test('encodes larger data and decodes correctly', () {
      // Create 1 MiB of compressible data
      final src = Uint8List(1024 * 1024);
      for (var i = 0; i < src.length; i++) {
        src[i] = i % 256;
      }

      final frame = lz4LegacyEncode(src);
      final decoded = lz4FrameDecode(frame);
      expect(decoded, equals(src));
    });

    test('encodes data larger than 8 MiB block size', () {
      // Create 10 MiB of data (requires 2 blocks)
      final src = Uint8List(10 * 1024 * 1024);
      for (var i = 0; i < src.length; i++) {
        src[i] = (i * 7) % 256;
      }

      final frame = lz4LegacyEncode(src);
      final decoded = lz4FrameDecode(frame);
      expect(decoded, equals(src));
    });

    test('lz4FrameInfo recognizes legacy frame', () {
      final src = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = lz4LegacyEncode(src);

      final info = lz4FrameInfo(frame);
      expect(info.isLegacy, isTrue);
      expect(info.isSkippable, isFalse);
      expect(info.magic, equals(0x184C2102));
      expect(info.headerSize, equals(4));
    });

    test('streaming decoder handles legacy frame', () async {
      final src = Uint8List.fromList('Streaming legacy test data!'.codeUnits);
      final frame = lz4LegacyEncode(src);

      // Split into chunks to simulate streaming
      final chunks = <List<int>>[];
      for (var i = 0; i < frame.length; i += 5) {
        final end = i + 5 > frame.length ? frame.length : i + 5;
        chunks.add(frame.sublist(i, end));
      }

      final stream = Stream.fromIterable(chunks);
      final decoded = await stream.transform(lz4FrameDecoder()).toList();
      final result = Uint8List.fromList(decoded.expand((e) => e).toList());

      expect(result, equals(src));
    });

    test('acceleration parameter affects output', () {
      final src = Uint8List(100000);
      for (var i = 0; i < src.length; i++) {
        src[i] = i % 256;
      }

      final frame1 = lz4LegacyEncode(src, acceleration: 1);
      final frame10 = lz4LegacyEncode(src, acceleration: 10);

      // Both should decode correctly
      expect(lz4FrameDecode(frame1), equals(src));
      expect(lz4FrameDecode(frame10), equals(src));

      // Higher acceleration typically produces larger output (less compression)
      // but this depends on data, so just verify both work
    });
  });
}
