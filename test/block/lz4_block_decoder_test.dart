import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/block/lz4_block_decoder.dart';
import 'package:test/test.dart';

void main() {
  test('literal-only block decodes', () {
    final src = Uint8List.fromList([
      0x50, // token: 5 literals, 0 matchlen
      0x48, 0x65, 0x6c, 0x6c, 0x6f, // "Hello"
    ]);

    final out = lz4Decompress(src, decompressedSize: 5);
    expect(out, Uint8List.fromList([0x48, 0x65, 0x6c, 0x6c, 0x6f]));
  });

  test('extended literal length decodes', () {
    final literals = List<int>.generate(20, (i) => i);
    final src = Uint8List.fromList([
      0xF0, // token: 15 literals, 0 matchlen
      0x05, // +5 => 20
      ...literals,
    ]);

    final out = lz4Decompress(src, decompressedSize: 20);
    expect(out, Uint8List.fromList(literals));
  });

  test('match copy decodes', () {
    final src = Uint8List.fromList([
      0x40, // token: 4 literals, matchlen base 0 => 4
      0x61, 0x62, 0x63, 0x64, // "abcd"
      0x04, 0x00, // distance 4
    ]);

    final out = lz4Decompress(src, decompressedSize: 8);
    expect(
      out,
      Uint8List.fromList([
        0x61, 0x62, 0x63, 0x64, // abcd
        0x61, 0x62, 0x63, 0x64, // abcd
      ]),
    );
  });

  test('overlapping match copy decodes (distance=1)', () {
    final src = Uint8List.fromList([
      0x13, // token: 1 literal, matchlen base 3 => 7
      0x41, // 'A'
      0x01, 0x00, // distance 1
    ]);

    final out = lz4Decompress(src, decompressedSize: 8);
    expect(out, Uint8List.fromList(List<int>.filled(8, 0x41)));
  });

  test('truncated input throws', () {
    final src = Uint8List.fromList([
      0x00, // token: 0 literals, matchlen base 0 => needs distance
    ]);

    expect(
      () => lz4Decompress(src, decompressedSize: 4),
      throwsA(isA<Lz4FormatException>()),
    );
  });

  test('invalid match distance throws', () {
    final src = Uint8List.fromList([
      0x00, // token: 0 literals, matchlen base 0 => 4
      0x00, 0x00, // distance 0 (invalid)
    ]);

    expect(
      () => lz4Decompress(src, decompressedSize: 4),
      throwsA(isA<Lz4CorruptDataException>()),
    );
  });

  test('match length exceeding output throws', () {
    final src = Uint8List.fromList([
      0x40, // 4 literals, matchlen 4
      0x01, 0x02, 0x03, 0x04,
      0x04, 0x00, // distance 4
    ]);

    expect(
      () => lz4Decompress(src, decompressedSize: 5),
      throwsA(isA<Lz4CorruptDataException>()),
    );
  });

  test('trailing bytes throw', () {
    final src = Uint8List.fromList([
      0x10, // 1 literal
      0xAA,
      0xBB, // trailing
    ]);

    expect(
      () => lz4Decompress(src, decompressedSize: 1),
      throwsA(isA<Lz4CorruptDataException>()),
    );
  });

  group('lz4BlockDecompressIntoBuffer', () {
    test('decompresses valid block into buffer at offset 0', () {
      final input = Uint8List.fromList([1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4]);
      final compressed = lz4Compress(input);
      final dst = Uint8List(input.length);

      final written = lz4BlockDecompressIntoBuffer(compressed, dst);
      expect(written, input.length);
      expect(dst, equals(input));
    });

    test('decompresses valid block with dstOffset > 0', () {
      final input = Uint8List.fromList([10, 20, 30, 40, 50, 60]);
      final compressed = lz4Compress(input);
      final dst = Uint8List(20);
      dst[0] = 0xff;
      dst[1] = 0xee;

      final written =
          lz4BlockDecompressIntoBuffer(compressed, dst, dstOffset: 2);
      expect(written, input.length);
      expect(dst[0], 0xff);
      expect(dst[1], 0xee);
      expect(dst.sublist(2, 2 + input.length), equals(input));
    });

    test('validates dstOffset range', () {
      final dst = Uint8List(10);
      final src = Uint8List(0);
      expect(() => lz4BlockDecompressIntoBuffer(src, dst, dstOffset: -1),
          throwsRangeError);
      expect(() => lz4BlockDecompressIntoBuffer(src, dst, dstOffset: 11),
          throwsRangeError);
      // dstOffset == dst.length with empty input is valid
      final written = lz4BlockDecompressIntoBuffer(src, dst, dstOffset: 10);
      expect(written, 0);
    });

    test('throws Lz4OutputLimitException when destination buffer is too small',
        () {
      final input = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final compressed = lz4Compress(input);
      final dst = Uint8List(4); // smaller than input

      expect(
        () => lz4BlockDecompressIntoBuffer(compressed, dst),
        throwsA(
          isA<Lz4OutputLimitException>().having(
            (e) => e.message,
            'message',
            contains('Destination buffer too small'),
          ),
        ),
      );
    });

    test(
        'throws Lz4OutputLimitException when dstOffset leaves insufficient space',
        () {
      final input = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final compressed = lz4Compress(input);
      final dst = Uint8List(10); // length 10, but offset 5 leaves only 5 bytes

      expect(
        () => lz4BlockDecompressIntoBuffer(compressed, dst, dstOffset: 5),
        throwsA(
          isA<Lz4OutputLimitException>().having(
            (e) => e.message,
            'message',
            contains('Destination buffer too small'),
          ),
        ),
      );
    });

    test('prevents match references prior to dstOffset', () {
      // Create a corrupted block: 4 literals, then match distance 6
      // When dstOffset=5, destStart is 9, distance 6 refers to index 3 (which is < dstOffset 5)
      final corruptSrc = Uint8List.fromList([
        0x40, // 4 literals, 0 base matchlen (= 4)
        0x01, 0x02, 0x03, 0x04,
        0x06, 0x00, // distance 6
      ]);

      final dst = Uint8List(20);
      // Pre-fill memory before dstOffset to ensure it is not read
      dst.setRange(0, 5, [0xaa, 0xbb, 0xcc, 0xdd, 0xee]);

      expect(
        () => lz4BlockDecompressIntoBuffer(corruptSrc, dst, dstOffset: 5),
        throwsA(isA<Lz4CorruptDataException>()),
      );
    });

    test(
        'throws Lz4FormatException on truncated input with incomplete distance',
        () {
      final truncated = Uint8List.fromList([
        0x10, // 1 literal, matchlen 0
        0x41, // 1 literal 'A'
        0x01, // Only 1 byte of distance, requires 2 bytes
      ]);
      final dst = Uint8List(10);
      expect(
        () => lz4BlockDecompressIntoBuffer(truncated, dst),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('throws Lz4FormatException on truncated literal bytes', () {
      final truncated = Uint8List.fromList([
        0x50, // 5 literals, but 0 literal bytes provided
      ]);
      final dst = Uint8List(10);
      expect(
        () => lz4BlockDecompressIntoBuffer(truncated, dst),
        throwsA(isA<Lz4FormatException>()),
      );
    });
  });
}
