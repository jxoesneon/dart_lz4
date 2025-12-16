import 'dart:async';
import 'dart:typed_data';

import '../block/lz4_block_encoder.dart';
import '../internal/byte_writer.dart';
import '../xxhash/xxh32.dart';

const _lz4FrameMagic = 0x184D2204;

StreamTransformer<List<int>, List<int>> lz4FrameEncoderTransformer({
  int acceleration = 1,
}) {
  if (acceleration < 1) {
    throw RangeError.value(acceleration, 'acceleration');
  }

  return StreamTransformer.fromBind((input) async* {
    const flg = 0x60; // version=01, block independence=1
    const bd = 0x70; // 4MB max block size
    const blockMaxSize = 4 * 1024 * 1024;

    yield _encodeHeader(flg: flg, bd: bd);

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

        yield _encodeBlock(block, acceleration: acceleration);
      }
    }

    if (bufferedLen != 0) {
      final remaining = buf.takeBytes();
      bufferedLen = 0;
      if (remaining.isNotEmpty) {
        yield _encodeBlock(remaining, acceleration: acceleration);
      }
    }

    yield Uint8List(4);
  });
}

Uint8List _encodeHeader({required int flg, required int bd}) {
  final writer = ByteWriter(initialCapacity: 16);
  writer.writeUint32LE(_lz4FrameMagic);
  writer.writeUint8(flg);
  writer.writeUint8(bd);

  final descriptor = Uint8List.fromList([flg, bd]);
  final hc = (xxh32(descriptor, seed: 0) >> 8) & 0xff;
  writer.writeUint8(hc);

  return writer.toBytes();
}

Uint8List _encodeBlock(
  Uint8List chunk, {
  required int acceleration,
}) {
  final compressed = lz4BlockCompress(chunk, acceleration: acceleration);

  final useCompressed = compressed.length < chunk.length;
  final payload = useCompressed ? compressed : chunk;

  final blockSizeRaw = (useCompressed ? 0 : 0x80000000) | payload.length;

  final writer = ByteWriter(initialCapacity: payload.length + 8);
  writer.writeUint32LE(blockSizeRaw);
  writer.writeBytes(payload);
  return writer.toBytes();
}
