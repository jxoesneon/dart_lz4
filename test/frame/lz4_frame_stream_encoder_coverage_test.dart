import 'dart:typed_data';
import 'package:dart_lz4/src/frame/lz4_frame_stream_encoder.dart';
import 'package:dart_lz4/src/frame/lz4_frame_options.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

void main() {
  test('lz4FrameEncoderTransformer throws on contentSize mismatch (too short)', () async {
    final options = Lz4FrameOptions(contentSize: 100);
    final transformer = lz4FrameEncoderTransformerWithOptions(options: options);
    final input = Stream<List<int>>.value(Uint8List.fromList([1, 2, 3]));
    
    expect(input.transform(transformer).toList(), throwsA(isA<Lz4FormatException>()));
  });

  test('lz4FrameEncoderTransformer throws on contentSize mismatch (too long)', () async {
    final options = Lz4FrameOptions(contentSize: 2);
    final transformer = lz4FrameEncoderTransformerWithOptions(options: options);
    final input = Stream<List<int>>.value(Uint8List.fromList([1, 2, 3]));
    
    expect(input.transform(transformer).toList(), throwsA(isA<Lz4FormatException>()));
  });
}
