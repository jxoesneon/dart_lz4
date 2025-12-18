@TestOn('vm')
library lz4_cli_decode_our_frames_test;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

bool _isLz4AvailableSync() {
  if (Platform.isWindows) {
    return false;
  }

  final explicit = Platform.environment['LZ4_CLI'];
  if (explicit != null && explicit.isNotEmpty) {
    return File(explicit).existsSync();
  }

  try {
    final result = Process.runSync(
      'lz4',
      const ['--version'],
      runInShell: true,
    );
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

bool _hasUncompressedBlock(Uint8List frame) {
  int readU32LE(int offset) {
    final b0 = frame[offset];
    final b1 = frame[offset + 1];
    final b2 = frame[offset + 2];
    final b3 = frame[offset + 3];
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
  }

  if (frame.length < 7) {
    return false;
  }
  const magic = 0x184D2204;
  if (readU32LE(0) != magic) {
    return false;
  }

  final flg = frame[4];
  final blockChecksum = ((flg >> 4) & 0x01) != 0;
  final contentSizeFlag = ((flg >> 3) & 0x01) != 0;
  final dictIdFlag = (flg & 0x01) != 0;

  var offset = 6;
  if (contentSizeFlag) {
    offset += 8;
  }
  if (dictIdFlag) {
    offset += 4;
  }
  offset += 1;

  while (offset + 4 <= frame.length) {
    final blockSizeRaw = readU32LE(offset);
    offset += 4;
    if (blockSizeRaw == 0) {
      break;
    }

    final isUncompressed = (blockSizeRaw & 0x80000000) != 0;
    final blockSize = blockSizeRaw & 0x7fffffff;
    offset += blockSize;
    if (blockChecksum) {
      offset += 4;
    }
    if (isUncompressed) {
      return true;
    }
  }

  return false;
}

String _lz4Command() {
  final explicit = Platform.environment['LZ4_CLI'];
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }
  return 'lz4';
}

Uint8List _payload({required int size, required int seed}) {
  final r = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < out.length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

Future<Uint8List> _decodeWithCli(Uint8List encoded) async {
  final dir = Directory.systemTemp.createTempSync('dart_lz4_cli_');
  try {
    final inFile = File('${dir.path}/data.lz4');
    inFile.writeAsBytesSync(encoded, flush: true);

    final result = await Process.run(
      _lz4Command(),
      const ['-d', '-c', 'data.lz4'],
      workingDirectory: dir.path,
      runInShell: true,
      stdoutEncoding: null,
      stderrEncoding: null,
    );

    if (result.exitCode != 0) {
      final stderrBytes = result.stderr as List<int>;
      throw StateError(
          'lz4 CLI failed (exit ${result.exitCode}): ${String.fromCharCodes(stderrBytes)}');
    }

    return Uint8List.fromList(result.stdout as List<int>);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  Object skipReason =
      'Skipping: reference lz4 CLI interop tests require dart:io';
  if (!const bool.fromEnvironment('dart.library.html')) {
    final cliAvailable = _isLz4AvailableSync();
    skipReason = cliAvailable
        ? false
        : 'Skipping: reference lz4 CLI not available (set LZ4_CLI or install lz4)';
  }

  test(
    'reference lz4 CLI decodes our independent-block frames',
    () async {
      final src = _payload(size: 128 * 1024 + 123, seed: 1);

      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          blockSize: Lz4FrameBlockSize.k64KB,
          blockIndependence: true,
          blockChecksum: true,
          contentChecksum: true,
          contentSize: src.length,
          compression: Lz4FrameCompression.fast,
          acceleration: 1,
        ),
      );

      final decoded = await _decodeWithCli(encoded);
      expect(decoded, src);
    },
    skip: skipReason,
  );

  test(
    'reference lz4 CLI decodes our dependent-block frames',
    () async {
      final src = _payload(size: 128 * 1024 + 123, seed: 2);

      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          blockSize: Lz4FrameBlockSize.k64KB,
          blockIndependence: false,
          blockChecksum: true,
          contentChecksum: true,
          contentSize: src.length,
          compression: Lz4FrameCompression.fast,
          acceleration: 1,
        ),
      );

      final decoded = await _decodeWithCli(encoded);
      expect(decoded, src);
    },
    skip: skipReason,
  );

  test(
    'reference lz4 CLI decodes our hc frames',
    () async {
      final src = _payload(size: 128 * 1024 + 123, seed: 3);

      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          blockSize: Lz4FrameBlockSize.k64KB,
          blockIndependence: true,
          blockChecksum: true,
          contentChecksum: true,
          contentSize: src.length,
          compression: Lz4FrameCompression.hc,
        ),
      );

      final decoded = await _decodeWithCli(encoded);
      expect(decoded, src);
    },
    skip: skipReason,
  );

  test(
    'reference lz4 CLI decodes our frames (options matrix)',
    () async {
      final cases = <Lz4FrameOptions Function(Uint8List src)>[
        (src) => Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: true,
              blockChecksum: false,
              contentChecksum: false,
              compression: Lz4FrameCompression.fast,
            ),
        (src) => Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: true,
              blockChecksum: true,
              contentChecksum: false,
              contentSize: src.length,
              compression: Lz4FrameCompression.fast,
              acceleration: 2,
            ),
        (src) => Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: true,
              blockChecksum: false,
              contentChecksum: true,
              compression: Lz4FrameCompression.fast,
            ),
        (src) => Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k256KB,
              blockIndependence: false,
              blockChecksum: false,
              contentChecksum: true,
              contentSize: src.length,
              compression: Lz4FrameCompression.fast,
            ),
        (src) => Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: false,
              blockChecksum: true,
              contentChecksum: false,
              compression: Lz4FrameCompression.fast,
            ),
        (src) => Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: true,
              blockChecksum: true,
              contentChecksum: true,
              contentSize: src.length,
              compression: Lz4FrameCompression.hc,
            ),
        (src) => Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: false,
              blockChecksum: true,
              contentChecksum: true,
              contentSize: src.length,
              compression: Lz4FrameCompression.hc,
            ),
      ];

      for (var i = 0; i < cases.length; i++) {
        final src = _payload(size: 128 * 1024 + 123 + i, seed: 100 + i);
        final options = cases[i](src);

        final encoded = lz4FrameEncodeWithOptions(src, options: options);
        final decoded = await _decodeWithCli(encoded);

        expect(decoded, src, reason: 'case $i');
      }
    },
    skip: skipReason,
  );

  test(
    'reference lz4 CLI decodes our frames containing at least one uncompressed block',
    () async {
      Uint8List? encoded;
      Uint8List? src;
      for (var seed = 1; seed <= 50; seed++) {
        final candidate = _payload(size: 256 * 1024 + 7, seed: seed);
        final frame = lz4FrameEncodeWithOptions(
          candidate,
          options: Lz4FrameOptions(
            blockSize: Lz4FrameBlockSize.k64KB,
            blockIndependence: true,
            blockChecksum: true,
            contentChecksum: true,
            compression: Lz4FrameCompression.fast,
          ),
        );
        if (_hasUncompressedBlock(frame)) {
          encoded = frame;
          src = candidate;
          break;
        }
      }

      expect(encoded, isNotNull,
          reason: 'Failed to produce a frame with an uncompressed block');

      final decoded = await _decodeWithCli(encoded!);
      expect(decoded, src);
    },
    skip: skipReason,
  );
}
