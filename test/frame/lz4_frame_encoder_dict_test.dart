import 'dart:async';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

void main() {
  group('LZ4 Encoder Dictionary Support', () {
    // Dictionary: "abcdef..."
    final dictionary = Uint8List.fromList(
        List.generate(64, (i) => 'a'.codeUnitAt(0) + (i % 26)));
    const dictId = 0x12345678;

    // Input data references the dictionary
    // We'll construct input that matches the beginning of the dictionary
    // to force a match if the dictionary is properly used.
    final input = Uint8List.fromList(dictionary.sublist(0, 32));

    test('sync encode with independent blocks and dictionary', () {
      final encoded = lz4FrameEncodeWithOptions(
        input,
        options: Lz4FrameOptions(
          blockIndependence: true,
          dictId: dictId,
        ),
        dictionary: dictionary,
      );

      final info = lz4FrameInfo(encoded);
      expect(info.dictId, dictId, reason: 'Header should contain dictId');

      // Decode with dictionary
      final decoded = lz4FrameDecode(
        encoded,
        dictionaryResolver: (id) => id == dictId ? dictionary : null,
      );
      expect(decoded, input);

      // Verify compression ratio (should be good if dict used)
      // Header ~7-11 bytes, Block overhead ~4-8 bytes.
      // 32 bytes of input matching dictionary should compress to very few bytes (sequence).
      // If dict NOT used, 32 literals => 33 bytes block.
      // If dict USED, sequence (0 literals, match 32) => ~3-4 bytes block.
      // Let's check block size.
      // Header: Magic(4) + FLG(1) + BD(1) + DictID(4) + HC(1) = 11 bytes
      // EndMark: 4 bytes
      // Total overhead: 15 bytes.
      // If compressed: 15 + ~4 = 19 bytes.
      // If uncompressed: 15 + 32 + ~4 = 51 bytes.
      expect(encoded.length, lessThan(30),
          reason: 'Should be compressed using dictionary');
    });

    test('sync encode with dependent blocks and dictionary', () {
      final encoded = lz4FrameEncodeWithOptions(
        input,
        options: Lz4FrameOptions(
          blockIndependence: false,
          dictId: dictId,
        ),
        dictionary: dictionary,
      );

      final info = lz4FrameInfo(encoded);
      expect(info.dictId, dictId);

      final decoded = lz4FrameDecode(
        encoded,
        dictionaryResolver: (id) => id == dictId ? dictionary : null,
      );
      expect(decoded, input);
      expect(encoded.length, lessThan(30));
    });

    test('streaming encode with independent blocks and dictionary', () async {
      final stream = Stream<List<int>>.fromIterable([input]);
      final transformer = lz4FrameEncoderWithOptions(
        options: Lz4FrameOptions(
          blockIndependence: true,
          dictId: dictId,
        ),
        dictionary: dictionary,
      );

      final encodedChunks = await stream.transform(transformer).toList();
      final encoded =
          Uint8List.fromList(encodedChunks.expand((x) => x).toList());

      final info = lz4FrameInfo(encoded);
      expect(info.dictId, dictId);

      final decoded = lz4FrameDecode(
        encoded,
        dictionaryResolver: (id) => id == dictId ? dictionary : null,
      );
      expect(decoded, input);
      expect(encoded.length, lessThan(30));
    });

    test('streaming encode with dependent blocks and dictionary', () async {
      final stream = Stream<List<int>>.fromIterable([input]);
      final transformer = lz4FrameEncoderWithOptions(
        options: Lz4FrameOptions(
          blockIndependence: false,
          dictId: dictId,
        ),
        dictionary: dictionary,
      );

      final encodedChunks = await stream.transform(transformer).toList();
      final encoded =
          Uint8List.fromList(encodedChunks.expand((x) => x).toList());

      final info = lz4FrameInfo(encoded);
      expect(info.dictId, dictId);

      final decoded = lz4FrameDecode(
        encoded,
        dictionaryResolver: (id) => id == dictId ? dictionary : null,
      );
      expect(decoded, input);
      expect(encoded.length, lessThan(30));
    });
  });
}
