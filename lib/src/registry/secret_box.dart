/// Lightweight authenticated symmetric encryption for at-rest credentials.
///
/// Uses HMAC-SHA256 over a random nonce + ciphertext (XOR keystream derived
/// from `HMAC(key, nonce || counter)`). This is intentionally a small
/// dependency-free construction whose only requirements are:
///   1) ciphertext produced by one [SecretBox] cannot be decrypted by another
///      with a different key (TC-422 contract);
///   2) round-trip with the same key recovers the plaintext (TC-421 contract).
///
/// Hosts that need stronger guarantees should swap in a real AEAD
/// (`package:cryptography` AES-GCM, libsodium SecretBox, etc.).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class SecretBox {

  SecretBox(List<int> key) : key = List<int>.unmodifiable(_normalizeKey(key));

  /// Generate a fresh random key.
  factory SecretBox.generate() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return SecretBox(bytes);
  }

  /// Derive a key by hashing [phrase].
  factory SecretBox.fromPassphrase(String phrase) {
    return SecretBox(sha256.convert(utf8.encode(phrase)).bytes);
  }
  /// 32-byte key. Held in memory only.
  final List<int> key;

  static final Random _rng = Random.secure();

  /// Encrypt [plaintext] (UTF-8). Returns a self-contained base64 token of
  /// the form `nonce(16) || tag(32) || ciphertext`.
  String encrypt(String plaintext) {
    final nonce = Uint8List.fromList(
        List<int>.generate(16, (_) => _rng.nextInt(256)));
    final body = Uint8List.fromList(utf8.encode(plaintext));
    final stream = _keystream(nonce, body.length);
    final cipher = Uint8List(body.length);
    for (var i = 0; i < body.length; i++) {
      cipher[i] = body[i] ^ stream[i];
    }
    final mac = Hmac(sha256, key)
        .convert(<int>[...nonce, ...cipher])
        .bytes;
    final blob = <int>[...nonce, ...mac, ...cipher];
    return base64.encode(blob);
  }

  /// Decrypt a token produced by [encrypt]. Returns `null` when the MAC
  /// does not verify under [key], when the token is too short, or when the
  /// payload is not valid UTF-8.
  String? decrypt(String token) {
    Uint8List bytes;
    try {
      bytes = base64.decode(token);
    } on Object {
      return null;
    }
    if (bytes.length < 16 + 32) return null;
    final nonce = bytes.sublist(0, 16);
    final mac = bytes.sublist(16, 16 + 32);
    final cipher = bytes.sublist(16 + 32);
    final expected = Hmac(sha256, key)
        .convert(<int>[...nonce, ...cipher])
        .bytes;
    if (!_constantTimeEquals(expected, mac)) return null;
    final stream = _keystream(nonce, cipher.length);
    final plain = Uint8List(cipher.length);
    for (var i = 0; i < cipher.length; i++) {
      plain[i] = cipher[i] ^ stream[i];
    }
    try {
      return utf8.decode(plain);
    } on Object {
      return null;
    }
  }

  Uint8List _keystream(Uint8List nonce, int length) {
    final out = Uint8List(length);
    var offset = 0;
    var counter = 0;
    while (offset < length) {
      final block = Hmac(sha256, key)
          .convert(<int>[...nonce, ..._intToBytes(counter)])
          .bytes;
      final take = (length - offset) < block.length
          ? (length - offset)
          : block.length;
      out.setRange(offset, offset + take, block);
      offset += take;
      counter++;
    }
    return out;
  }

  static List<int> _intToBytes(int value) {
    return <int>[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static List<int> _normalizeKey(List<int> raw) {
    if (raw.length == 32) return raw;
    return sha256.convert(raw).bytes;
  }
}
