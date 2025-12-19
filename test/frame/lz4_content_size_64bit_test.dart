import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

void main() {
  group('LZ4 Frame Encoder 64-bit Content Size', () {
    test('encodes header with > 4GiB content size correctly', () async {
      // 5 GiB = 5 * 1024 * 1024 * 1024 = 5368709120
      // 5368709120 in hex is 0x140000000
      // Low 32 bits: 0x40000000
      // High 32 bits: 0x00000001
      const hugeSize = 5368709120;

      final stream = Stream<List<int>>.fromIterable([Uint8List(0)]);
      final transformer = lz4FrameEncoderWithOptions(
        options: Lz4FrameOptions(
          contentSize: hugeSize,
          contentChecksum: false,
        ),
      );

      final queue = StreamQueue(stream.transform(transformer));

      // The first chunk should be the header
      final header = await queue.next;

      // Parse header using lz4FrameInfo to verify
      final info = lz4FrameInfo(Uint8List.fromList(header));
      expect(info.contentSize, hugeSize);

      // We don't care about the rest, and if we continue it will fail
      // because we provided 0 bytes of input vs 5GB expected.
      // But we successfully verified the header was written with 64-bit size.
    });
  });
}
