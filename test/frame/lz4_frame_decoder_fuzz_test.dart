import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

Uint8List _randomBytes(Random r, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < out.length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

class _Outcome {
  final Uint8List? bytes;
  final String? errorType;
  final String? errorText;

  const _Outcome.ok(this.bytes)
      : errorType = null,
        errorText = null;

  const _Outcome.err(this.errorType, this.errorText) : bytes = null;
}

_Outcome _decodeOutcome({
  required Uint8List input,
  required int maxOutputBytes,
}) {
  try {
    final out = lz4FrameDecode(input, maxOutputBytes: maxOutputBytes);
    expect(out.length, lessThanOrEqualTo(maxOutputBytes));
    return _Outcome.ok(out);
  } on Error catch (e, st) {
    fail('Unexpected Error thrown: $e\n$st');
  } on Object catch (e) {
    return _Outcome.err(e.runtimeType.toString(), e.toString());
  }
}

void _expectDeterministicDecode({
  required Uint8List input,
  required int maxOutputBytes,
}) {
  final a = _decodeOutcome(input: input, maxOutputBytes: maxOutputBytes);
  final b = _decodeOutcome(input: input, maxOutputBytes: maxOutputBytes);

  if (a.bytes != null) {
    expect(b.bytes, isNotNull);
    expect(b.bytes, orderedEquals(a.bytes!));
    return;
  }

  expect(b.bytes, isNull);
  expect(b.errorType, a.errorType);
  expect(b.errorText, a.errorText);
}

void main() {
  test(
      'fuzz: lz4FrameDecode never throws Dart Error and respects maxOutputBytes',
      () {
    final r = Random(0);

    for (var i = 0; i < 200; i++) {
      final len = r.nextInt(2048);
      final bytes = _randomBytes(r, len);
      _expectDeterministicDecode(input: bytes, maxOutputBytes: 1024);
    }
  });

  test('fuzz: bitflips of valid frames never throw Dart Error', () {
    final r = Random(1);

    final payload = _randomBytes(r, 16 * 1024 + 7);
    final baseFrame = lz4FrameEncodeWithOptions(
      payload,
      options: Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k64KB,
        blockIndependence: false,
        contentChecksum: true,
      ),
    );

    for (var i = 0; i < 200; i++) {
      final mutated = Uint8List.fromList(baseFrame);
      final flips = 1 + r.nextInt(8);
      for (var j = 0; j < flips; j++) {
        final idx = r.nextInt(mutated.length);
        mutated[idx] ^= 1 << r.nextInt(8);
      }
      _expectDeterministicDecode(input: mutated, maxOutputBytes: 32 * 1024);
    }
  });

  test(
      'fuzz: valid frame exceeding maxOutputBytes throws output limit exception',
      () {
    final r = Random(2);
    final payload = _randomBytes(r, 4096);
    final frame = lz4FrameEncode(payload);
    expect(
      () => lz4FrameDecode(frame, maxOutputBytes: 1024),
      throwsA(isA<Lz4OutputLimitException>()),
    );
  });
}
