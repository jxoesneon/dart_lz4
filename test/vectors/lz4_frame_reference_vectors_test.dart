import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

const _independentFrameB64 =
    'BCJNGHxAABgBAAAAAAC+KwEAAP8RAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gAP/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////IUBscHR4fbTlAxEIAAAD/EQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIAD//////////////////////////////99QGxwdHh/6J6/rAAAAAIL1gfc=';

const _dependentFrameB64 =
    'BCJNGFxAABgBAAAAAADzKwEAAP8RAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gAP/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////IUBscHR4fbTlAxCIAAAAPIAD///////////////////////////////8AUBscHR4fb6vvZwAAAACC9YH3';

const _smallIndependentDefaultB64 =
    'BCJNGGRApy4AAAD/EQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIAD////LUBscHR4fAAAAAMVHkww=';

const _smallIndependentNoFrameCrcB64 =
    'BCJNGGBAgi4AAAD/EQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIAD////LUBscHR4fAAAAAA==';

const _smallIndependentBlockChecksumB64 =
    'BCJNGHRAvS4AAAD/EQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIAD////LUBscHR4fJtshrAAAAADFR5MM';

const _smallIndependentContentSizeB64 =
    'BCJNGGxAAAQAAAAAAABWLgAAAP8RAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gAP///8tQGxwdHh8AAAAAxUeTDA==';

const _emptyFrameB64 = 'BCJNGGRApwAAAAAFXcwC';

Uint8List _decodeB64(String s) => Uint8List.fromList(base64Decode(s));

int _readUint32LE(Uint8List bytes, int offset) {
  final b0 = bytes[offset];
  final b1 = bytes[offset + 1];
  final b2 = bytes[offset + 2];
  final b3 = bytes[offset + 3];
  return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
}

int _readUint64LEAsInt(Uint8List bytes, int offset) {
  final lo = _readUint32LE(bytes, offset);
  final hi = _readUint32LE(bytes, offset + 4);
  return (hi << 32) | lo;
}

Uint8List _expectedPayload([int size = 70 * 1024]) {
  final out = Uint8List(size);
  for (var i = 0; i < out.length; i++) {
    out[i] = i & 0x1f;
  }
  return out;
}

void _expectHeader(
  Uint8List frame, {
  required bool blockIndependence,
  required bool blockChecksum,
  required bool contentChecksum,
  required int? contentSize,
  required int blockMaxSizeId,
}) {
  const magic = 0x184D2204;
  expect(_readUint32LE(frame, 0), magic);

  final flg = frame[4];
  final bd = frame[5];

  final version = (flg >> 6) & 0x03;
  expect(version, 0x01);

  expect(((flg >> 5) & 0x01) != 0, blockIndependence);
  expect(((flg >> 4) & 0x01) != 0, blockChecksum);
  expect(((flg >> 2) & 0x01) != 0, contentChecksum);

  final hasContentSize = ((flg >> 3) & 0x01) != 0;
  expect(hasContentSize, contentSize != null);

  final bdId = (bd >> 4) & 0x07;
  expect(bdId, blockMaxSizeId);

  if (contentSize != null) {
    expect(_readUint64LEAsInt(frame, 6), contentSize);
  }
}

void main() {
  test('reference lz4 CLI independent frame decodes', () {
    final frame = _decodeB64(_independentFrameB64);
    final decoded = lz4FrameDecode(frame);

    final expected = _expectedPayload();
    expect(decoded, expected);

    _expectHeader(
      frame,
      blockIndependence: true,
      blockChecksum: true,
      contentChecksum: true,
      contentSize: expected.length,
      blockMaxSizeId: 4,
    );
  });

  test('reference lz4 CLI dependent frame decodes', () {
    final independent = _decodeB64(_independentFrameB64);
    final dependent = _decodeB64(_dependentFrameB64);

    final decoded = lz4FrameDecode(dependent);
    final expected = _expectedPayload();

    expect(decoded, expected);
    expect(dependent.length, lessThan(independent.length));

    _expectHeader(
      dependent,
      blockIndependence: false,
      blockChecksum: true,
      contentChecksum: true,
      contentSize: expected.length,
      blockMaxSizeId: 4,
    );
  });

  test('reference lz4 CLI small independent frame (default) decodes', () {
    final frame = _decodeB64(_smallIndependentDefaultB64);
    final decoded = lz4FrameDecode(frame);

    final expected = _expectedPayload(1024);
    expect(decoded, expected);

    _expectHeader(
      frame,
      blockIndependence: true,
      blockChecksum: false,
      contentChecksum: true,
      contentSize: null,
      blockMaxSizeId: 4,
    );
  });

  test('reference lz4 CLI small frame with content size decodes', () {
    final frame = _decodeB64(_smallIndependentContentSizeB64);
    final decoded = lz4FrameDecode(frame);

    final expected = _expectedPayload(1024);
    expect(decoded, expected);

    _expectHeader(
      frame,
      blockIndependence: true,
      blockChecksum: false,
      contentChecksum: true,
      contentSize: expected.length,
      blockMaxSizeId: 4,
    );
  });

  test('reference lz4 CLI small frame with no frame crc decodes', () {
    final frame = _decodeB64(_smallIndependentNoFrameCrcB64);
    final decoded = lz4FrameDecode(frame);

    final expected = _expectedPayload(1024);
    expect(decoded, expected);

    _expectHeader(
      frame,
      blockIndependence: true,
      blockChecksum: false,
      contentChecksum: false,
      contentSize: null,
      blockMaxSizeId: 4,
    );
  });

  test('reference lz4 CLI small frame with block checksum decodes', () {
    final frame = _decodeB64(_smallIndependentBlockChecksumB64);
    final decoded = lz4FrameDecode(frame);

    final expected = _expectedPayload(1024);
    expect(decoded, expected);

    _expectHeader(
      frame,
      blockIndependence: true,
      blockChecksum: true,
      contentChecksum: true,
      contentSize: null,
      blockMaxSizeId: 4,
    );
  });

  test('reference lz4 CLI empty frame decodes', () {
    final frame = _decodeB64(_emptyFrameB64);
    final decoded = lz4FrameDecode(frame);
    expect(decoded, Uint8List(0));

    _expectHeader(
      frame,
      blockIndependence: true,
      blockChecksum: false,
      contentChecksum: true,
      contentSize: null,
      blockMaxSizeId: 4,
    );
  });

  test('skippable frame prefix is ignored', () {
    final frame = _decodeB64(_smallIndependentDefaultB64);
    const magic = 0x184D2A50;

    final skippable = Uint8List.fromList([
      magic & 0xff,
      (magic >> 8) & 0xff,
      (magic >> 16) & 0xff,
      (magic >> 24) & 0xff,
      4,
      0,
      0,
      0,
      0xDE,
      0xAD,
      0xBE,
      0xEF,
    ]);

    final combined = Uint8List(skippable.length + frame.length);
    combined.setRange(0, skippable.length, skippable);
    combined.setRange(skippable.length, combined.length, frame);

    final decoded = lz4FrameDecode(combined);
    expect(decoded, _expectedPayload(1024));
  });
}
