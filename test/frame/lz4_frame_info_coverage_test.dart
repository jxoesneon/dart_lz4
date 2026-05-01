import 'dart:typed_data';
import 'package:dart_lz4/src/frame/lz4_frame_info.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

void main() {
  test('lz4FrameInfo throws on truncated input', () {
    expect(() => lz4FrameInfo(Uint8List.fromList([0x04, 0x22, 0x4D])), throwsA(isA<Lz4FormatException>()));
  });

  test('lz4FrameInfo throws on invalid magic', () {
    expect(() => lz4FrameInfo(Uint8List.fromList([0x00, 0x00, 0x00, 0x00])), throwsA(isA<Lz4FormatException>()));
  });

  test('lz4FrameInfo throws on truncated skippable frame', () {
    // Magic 0x184D2A50
    expect(() => lz4FrameInfo(Uint8List.fromList([0x50, 0x2A, 0x4D, 0x18, 0x00])), throwsA(isA<Lz4FormatException>()));
  });

  test('lz4FrameInfo throws on truncated standard frame descriptor', () {
    // Magic 0x184D2204
    expect(() => lz4FrameInfo(Uint8List.fromList([0x04, 0x22, 0x4D, 0x18])), throwsA(isA<Lz4FormatException>()));
  });
}
