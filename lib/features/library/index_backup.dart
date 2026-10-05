import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encrypted library index. Video files stay on the phone.
class IndexBackup {
  const IndexBackup();

  static const magic = 'SSB1';

  Future<Uint8List> seal(String jsonText, String passphrase) async {
    final salt = _random(16);
    final secret = await _key(passphrase, salt);
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonText),
      secretKey: secret,
    );
    final out = BytesBuilder();
    out.add(ascii.encode(magic));
    out.add(_chunk(salt));
    out.add(_chunk(box.nonce));
    out.add(_chunk(box.mac.bytes));
    out.add(box.cipherText);
    return out.toBytes();
  }

  Future<String> open(Uint8List bytes, String passphrase) async {
    final data = bytes;
    if (data.length < 8 || ascii.decode(data.sublist(0, 4), allowInvalid: true) != magic) {
      throw const FormatException('This is not a SocialSave library backup.');
    }
    var offset = 4;
    final salt = _read(data, offset);
    offset += 1 + salt.length;
    final nonce = _read(data, offset);
    offset += 1 + nonce.length;
    final mac = _read(data, offset);
    offset += 1 + mac.length;
    final cipher = data.sublist(offset);
    final secret = await _key(passphrase, salt);
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: secret,
    );
    return utf8.decode(clear);
  }

  Future<SecretKey> _key(String passphrase, List<int> salt) {
    final trimmed = passphrase.trim();
    if (trimmed.length < 4) {
      throw const FormatException('Use a passphrase of at least 4 characters.');
    }
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(trimmed)),
      nonce: salt,
    );
  }

  List<int> _random(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  List<int> _chunk(List<int> bytes) {
    if (bytes.length > 255) {
      throw const FormatException('Backup header is too large.');
    }
    return [bytes.length, ...bytes];
  }

  List<int> _read(Uint8List data, int offset) {
    if (offset >= data.length) {
      throw const FormatException('This backup is incomplete.');
    }
    final length = data[offset];
    final start = offset + 1;
    final end = start + length;
    if (end > data.length) {
      throw const FormatException('This backup is incomplete.');
    }
    return data.sublist(start, end);
  }
}
