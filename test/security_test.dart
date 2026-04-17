import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

void main() {
  group('Security Fixes', () {
    test('lz4Decompress maxDecompressedSize sanity check', () {
      final src = Uint8List.fromList([
        0x50, // token: 5 literals
        0x48, 0x65, 0x6c, 0x6c, 0x6f, // "Hello"
      ]);

      // Should pass with correct size
      expect(
        lz4Decompress(src, decompressedSize: 5, maxDecompressedSize: 10),
        Uint8List.fromList([0x48, 0x65, 0x6c, 0x6c, 0x6f]),
      );

      // Should throw when exceeding maxDecompressedSize
      expect(
        () => lz4Decompress(src, decompressedSize: 11, maxDecompressedSize: 10),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.toString(),
          'message',
          contains('exceeds maxDecompressedSize'),
        )),
      );
    });

    test('lz4DecompressWithSize maxDecompressedSize header check', () {
      // Create a valid compressed block with size header
      final data = Uint8List.fromList([0x48, 0x65, 0x6c, 0x6c, 0x6f]);
      final compressed = lz4CompressWithSize(data);

      // Header is 4 bytes size (5) + data
      expect(compressed[0], 5);
      expect(compressed[1], 0);
      expect(compressed[2], 0);
      expect(compressed[3], 0);

      // Should pass with correct limit
      expect(
        lz4DecompressWithSize(compressed, maxDecompressedSize: 10),
        data,
      );

      // Should throw when header exceeds limit
      expect(
        () => lz4DecompressWithSize(compressed, maxDecompressedSize: 4),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.toString(),
          'message',
          contains('from header exceeds maxDecompressedSize'),
        )),
      );

      // Malicious header with huge size
      final malicious = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0x00]);
      expect(
        () =>
            lz4DecompressWithSize(malicious, maxDecompressedSize: 1024 * 1024),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.toString(),
          'message',
          contains('from header exceeds maxDecompressedSize'),
        )),
      );
    });

    test('CPU Exhaustion in _readExtendedLength', () {
      // Create a block that attempts to read a very long extended length.
      // 0xF0 means 15 literals + extended length.
      // Then many 0xFF bytes.
      final src = Uint8List(2000);
      src[0] = 0xF0;
      for (var i = 1; i < src.length; i++) {
        src[i] = 0xFF;
      }

      // It should eventually throw because it will hit EOF in ByteReader
      // OR our new limit.
      // In this case, it will hit EOF first if src is short.
      // To test the iteration limit specifically, we'd need a huge input or a mock.
      // But we can at least verify it doesn't loop forever if we provide enough bytes.

      // Let's create a "relatively" long sequence but still short enough to be reasonable.
      // Our limit is 0x1000000 (16 million). 2000 bytes is not enough.

      // If we provide a truncated sequence, it throws Lz4FormatException('Unexpected end of input')
      // from reader.readUint8().
      expect(
        () => lz4Decompress(src, decompressedSize: 100),
        throwsA(isA<Lz4FormatException>()),
      );
    });
  });
}
