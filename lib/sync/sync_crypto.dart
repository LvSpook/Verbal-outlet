/// Authenticated encryption for sync traffic.
///
/// Notes are personal, so they are not sent in the clear even over the local
/// network. The key is generated when a device is paired and shared only once,
/// inside the QR code, so the code itself is the secret - don't screenshot it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encrypts each message with AES-256-GCM under a 32-byte shared key.
///
/// GCM rather than a plain cipher because it is authenticated: a frame that was
/// altered in transit, or sent by something without the key, fails to open
/// instead of decoding to garbage notes.
class SyncCrypto {
  SyncCrypto(String base64Key)
    : _key = SecretKeyData(_decodeKey(base64Key));

  final SecretKeyData _key;
  static final AesGcm _cipher = AesGcm.with256bits();
  static final Random _random = Random.secure();

  /// A fresh key, as base64, for pairing a new device.
  static String newKey() => base64Url.encode(_randomBytes(32));

  /// Encrypts [message] to one line-safe string.
  Future<String> seal(Map<String, Object?> message) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(message)),
      secretKey: _key,
    );
    return base64.encode(box.concatenation());
  }

  /// Decrypts a sealed frame, or returns null if it cannot be opened.
  Future<Map<String, Object?>?> open(String frame) async {
    try {
      final box = SecretBox.fromConcatenation(
        base64.decode(frame.trim()),
        nonceLength: _cipher.nonceLength,
        macLength: _cipher.macAlgorithm.macLength,
      );
      final clear = await _cipher.decrypt(box, secretKey: _key);
      final json = jsonDecode(utf8.decode(clear));
      return json is Map<String, Object?> ? json : null;
    } catch (_) {
      // Wrong key, a tampered frame, or a stray line on the socket.
      return null;
    }
  }

  static Uint8List _decodeKey(String value) {
    final bytes = base64Url.decode(base64Url.normalize(value.trim()));
    if (bytes.length != 32) {
      throw ArgumentError('A sync key must be 32 bytes, got ${bytes.length}.');
    }
    return Uint8List.fromList(bytes);
  }

  static Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}
