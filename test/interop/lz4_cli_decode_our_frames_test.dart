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
  final cliAvailable = _isLz4AvailableSync();

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
    skip: cliAvailable
        ? false
        : 'Skipping: reference lz4 CLI not available (set LZ4_CLI or install lz4)',
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
    skip: cliAvailable
        ? false
        : 'Skipping: reference lz4 CLI not available (set LZ4_CLI or install lz4)',
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
    skip: cliAvailable
        ? false
        : 'Skipping: reference lz4 CLI not available (set LZ4_CLI or install lz4)',
  );
}
