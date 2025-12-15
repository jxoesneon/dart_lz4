import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
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
}
