import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';

void main() async {
  final originalString = 'The quick brown fox jumps over the lazy dog. ' * 2000;
  final originalData = Uint8List.fromList(utf8.encode(originalString));

  print('Original size: ${originalData.length} bytes');

  final encoder = lz4FrameEncoderWithOptions(
    options: Lz4FrameOptions(
      blockSize: Lz4FrameBlockSize.k64KB,
      blockIndependence: false,
      contentChecksum: true,
    ),
  );

  final rawStream = Stream.value(originalData);

  final networkStream = rawStream
      .transform(encoder.cast<Uint8List, Uint8List>())
      .expand<Uint8List>((chunk) sync* {
    var offset = 0;
    final fragments = [7, 13, 42, 100, 3, 999];
    var i = 0;
    while (offset < chunk.length) {
      final size = fragments[i % fragments.length];
      final end = (offset + size < chunk.length) ? offset + size : chunk.length;
      yield chunk.sublist(offset, end);
      offset = end;
      i++;
    }
  });

  final decoder = lz4FrameDecoder(
    maxOutputBytes: 10 * 1024 * 1024,
  ).cast<Uint8List, Uint8List>();

  print('Starting streaming decompression of fragmented network data...');
  final builder = BytesBuilder(copy: false);
  final stopwatch = Stopwatch()..start();

  try {
    await for (final chunk in networkStream.transform<Uint8List>(decoder)) {
      builder.add(chunk);
    }
    stopwatch.stop();

    final decodedBytes = builder.takeBytes();
    final decodedString = utf8.decode(decodedBytes);
    final success = decodedString == originalString;

    print('Decompression finished in ${stopwatch.elapsedMilliseconds}ms');
    print('Decoded size: ${decodedBytes.length} bytes');
    print('Roundtrip match: $success');
  } on Lz4Exception catch (e) {
    print('LZ4 error: ${e.message}');
    rethrow;
  }
}
