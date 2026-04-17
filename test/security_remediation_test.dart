import 'dart:async';
import 'dart:typed_data';
import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

List<int> _u32le(int v) =>
    <int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  group('Security: Unbounded Legacy Block Buffering', () {
    test('rejects legacy frame with excessively large block size (> 8MB)',
        () async {
      const magic = 0x184C2102;
      const hugeBlockSize = 8 * 1024 * 1024 + 1; // 8MB + 1 byte

      final frame = Uint8List.fromList([
        ..._u32le(magic),
        ..._u32le(hugeBlockSize),
        0x01,
        0x02,
        0x03,
        0x04,
      ]);

      final stream = Stream<List<int>>.fromIterable([frame]);

      expect(
        () => stream.transform(lz4FrameDecoder()).drain<void>(),
        throwsA(isA<Lz4CorruptDataException>().having((e) => e.message,
            'message', contains('Legacy block size exceeds maximum'))),
      );
    });

    test('accepts legacy frame with valid block size (<= 8MB)', () async {
      const magic = 0x184C2102;
      final data = Uint8List(1024);
      final compressed = lz4Compress(data);

      final frame = Uint8List.fromList([
        ..._u32le(magic),
        ..._u32le(compressed.length),
        ...compressed,
      ]);

      final stream = Stream<List<int>>.fromIterable([frame]);
      final out = await stream.transform(lz4FrameDecoder()).fold<List<int>>(
          [], (previous, element) => previous..addAll(element));

      expect(out, data);
    });
  });

  group('Security: Unbounded Output Buffering', () {
    test(
        'enforces default output limit of 256MB when maxOutputBytes is omitted',
        () {
      // Create a frame that expands to more than 256MB
      // 257MB of zeros. LZ4 will compress this very well.
      final size = 257 * 1024 * 1024;
      final data = Uint8List(size);
      final frame = lz4FrameEncode(data);

      expect(
        () => lz4FrameDecode(frame),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });

    test('allows overriding default output limit', () {
      // 10MB of zeros, should pass with default (256MB)
      final size = 10 * 1024 * 1024;
      final data = Uint8List(size);
      final frame = lz4FrameEncode(data);

      expect(lz4FrameDecode(frame).length, size);

      // Should fail if we set a smaller limit
      expect(
        () => lz4FrameDecode(frame, maxOutputBytes: 1 * 1024 * 1024),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });
  });

  group('Blue Team Remediation Tests', () {
    test('Match Distance Performance: No infinite loop or excessive search',
        () {
      // Large incompressible-ish data to test the 'break' vs 'continue' fix
      final data = Uint8List.fromList(
          List.generate(1024 * 1024, (i) => i % 251)); // sparse matches
      final stopwatch = Stopwatch()..start();
      lz4Compress(data, level: Lz4CompressionLevel.hc);
      stopwatch.stop();
      print('Compression took ${stopwatch.elapsedMilliseconds}ms');
      expect(stopwatch.elapsedMilliseconds, lessThan(2000),
          reason: 'Compression should be fast with distance breaking');
    });

    test('Circular Chain Poisoning Prevention', () {
      // Specific pattern that used to trigger self-references
      final data = Uint8List.fromList([1, 2, 3, 1, 2, 3, 1, 2, 3, 4, 5, 6]);
      expect(() => lz4Compress(data, level: Lz4CompressionLevel.hc),
          returnsNormally);
    });
  });
}
