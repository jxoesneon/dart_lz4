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

    // Reserve space for block size (4 bytes)
    final blockStart = writer.length;
    writer.writeUint32LE(0); // placeholder

    final payloadStart = writer.length;

    switch (options.compression) {
      case Lz4FrameCompression.fast:
        lz4BlockCompressToWriter(
          writer,
          chunk,
          dictionary: dictionary,
          acceleration: options.acceleration,
        );
        break;
      case Lz4FrameCompression.hc:
        lz4HcBlockCompressToWriter(
          writer,
          chunk,
          dictionary: dictionary,
          options: options.hcOptions,
        );
        break;
    }

    final compressedLen = writer.length - payloadStart;
    final useCompressed = compressedLen < chunk.length;

    if (useCompressed) {
      // Update block size header
      final blockSizeRaw = compressedLen; // Compressed flag bit 31 is 0
      writer.writeUint32LEAt(blockStart, blockSizeRaw);

      if (options.blockChecksum) {
        // We need to calculate checksum of the COMPRESSED payload
        // Wait, LZ4 block checksum is of the compressed data?
        // Spec says: "If the Block Checksum flag is set, a 4-byte Checksum is appended to the end of the Block."
        // "The checksum is the result of xxHash32() on the raw (compressed) block data."
        // Wait, standard LZ4 frame spec says:
        // "Block Checksum: if this flag is set, each block is followed by a 4-bytes checksum of that block.
        // The checksum is calculated on the raw (compressed) data."
        // Let's verify.
        // My previous implementation was: writer.writeUint32LE(xxh32(payload, seed: 0));
        // where payload was compressed or chunk.
        // So yes, checksum of what was written.
        // We can access it via writer view.
        final payloadView = Uint8List.sublistView(
            writer.bytesView(), payloadStart, writer.length);
        writer.writeUint32LE(xxh32(payloadView, seed: 0));
      }
    } else {
      // Discard compressed data and write uncompressed
      writer.length = blockStart; // Rewind
      final blockSizeRaw = 0x80000000 | chunk.length;
      writer.writeUint32LE(blockSizeRaw);
      writer.writeBytes(chunk);

      if (options.blockChecksum) {
        writer.writeUint32LE(xxh32(chunk, seed: 0));
      }
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
