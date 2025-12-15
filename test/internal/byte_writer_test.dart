import 'dart:typed_data';

import 'package:dart_lz4/src/internal/byte_writer.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

void main() {
  test('writeUint8/writeUint16LE/writeUint32LE', () {
    final w = ByteWriter();
    w.writeUint8(0x12);
    w.writeUint16LE(0x3456);
    w.writeUint32LE(0x0a0b0c0d);

    expect(w.toBytes(), [
      0x12,
      0x56,
      0x34,
      0x0d,
      0x0c,
      0x0b,
      0x0a,
    ]);
  });

  test('writeBytes and writeBytesView', () {
    final w = ByteWriter();
    w.writeBytes(Uint8List.fromList([1, 2, 3]));
    w.writeBytesView(Uint8List.fromList([9, 8, 7, 6]), 1, 3);

    expect(w.toBytes(), [1, 2, 3, 8, 7]);
  });

  test('writeRepeatedByte', () {
    final w = ByteWriter();
    w.writeRepeatedByte(0xaa, 4);
    expect(w.toBytes(), [0xaa, 0xaa, 0xaa, 0xaa]);
  });

  test('copyMatch distance 1 repeats last byte', () {
    final w = ByteWriter();
    w.writeBytes(Uint8List.fromList([0x41]));
    w.copyMatch(1, 4);

    expect(w.toBytes(), [0x41, 0x41, 0x41, 0x41, 0x41]);
  });

  test('copyMatch overlap is handled correctly', () {
    final w = ByteWriter();
    w.writeBytes(Uint8List.fromList([1, 2, 3, 4]));
    w.copyMatch(4, 8);

    expect(w.toBytes(), [
      1,
      2,
      3,
      4,
      1,
      2,
      3,
      4,
      1,
      2,
      3,
      4,
    ]);
  });

  test('copyMatch validates distance', () {
    final w = ByteWriter();
    w.writeBytes(Uint8List.fromList([1, 2, 3]));
    expect(() => w.copyMatch(0, 1), throwsA(isA<Lz4CorruptDataException>()));
    expect(() => w.copyMatch(4, 1), throwsA(isA<Lz4CorruptDataException>()));
  });

  test('maxLength enforces output limit', () {
    final w = ByteWriter(maxLength: 3);
    w.writeBytes(Uint8List.fromList([1, 2, 3]));
    expect(() => w.writeUint8(4), throwsA(isA<Lz4OutputLimitException>()));
  });
}
