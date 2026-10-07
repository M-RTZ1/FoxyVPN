import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Uint8List hmacSha256(List<int> key, List<int> data) {
  final mac = Hmac(sha256, key);
  return Uint8List.fromList(mac.convert(data).bytes);
}

Uint8List sha256Bytes(List<int> data) =>
    Uint8List.fromList(sha256.convert(data).bytes);

/// HKDF-SHA256 with a zero salt, matching the Android client's derivation.
Uint8List hkdf(List<int> ikm, String info, int length,
    {Uint8List? salt}) {
  final saltBytes = salt ?? Uint8List(32);
  final prk = hmacSha256(saltBytes, ikm);
  final infoBytes = utf8.encode(info);
  final result = Uint8List(length);
  Uint8List previousBlock = Uint8List(0);
  int generated = 0;
  int counter = 1;
  while (generated < length) {
    final input = Uint8List(previousBlock.length + infoBytes.length + 1)
      ..setRange(0, previousBlock.length, previousBlock)
      ..setRange(previousBlock.length, previousBlock.length + infoBytes.length,
          infoBytes)
      ..[previousBlock.length + infoBytes.length] = counter;
    final block = hmacSha256(prk, input);
    final toCopy =
        block.length < length - generated ? block.length : length - generated;
    result.setRange(generated, generated + toCopy, block);
    generated += toCopy;
    previousBlock = block;
    counter++;
  }
  return result;
}

Uint8List pbkdf2HmacSha256(
    List<int> password, List<int> salt, int iterations, int keyLengthBytes) {
  const hLen = 32;
  final numBlocks = (keyLengthBytes + hLen - 1) ~/ hLen;
  final result = Uint8List(numBlocks * hLen);
  final mac = Hmac(sha256, password);
  for (int blockIndex = 1; blockIndex <= numBlocks; blockIndex++) {
    final blockIndexBytes = Uint8List(4)
      ..[0] = (blockIndex >> 24) & 0xFF
      ..[1] = (blockIndex >> 16) & 0xFF
      ..[2] = (blockIndex >> 8) & 0xFF
      ..[3] = blockIndex & 0xFF;
    Uint8List u =
        Uint8List.fromList(mac.convert([...salt, ...blockIndexBytes]).bytes);
    final t = Uint8List.fromList(u);
    for (int iter = 2; iter <= iterations; iter++) {
      u = Uint8List.fromList(mac.convert(u).bytes);
      for (int i = 0; i < t.length; i++) {
        t[i] ^= u[i];
      }
    }
    result.setRange((blockIndex - 1) * hLen, blockIndex * hLen, t);
  }
  return Uint8List.view(
      result.buffer, result.offsetInBytes, keyLengthBytes);
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join();

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
