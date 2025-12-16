import 'dart:typed_data';

import '../block/lz4_block_encoder.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_exception.dart';
import '../hc/lz4_hc_block_encoder.dart';
import '../xxhash/xxh32.dart';
import 'lz4_frame_options.dart';

const _lz4FrameMagic = 0x184D2204;

Uint8List lz4FrameEncodeBytes(
  Uint8List src, {
  int acceleration = 1,
}) {
  return lz4FrameEncodeBytesWithOptions(
    src,
    options: Lz4FrameOptions(
      acceleration: acceleration,
    ),
  );
}

Uint8List lz4FrameEncodeBytesWithOptions(
  Uint8List src, {
  required Lz4FrameOptions options,
}) {
  const version = 0x01;

  final flg = ((version & 0x03) << 6) |
      ((options.blockIndependence ? 1 : 0) << 5) |
      ((options.blockChecksum ? 1 : 0) << 4) |
      ((options.contentSize != null ? 1 : 0) << 3) |
      ((options.contentChecksum ? 1 : 0) << 2);

  final bd = (options.blockSize.bdId & 0x07) << 4;
  final blockMaxSize = options.blockSize.maxBytes;

  final writer = ByteWriter(initialCapacity: src.length + 64);
  writer.writeUint32LE(_lz4FrameMagic);

  writer.writeUint8(flg);
  writer.writeUint8(bd);

  final contentSize = options.contentSize;
  if (contentSize != null) {
    writer.writeUint32LE(contentSize);
    writer.writeUint32LE(0);
  }

  final headerEnd = writer.length;
  final headerBytes = writer.bytesView();
  final descriptor = Uint8List.sublistView(headerBytes, 4, headerEnd);
  final hc = (xxh32(descriptor, seed: 0) >> 8) & 0xff;
  writer.writeUint8(hc);

  Xxh32? contentHasher;
  if (options.contentChecksum) {
    contentHasher = Xxh32(seed: 0);
  }

  const historyWindow = 64 * 1024;

  var offset = 0;
  while (offset < src.length) {
    var end = offset + blockMaxSize;
    if (end > src.length) {
      end = src.length;
    }

    final chunk = Uint8List.sublistView(src, offset, end);

    if (contentHasher != null) {
      contentHasher.update(chunk);
    }

    final Uint8List? dictionary;
    if (!options.blockIndependence && offset != 0) {
      final start = offset > historyWindow ? (offset - historyWindow) : 0;
      dictionary = Uint8List.sublistView(src, start, offset);
    } else {
      dictionary = null;
    }

    final Uint8List compressed;
    switch (options.compression) {
      case Lz4FrameCompression.fast:
        compressed = lz4BlockCompress(
          chunk,
          dictionary: dictionary,
          acceleration: options.acceleration,
        );
        break;
      case Lz4FrameCompression.hc:
        compressed = lz4HcBlockCompress(
          chunk,
          dictionary: dictionary,
          options: options.hcOptions,
        );
        break;
    }

    final useCompressed = compressed.length < chunk.length;
    final payload = useCompressed ? compressed : chunk;

    final isUncompressed = !useCompressed;
    final blockSizeRaw = (isUncompressed ? 0x80000000 : 0) | payload.length;
    writer.writeUint32LE(blockSizeRaw);
    writer.writeBytes(payload);

    if (options.blockChecksum) {
      writer.writeUint32LE(xxh32(payload, seed: 0));
    }

    offset = end;
  }

  writer.writeUint32LE(0);

  if (options.contentChecksum) {
    writer.writeUint32LE(contentHasher!.digest());
  }

  if (contentSize != null && src.length != contentSize) {
    throw Lz4FormatException('contentSize does not match src length');
  }

  return writer.toBytes();
}
