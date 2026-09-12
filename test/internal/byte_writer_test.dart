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

  group('ByteWriter.forBuffer', () {
    test('writes directly into pre-allocated buffer', () {
      final buffer = Uint8List(10);
      final w = ByteWriter.forBuffer(buffer, offset: 2);
      expect(w.isFixed, isTrue);
      expect(w.length, 2);
      expect(w.blockStartOffset, 2);

      w.writeUint8(0xab);
      w.writeUint8(0xcd);
      expect(w.length, 4);
      expect(buffer[2], 0xab);
      expect(buffer[3], 0xcd);
    });

    test(
        'throws Lz4OutputLimitException Destination buffer too small on overflow',
        () {
      final buffer = Uint8List(4);
      final w = ByteWriter.forBuffer(buffer);

      w.writeBytes(Uint8List.fromList([1, 2, 3, 4]));
      expect(
        () => w.writeUint8(5),
        throwsA(
          isA<Lz4OutputLimitException>().having(
            (e) => e.message,
            'message',
            contains('Destination buffer too small'),
          ),
        ),
      );
      // Ensures buffer was never reallocated and directly shares storage
      expect(w.length, 4);
      buffer[0] = 0x99;
      expect(w.bytesView()[0], 0x99);
    });

    test('enforces offset bounds in constructor', () {
      final buffer = Uint8List(5);
      expect(() => ByteWriter.forBuffer(buffer, offset: -1), throwsRangeError);
      expect(() => ByteWriter.forBuffer(buffer, offset: 6), throwsRangeError);
      // offset == buffer.length is valid (empty remaining)
      final w = ByteWriter.forBuffer(buffer, offset: 5);
      expect(w.length, 5);
      expect(() => w.writeUint8(1), throwsA(isA<Lz4OutputLimitException>()));
    });

    test('copyMatch cannot read prior to blockStartOffset', () {
      final buffer = Uint8List(10);
      // Pre-fill buffer with dummy data that shouldn't be accessible
      buffer.setRange(0, 5, [0xde, 0xad, 0xbe, 0xef, 0xaa]);

      final w = ByteWriter.forBuffer(buffer, offset: 5);
      expect(w.blockStartOffset, 5);

      // Writing 2 bytes in the block
      w.writeBytes(Uint8List.fromList([1, 2]));
      expect(w.length, 7);

      // Valid match: distance 2 stays within block (reads from index 5)
      w.copyMatch(2, 2);
      expect(w.length, 9);
      expect(buffer[7], 1);
      expect(buffer[8], 2);

      // Invalid match: distance 5 from length 9 would attempt reading index 4 (before blockStartOffset 5)
      expect(() => w.copyMatch(5, 1), throwsA(isA<Lz4CorruptDataException>()));

      // Distance matching exact block length (4) is valid (reads index 5)
      w.copyMatch(4, 1);
      expect(w.length, 10);
      expect(buffer[9], 1);
    });
  });
}
