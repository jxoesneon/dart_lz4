import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

void main() {
  group('lz4DecompressInto - basic decompression', () {
    test('empty input into empty or non-empty buffer', () {
      final original = Uint8List(0);
      final compressed = lz4Compress(original);

      // Into empty buffer
      final dstEmpty = Uint8List(0);
      final written0 = lz4DecompressInto(compressed, dstEmpty);
      expect(written0, equals(0));

      // Into non-empty buffer
      final dstNonEmpty = Uint8List(16)..fillRange(0, 16, 0xAA);
      final written1 = lz4DecompressInto(compressed, dstNonEmpty);
      expect(written1, equals(0));
      // Buffer must remain unchanged
      expect(dstNonEmpty.every((b) => b == 0xAA), isTrue);
    });

    test('small ASCII string', () {
      final original =
          Uint8List.fromList(utf8.encode('Hello, Dart LZ4 zero-copy!'));
      final compressed = lz4Compress(original);

      final dst = Uint8List(original.length);
      final written = lz4DecompressInto(compressed, dst);

      expect(written, equals(original.length));
      expect(dst, equals(original));
    });

    test('single byte payload', () {
      final original = Uint8List.fromList([42]);
      final compressed = lz4Compress(original);

      final dst = Uint8List(1);
      final written = lz4DecompressInto(compressed, dst);

      expect(written, equals(1));
      expect(dst[0], equals(42));
    });

    test('repeating pattern (10 KB)', () {
      final pattern = utf8.encode('RepeatedDataBlock12345!');
      final original = Uint8List(10 * 1024);
      for (var i = 0; i < original.length; i++) {
        original[i] = pattern[i % pattern.length];
      }

      final compressed = lz4Compress(original);
      final dst = Uint8List(original.length);
      final written = lz4DecompressInto(compressed, dst);

      expect(written, equals(original.length));
      expect(dst, equals(original));
    });

    test('large payload crossing 64KB LZ4 window (128 KB)', () {
      final original = Uint8List(128 * 1024);
      final random = Random(12345);
      // Mix of random chunks and repeating runs to exercise matches across >64KB
      for (var i = 0; i < original.length; i++) {
        if (i < 32 * 1024) {
          original[i] = random.nextInt(256);
        } else if (i < 64 * 1024) {
          original[i] = original[i - 32 * 1024]; // 32KB offset match
        } else if (i < 96 * 1024) {
          original[i] = (i & 0xFF);
        } else {
          original[i] = original[i - 65536]; // >64KB offset match
        }
      }

      final compressed = lz4Compress(original);
      final dst = Uint8List(original.length);
      final written = lz4DecompressInto(compressed, dst);

      expect(written, equals(original.length));
      expect(dst, equals(original));
    });

    test('binary payload with all byte values 0..255', () {
      final original = Uint8List(256 * 16);
      for (var i = 0; i < original.length; i++) {
        original[i] = i % 256;
      }

      final compressed = lz4Compress(original);
      final dst = Uint8List(original.length);
      final written = lz4DecompressInto(compressed, dst);

      expect(written, equals(original.length));
      expect(dst, equals(original));
    });

    test('HC-compressed block decompressInto', () {
      final original = Uint8List.fromList(
        List.generate(2000, (i) => (i * 7 + 13) % 256),
      );
      final compressed = lz4Compress(original, level: Lz4CompressionLevel.hc);

      final dst = Uint8List(original.length);
      final written = lz4DecompressInto(compressed, dst);

      expect(written, equals(original.length));
      expect(dst, equals(original));
    });
  });

  group('lz4DecompressInto - non-zero dstOffset & canary verification', () {
    test('write into middle of larger buffer preserves pre and post canaries',
        () {
      final original = Uint8List.fromList(
          utf8.encode('Protected Payload Within Large Buffer'));
      final compressed = lz4Compress(original);

      const prefixLen = 64;
      const suffixLen = 128;
      final totalLen = prefixLen + original.length + suffixLen;
      final dst = Uint8List(totalLen);

      // Fill with canaries
      dst.fillRange(0, prefixLen, 0xAA);
      dst.fillRange(prefixLen, prefixLen + original.length, 0x00);
      dst.fillRange(prefixLen + original.length, totalLen, 0xBB);

      final written = lz4DecompressInto(
        compressed,
        dst,
        dstOffset: prefixLen,
      );

      expect(written, equals(original.length));

      // 1. Check decompressed content
      final decompressedView = dst.sublist(prefixLen, prefixLen + written);
      expect(decompressedView, equals(original));

      // 2. Check prefix canaries untouched
      for (var i = 0; i < prefixLen; i++) {
        expect(dst[i], equals(0xAA),
            reason: 'Prefix canary at $i was overwritten');
      }

      // 3. Check suffix canaries untouched
      for (var i = prefixLen + written; i < totalLen; i++) {
        expect(dst[i], equals(0xBB),
            reason: 'Suffix canary at $i was overwritten');
      }
    });

    test('write at exact end boundary', () {
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = lz4Compress(original);

      final dst = Uint8List(15);
      dst.fillRange(0, 10, 0xEE);

      final written = lz4DecompressInto(compressed, dst, dstOffset: 10);
      expect(written, equals(5));
      expect(dst.sublist(10, 15), equals(original));
      expect(dst.sublist(0, 10).every((b) => b == 0xEE), isTrue);
    });

    test('invalid dstOffset throws RangeError', () {
      final original = Uint8List.fromList([10, 20, 30]);
      final compressed = lz4Compress(original);
      final dst = Uint8List(10);

      // Negative dstOffset
      expect(
        () => lz4DecompressInto(compressed, dst, dstOffset: -1),
        throwsA(isA<RangeError>()),
      );

      // dstOffset strictly greater than dst.length
      expect(
        () => lz4DecompressInto(compressed, dst, dstOffset: 11),
        throwsA(isA<RangeError>()),
      );
    });

    test(
        'dstOffset == dst.length with non-empty input throws Lz4OutputLimitException',
        () {
      final original = Uint8List.fromList([10, 20, 30]);
      final compressed = lz4Compress(original);
      final dst = Uint8List(10);

      expect(
        () => lz4DecompressInto(compressed, dst, dstOffset: 10),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });

    test('dstOffset == dst.length with empty input returns 0', () {
      final original = Uint8List(0);
      final compressed = lz4Compress(original);
      final dst = Uint8List(10);

      final written = lz4DecompressInto(compressed, dst, dstOffset: 10);
      expect(written, equals(0));
    });
  });

  group(
      'lz4DecompressInto - destination buffer too small (Lz4OutputLimitException)',
      () {
    test('buffer shorter by 1 byte throws Lz4OutputLimitException', () {
      final original = Uint8List(100)..fillRange(0, 100, 0x77);
      final compressed = lz4Compress(original);

      final dst = Uint8List(99);
      expect(
        () => lz4DecompressInto(compressed, dst),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });

    test(
        'dstOffset leaves insufficient capacity throws Lz4OutputLimitException',
        () {
      final original =
          Uint8List.fromList(utf8.encode('Long enough message to overflow'));
      final compressed = lz4Compress(original);

      final dst = Uint8List(original.length + 10);
      // offset is 15, remaining space is (original.length + 10) - 15 = original.length - 5
      expect(
        () => lz4DecompressInto(compressed, dst, dstOffset: 15),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });

    test('match copy exceeding remaining buffer throws Lz4OutputLimitException',
        () {
      // Create block: 4 literals, then match length 16. Total = 20 bytes.
      final src = Uint8List.fromList([
        0x4C, // 4 literals, matchlen 12 + 4 = 16
        0x01, 0x02, 0x03, 0x04,
        0x04, 0x00, // distance 4
      ]);

      // dst buffer is only 15 bytes (can hold literals, but match overflows)
      final dst = Uint8List(15);
      expect(
        () => lz4DecompressInto(src, dst),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });

    test(
        'zero-capacity buffer with non-empty payload throws Lz4OutputLimitException',
        () {
      final original = Uint8List.fromList([1, 2, 3]);
      final compressed = lz4Compress(original);

      final dst = Uint8List(0);
      expect(
        () => lz4DecompressInto(compressed, dst),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });
  });

  group('lz4DecompressInto - corrupt and malformed payloads', () {
    test(
        'truncated literal stream throws Lz4FormatException or Lz4CorruptDataException',
        () {
      final src = Uint8List.fromList([
        0x50, // token: 5 literals, 0 matchlen
        0x01, 0x02, // only 2 bytes provided
      ]);
      final dst = Uint8List(10);

      expect(
        () => lz4DecompressInto(src, dst),
        throwsA(
            anyOf(isA<Lz4FormatException>(), isA<Lz4CorruptDataException>())),
      );
    });

    test(
        'missing match distance bytes throws Lz4FormatException or Lz4CorruptDataException',
        () {
      final src = Uint8List.fromList([
        0x00, // 0 literals, matchlen 4 -> requires 2-byte distance
      ]);
      final dst = Uint8List(10);

      expect(
        () => lz4DecompressInto(src, dst),
        throwsA(
            anyOf(isA<Lz4FormatException>(), isA<Lz4CorruptDataException>())),
      );
    });

    test('match distance 0 is corrupt throws Lz4CorruptDataException', () {
      final src = Uint8List.fromList([
        0x10, // 1 literal, matchlen 4
        0x42, // literal
        0x00, 0x00, // distance 0 (invalid)
      ]);
      final dst = Uint8List(10);

      expect(
        () => lz4DecompressInto(src, dst),
        throwsA(isA<Lz4CorruptDataException>()),
      );
    });

    test(
        'match distance pointing before dstOffset throws Lz4CorruptDataException',
        () {
      // Security test: Verify that match distance cannot read backward past dstOffset
      // into preexisting data in dst!
      final src = Uint8List.fromList([
        0x10, // 1 literal, matchlen 4
        0x42, // literal
        0x05,
        0x00, // distance 5: attempts to reference 5 bytes back, but only 1 byte written!
      ]);

      final dst = Uint8List(50)..fillRange(0, 50, 0xFF);
      // dstOffset is 10, so 10 bytes precede the current write
      expect(
        () => lz4DecompressInto(src, dst, dstOffset: 10),
        throwsA(isA<Lz4CorruptDataException>()),
      );
    });

    test(
        'match distance pointing past written data throws Lz4CorruptDataException',
        () {
      final src = Uint8List.fromList([
        0x20, // 2 literals
        0xAA, 0xBB,
        0x03, 0x00, // distance 3 (only 2 bytes written)
      ]);
      final dst = Uint8List(20);

      expect(
        () => lz4DecompressInto(src, dst),
        throwsA(isA<Lz4CorruptDataException>()),
      );
    });

    test(
        'excessively long extended length sequence throws Lz4FormatException or Lz4CorruptDataException',
        () {
      // Construct a sequence of 255s with no terminator
      final src = Uint8List.fromList([
        0xF0, // 15 literals + extended
        ...List<int>.filled(100, 255),
      ]);
      final dst = Uint8List(1000);

      expect(
        () => lz4DecompressInto(src, dst),
        throwsA(
            anyOf(isA<Lz4FormatException>(), isA<Lz4CorruptDataException>())),
      );
    });

    test('random fuzzed corrupt blocks do not crash or loop infinitely', () {
      final random = Random(999);
      final dst = Uint8List(512);

      for (var trial = 0; trial < 100; trial++) {
        final length = random.nextInt(64) + 1;
        final corruptBytes = Uint8List(length);
        for (var i = 0; i < length; i++) {
          corruptBytes[i] = random.nextInt(256);
        }

        try {
          lz4DecompressInto(corruptBytes, dst);
        } catch (e) {
          expect(
            e,
            anyOf(
              isA<Lz4Exception>(),
              isA<FormatException>(),
              isA<RangeError>(),
            ),
          );
        }
      }
    });
  });

  group('lz4DecompressInto - integration with Lz4BufferPool', () {
    test('works seamlessly with SimpleLz4BufferPool', () {
      final pool = SimpleLz4BufferPool(maxBuffers: 4);
      final original = Uint8List.fromList(
          utf8.encode('Zero-copy decompression into pooled buffer'));
      final compressed = lz4Compress(original);

      final buffer = pool.checkout(original.length);
      try {
        final written = lz4DecompressInto(compressed, buffer);
        expect(written, equals(original.length));
        expect(buffer.sublist(0, written), equals(original));
      } finally {
        pool.checkin(buffer);
      }
    });

    test('works seamlessly with SecureLz4BufferPool (CWE-226 sanitization)',
        () {
      final securePool = SecureLz4BufferPool(maxBuffers: 4);
      final original =
          Uint8List.fromList(utf8.encode('Secret cryptographic key material'));
      final compressed = lz4Compress(original);

      final buffer = securePool.checkout(original.length);
      try {
        final written = lz4DecompressInto(compressed, buffer);
        expect(written, equals(original.length));
        expect(buffer.sublist(0, written), equals(original));
      } finally {
        securePool.checkin(buffer);
      }

      // Check that buffer in pool was zeroed out upon checkin
      expect(buffer.every((b) => b == 0), isTrue);
    });
  });
}
