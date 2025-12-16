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
  if (!options.blockIndependence) {
    throw const Lz4UnsupportedFeatureException(
        'Dependent blocks are not supported for encoding');
  }

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

    Uint8List takeBlock(Uint8List all, int size) {
      return Uint8List.sublistView(all, 0, size);
    }

    Uint8List takeRest(Uint8List all, int start) {
      return Uint8List.sublistView(all, start, all.length);
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

        yield _encodeBlock(block, options: options);
      }
    }

    if (bufferedLen != 0) {
      final remaining = buf.takeBytes();
      bufferedLen = 0;
      if (remaining.isNotEmpty) {
        yield _encodeBlock(remaining, options: options);
      }
    }

    yield Uint8List(4);

    if (options.contentChecksum) {
      final out = ByteWriter(initialCapacity: 4);
      out.writeUint32LE(contentHasher!.digest());
      yield out.toBytes();
    }

    if (contentSize != null && totalIn != contentSize) {
      throw Lz4FormatException('contentSize does not match stream length');
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

Uint8List _encodeBlock(
  Uint8List chunk, {
  required Lz4FrameOptions options,
}) {
  final Uint8List compressed;
  switch (options.compression) {
    case Lz4FrameCompression.fast:
      compressed = lz4BlockCompress(chunk, acceleration: options.acceleration);
      break;
    case Lz4FrameCompression.hc:
      compressed = lz4HcBlockCompress(chunk, options: options.hcOptions);
      break;
  }

  final useCompressed = compressed.length < chunk.length;
  final payload = useCompressed ? compressed : chunk;

  final blockSizeRaw = (useCompressed ? 0 : 0x80000000) | payload.length;

  final writer = ByteWriter(
      initialCapacity: payload.length + 8 + (options.blockChecksum ? 4 : 0));
  writer.writeUint32LE(blockSizeRaw);
  writer.writeBytes(payload);

  if (options.blockChecksum) {
    writer.writeUint32LE(xxh32(payload, seed: 0));
  }
  return writer.toBytes();
}
