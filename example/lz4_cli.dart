import 'dart:io';
import 'dart:typed_data';
import 'package:dart_lz4/dart_lz4.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    _printUsage();
    exit(1);
  }

  final command = args[0];
  if (command == 'compress') {
    if (args.length != 3) {
      print('Usage: compress <input_file> <output_file>');
      exit(1);
    }
    await _compress(args[1], args[2]);
  } else if (command == 'decompress') {
    if (args.length != 3) {
      print('Usage: decompress <input_file> <output_file>');
      exit(1);
    }
    await _decompress(args[1], args[2]);
  } else if (command == 'info') {
    if (args.length != 2) {
      print('Usage: info <input_file>');
      exit(1);
    }
    await _info(args[1]);
  } else {
    _printUsage();
    exit(1);
  }
}

void _printUsage() {
  print('dart_lz4 CLI Example');
  print('');
  print('Usage:');
  print('  compress   <input> <output>   Compress a file using LZ4 frames');
  print('  decompress <input> <output>   Decompress an LZ4 frame file');
  print('  info       <input>            Show LZ4 frame information');
}

Future<void> _compress(String inputPath, String outputPath) async {
  final inFile = File(inputPath);
  final outFile = File(outputPath);

  if (!await inFile.exists()) {
    print('Error: Input file not found: $inputPath');
    exit(1);
  }

  print('Compressing $inputPath to $outputPath...');
  final stopwatch = Stopwatch()..start();

  final inputSize = await inFile.length();

  // Use options to add a content checksum and content size for better integrity
  final options = Lz4FrameOptions(
    contentChecksum: true,
    contentSize: inputSize, // Stores original size in header
    compression: Lz4FrameCompression.fast, // Use 'hc' for high compression
  );

  try {
    final sink = outFile.openWrite();
    await inFile
        .openRead()
        .transform(lz4FrameEncoderWithOptions(options: options))
        .pipe(sink);

    stopwatch.stop();
    final outputSize = await outFile.length();
    final ratio = outputSize / inputSize;

    print('Done in ${stopwatch.elapsedMilliseconds}ms.');
    print('Original size: $inputSize bytes');
    print('Compressed size: $outputSize bytes');
    print('Ratio: ${ratio.toStringAsFixed(3)}');
  } catch (e) {
    print('Error during compression: $e');
    try {
      await outFile.delete();
    } catch (_) {}
    exit(1);
  }
}

Future<void> _decompress(String inputPath, String outputPath) async {
  final inFile = File(inputPath);
  final outFile = File(outputPath);

  if (!await inFile.exists()) {
    print('Error: Input file not found: $inputPath');
    exit(1);
  }

  print('Decompressing $inputPath to $outputPath...');
  final stopwatch = Stopwatch()..start();

  try {
    final sink = outFile.openWrite();
    await inFile.openRead().transform(lz4FrameDecoder()).pipe(sink);

    stopwatch.stop();
    print('Done in ${stopwatch.elapsedMilliseconds}ms.');
  } catch (e) {
    print('Error during decompression: $e');
    try {
      await outFile.delete();
    } catch (_) {}
    exit(1);
  }
}

Future<void> _info(String inputPath) async {
  final inFile = File(inputPath);
  if (!await inFile.exists()) {
    print('Error: Input file not found: $inputPath');
    exit(1);
  }

  try {
    // Read the first 20 bytes (enough for header + magic + descriptor)
    // lz4FrameInfo typically needs just the start of the file.
    // In a real scenario, we might want to read a small chunk.
    final headerBytes = await inFile.openRead(0, 32).first;
    // Note: openRead might return a chunk smaller than requested if file is small,
    // or a list of chunks. Stream.first gets the first chunk.
    // We assume the header fits in the first chunk read.

    // Since lz4FrameInfo is synchronous and expects bytes, we pass the chunk.
    final info = lz4FrameInfo(Uint8List.fromList(headerBytes));

    print('File: $inputPath');
    print('LZ4 Frame Info:');
    print('  Block Independence: ${info.blockIndependence}');
    print('  Block Checksum: ${info.blockChecksum}');
    print('  Content Checksum: ${info.contentChecksum}');
    print('  Block Max Size: ${_formatSize(info.blockMaxSize)}');
    print(
        '  Content Size: ${info.contentSize != null ? _formatSize(info.contentSize!) : "Unknown"}');
    print('  Dictionary ID: ${info.dictId ?? "None"}');
  } catch (e) {
    print('Error reading frame info: $e');
    exit(1);
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
