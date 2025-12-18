import 'dart:async';
import 'dart:typed_data';

import '../block/lz4_block_encoder.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_exception.dart';
import '../hc/lz4_hc_block_encoder.dart';
import '../xxhash/xxh32.dart';
import 'lz4_frame_options.dart';

const _lz4FrameMagic = 0x184D2204;

StreamTransformer<List<int>, List<int>> lz4FrameEncoderTransformer({
  int acceleration = 1,
}) {
  return lz4FrameEncoderTransformerWithOptions(
    options: Lz4FrameOptions(
      acceleration: acceleration,
    ),
  );
}

StreamTransformer<List<int>, List<int>> lz4FrameEncoderTransformerWithOptions({
  required Lz4FrameOptions options,
}) {
  return StreamTransformer.fromBind((input) async* {
    const version = 0x01;

    final flg = ((version & 0x03) << 6) |
        ((options.blockIndependence ? 1 : 0) << 5) |
        ((options.blockChecksum ? 1 : 0) << 4) |
        ((options.contentSize != null ? 1 : 0) << 3) |
        ((options.contentChecksum ? 1 : 0) << 2);

    final bd = (options.blockSize.bdId & 0x07) << 4;
    final blockMaxSize = options.blockSize.maxBytes;

    yield _encodeHeader(
      flg: flg,
      bd: bd,
      contentSize: options.contentSize,
    );

    final contentSize = options.contentSize;
    var totalIn = 0;

    Xxh32? contentHasher;
    if (options.contentChecksum) {
      contentHasher = Xxh32(seed: 0);
    }

    final buf = BytesBuilder(copy: false);
    var bufferedLen = 0;

    const historyWindow = 64 * 1024;
    final history = Uint8List(historyWindow);
    var historyLen = 0;

    void appendHistory(Uint8List bytes) {
      if (bytes.length >= historyWindow) {
        final start = bytes.length - historyWindow;
        history.setRange(0, historyWindow, bytes, start);
        historyLen = historyWindow;
        return;
      }

      final required = historyLen + bytes.length;
      if (required <= historyWindow) {
        history.setRange(historyLen, required, bytes);
        historyLen = required;
        return;
      }

      final drop = required - historyWindow;
      final keep = historyLen - drop;
      List.copyRange(history, 0, history, drop, drop + keep);
      historyLen = keep;
      history.setRange(historyLen, historyLen + bytes.length, bytes);
      historyLen += bytes.length;
    }

    Uint8List takeBlock(Uint8List all, int size) {
      return Uint8List.sublistView(all, 0, size);
    }

    Uint8List takeRest(Uint8List all, int start) {
      return Uint8List.sublistView(all, start, all.length);
    }

    final blockWriter = ByteWriter(initialCapacity: blockMaxSize + 16);

    Uint8List encodeBlock(Uint8List chunk, Uint8List? dictionary) {
      blockWriter.clear();
      // Reserve space for block size
      blockWriter.writeUint32LE(0);
      final payloadStart = 4;

      switch (options.compression) {
        case Lz4FrameCompression.fast:
          lz4BlockCompressToWriter(
            blockWriter,
            chunk,
            dictionary: dictionary,
            acceleration: options.acceleration,
          );
          break;
        case Lz4FrameCompression.hc:
          lz4HcBlockCompressToWriter(
            blockWriter,
            chunk,
            dictionary: dictionary,
            options: options.hcOptions,
          );
          break;
      }

      final compressedLen = blockWriter.length - payloadStart;
      final useCompressed = compressedLen < chunk.length;

      if (useCompressed) {
        // Patch block size
        blockWriter.writeUint32LEAt(0, compressedLen);
        if (options.blockChecksum) {
          final payload = Uint8List.sublistView(
              blockWriter.bytesView(), payloadStart, blockWriter.length);
          blockWriter.writeUint32LE(xxh32(payload, seed: 0));
        }
        return blockWriter.toBytes();
      } else {
        // Reset and write uncompressed
        blockWriter.clear();
        final blockSizeRaw = 0x80000000 | chunk.length;
        blockWriter.writeUint32LE(blockSizeRaw);
        blockWriter.writeBytes(chunk);
        if (options.blockChecksum) {
          blockWriter.writeUint32LE(xxh32(chunk, seed: 0));
        }
        return blockWriter.toBytes();
      }
    }

    await for (final chunk in input) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      if (bytes.isEmpty) {
        continue;
      }

      totalIn += bytes.length;
      if (contentSize != null && totalIn > contentSize) {
        throw Lz4FormatException('contentSize does not match stream length');
      }
      if (contentHasher != null) {
        contentHasher.update(bytes);
      }

      buf.add(bytes);
      bufferedLen += bytes.length;

      while (bufferedLen >= blockMaxSize) {
        final all = buf.takeBytes();

        final block = takeBlock(all, blockMaxSize);
        final rest = takeRest(all, blockMaxSize);

        if (rest.isNotEmpty) {
          buf.add(rest);
        }
        bufferedLen = rest.length;

        final dictionary = (!options.blockIndependence && historyLen != 0)
            ? Uint8List.sublistView(history, 0, historyLen)
            : null;

        yield encodeBlock(block, dictionary);

        if (!options.blockIndependence) {
          appendHistory(block);
        }
      }
    }

    if (bufferedLen != 0) {
      final remaining = buf.takeBytes();
      bufferedLen = 0;
      if (remaining.isNotEmpty) {
        final dictionary = (!options.blockIndependence && historyLen != 0)
            ? Uint8List.sublistView(history, 0, historyLen)
            : null;

        yield encodeBlock(remaining, dictionary);

        if (!options.blockIndependence) {
          appendHistory(remaining);
        }
      }
    }

    if (contentSize != null && totalIn != contentSize) {
      throw Lz4FormatException('contentSize does not match stream length');
    }

    yield Uint8List(4);

    if (options.contentChecksum) {
      final out = ByteWriter(initialCapacity: 4);
      out.writeUint32LE(contentHasher!.digest());
      yield out.toBytes();
    }
  });
}

Uint8List _encodeHeader({
  required int flg,
  required int bd,
  required int? contentSize,
}) {
  final writer = ByteWriter(initialCapacity: 24);
  writer.writeUint32LE(_lz4FrameMagic);
  writer.writeUint8(flg);
  writer.writeUint8(bd);

  if (contentSize != null) {
    writer.writeUint32LE(contentSize);
    writer.writeUint32LE(0);
  }

  final headerEnd = writer.length;
  final headerBytes = writer.bytesView();
  final descriptor = Uint8List.sublistView(headerBytes, 4, headerEnd);
  final hc = (xxh32(descriptor, seed: 0) >> 8) & 0xff;
  writer.writeUint8(hc);

  return writer.toBytes();
}
