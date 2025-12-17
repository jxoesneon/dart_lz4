import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/block/lz4_block_decoder.dart';
import 'package:dart_lz4/src/internal/byte_writer.dart';
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

_Outcome _lz4DecompressOutcome({
  required Uint8List input,
  required int decompressedSize,
}) {
  try {
    final out = lz4Decompress(input, decompressedSize: decompressedSize);
    expect(out.length, decompressedSize);
    return _Outcome.ok(out);
  } on Error catch (e, st) {
    fail('Unexpected Error thrown: $e\n$st');
  } on Object catch (e) {
    return _Outcome.err(e.runtimeType.toString(), e.toString());
  }
}

void _expectDeterministicLz4Decompress({
  required Uint8List input,
  required int decompressedSize,
}) {
  final a =
      _lz4DecompressOutcome(input: input, decompressedSize: decompressedSize);
  final b =
      _lz4DecompressOutcome(input: input, decompressedSize: decompressedSize);

  if (a.bytes != null) {
    expect(b.bytes, isNotNull);
    expect(b.bytes, orderedEquals(a.bytes!));
    return;
  }

  expect(b.bytes, isNull);
  expect(b.errorType, a.errorType);
  expect(b.errorText, a.errorText);
}

_Outcome _lz4DecompressIntoOutcome({
  required Uint8List input,
  required int maxOutputBytes,
}) {
  final writer = ByteWriter(maxLength: maxOutputBytes);

  try {
    lz4BlockDecompressInto(input, writer);
    expect(writer.length, lessThanOrEqualTo(maxOutputBytes));
    return _Outcome.ok(writer.toBytes());
  } on Error catch (e, st) {
    fail('Unexpected Error thrown: $e\n$st');
  } on Object catch (e) {
    return _Outcome.err(e.runtimeType.toString(), e.toString());
  }
}

void _expectDeterministicLz4DecompressInto({
  required Uint8List input,
  required int maxOutputBytes,
}) {
  final a =
      _lz4DecompressIntoOutcome(input: input, maxOutputBytes: maxOutputBytes);
  final b =
      _lz4DecompressIntoOutcome(input: input, maxOutputBytes: maxOutputBytes);

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
  test('fuzz: lz4Decompress is deterministic and never throws Dart Error', () {
    final r = Random(10);

    for (var i = 0; i < 200; i++) {
      final inputLen = r.nextInt(2048);
      final input = _randomBytes(r, inputLen);
      final decompressedSize = r.nextInt(4096);
      _expectDeterministicLz4Decompress(
        input: input,
        decompressedSize: decompressedSize,
      );
    }
  });

  test('fuzz: lz4BlockDecompressInto is deterministic and enforces maxLength',
      () {
    final r = Random(11);

    for (var i = 0; i < 200; i++) {
      final inputLen = r.nextInt(2048);
      final input = _randomBytes(r, inputLen);
      final maxOutputBytes = r.nextInt(4096);
      _expectDeterministicLz4DecompressInto(
        input: input,
        maxOutputBytes: maxOutputBytes,
      );
    }
  });

  test('fuzz: bitflips of valid blocks are deterministic and never throw Error',
      () {
    final r = Random(12);

    final payload = _randomBytes(r, 16 * 1024 + 3);
    final baseBlock = lz4Compress(payload);

    for (var i = 0; i < 200; i++) {
      final mutated = Uint8List.fromList(baseBlock);
      final flips = 1 + r.nextInt(8);
      for (var j = 0; j < flips; j++) {
        final idx = r.nextInt(mutated.length);
        mutated[idx] ^= 1 << r.nextInt(8);
      }

      _expectDeterministicLz4Decompress(
        input: mutated,
        decompressedSize: payload.length,
      );
      _expectDeterministicLz4DecompressInto(
        input: mutated,
        maxOutputBytes: 64 * 1024,
      );
    }
  });

  test('lz4BlockDecompressInto round-trips a valid block', () {
    final r = Random(13);
    final payload = _randomBytes(r, 8192);
    final block = lz4Compress(payload);

    final writer = ByteWriter(
      initialCapacity: payload.length,
      maxLength: payload.length,
    );
    lz4BlockDecompressInto(block, writer);
    expect(writer.toBytes(), orderedEquals(payload));
  });

  test(
      'lz4BlockDecompressInto throws output limit exception when maxLength is too small',
      () {
    final r = Random(14);
    final payload = _randomBytes(r, 4096);
    final block = lz4Compress(payload);

    final writer = ByteWriter(maxLength: payload.length - 1);
    expect(
      () => lz4BlockDecompressInto(block, writer),
      throwsA(isA<Lz4OutputLimitException>()),
    );
  });

  test(
      'lz4Decompress throws corrupt exception when decompressedSize is too small',
      () {
    final r = Random(15);
    final payload = _randomBytes(r, 4096);
    final block = lz4Compress(payload);

    expect(
      () => lz4Decompress(block, decompressedSize: payload.length - 1),
      throwsA(isA<Lz4CorruptDataException>()),
    );
  });
}
