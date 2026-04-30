import 'package:test/test.dart';
import 'package:dart_lz4/src/internal/lz4_buffer_pool.dart';

void main() {
  group('Lz4BufferPool Security', () {
    test('SecureLz4BufferPool zeroes out buffers on checkin', () {
      final pool = SecureLz4BufferPool();

      // 1. Checkout a buffer and fill it with "sensitive" data.
      final buf1 = pool.checkout(1024);
      buf1.fillRange(0, buf1.length, 0xFF);

      // 2. Check it in.
      pool.checkin(buf1);

      // 3. Checkout a buffer of the same size.
      // It should be the same underlying buffer but zeroed.
      final buf2 = pool.checkout(1024);

      expect(buf2.length, greaterThanOrEqualTo(1024));
      for (var i = 0; i < buf2.length; i++) {
        if (buf2[i] != 0) {
          fail('Buffer not zeroed at index $i');
        }
      }
    });

    test(
        'SimpleLz4BufferPool does NOT zero out buffers (verification of behavior)',
        () {
      final pool = SimpleLz4BufferPool();

      final buf1 = pool.checkout(1024);
      buf1.fillRange(0, buf1.length, 0xAA);

      pool.checkin(buf1);

      final buf2 = pool.checkout(1024);

      // We expect SimpleLz4BufferPool to return the same dirty buffer
      var foundNonZero = false;
      for (var i = 0; i < buf2.length; i++) {
        if (buf2[i] == 0xAA) {
          foundNonZero = true;
          break;
        }
      }
      expect(foundNonZero, isTrue,
          reason: 'Simple pool should not have zeroed the buffer');
    });

    test('SecureLz4BufferPool handles multiple buffers', () {
      final pool = SecureLz4BufferPool(maxBuffers: 2);

      final b1 = pool.checkout(100);
      final b2 = pool.checkout(100);

      b1.fillRange(0, b1.length, 1);
      b2.fillRange(0, b2.length, 2);

      pool.checkin(b1);
      pool.checkin(b2);

      final b3 = pool.checkout(100);
      final b4 = pool.checkout(100);

      expect(b3.every((b) => b == 0), isTrue);
      expect(b4.every((b) => b == 0), isTrue);
    });
  });
}
