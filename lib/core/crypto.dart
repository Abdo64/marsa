import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Thrown when a vault cannot be decrypted with the supplied key.
class WrongPassword implements Exception {
  @override
  String toString() => 'Wrong master password';
}

class VaultFormatError implements Exception {
  VaultFormatError(this.message);
  final String message;
  @override
  String toString() => message;
}

final _rng = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

String newId() =>
    randomBytes(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Argon2id parameters. They travel in the vault header so they can be raised
/// later without breaking old files.
class KdfParams {
  KdfParams({
    required this.salt,
    this.memoryKib = 19456,
    this.iterations = 2,
    this.lanes = 1,
  });

  factory KdfParams.fresh() => KdfParams(salt: randomBytes(16));

  factory KdfParams.fromJson(Map<String, dynamic> j) {
    if (j['alg'] != 'argon2id') {
      throw VaultFormatError('Unsupported key derivation: ${j['alg']}');
    }
    final p = KdfParams(
      salt: base64.decode(j['salt'] as String),
      memoryKib: j['m'] as int,
      iterations: j['t'] as int,
      lanes: j['p'] as int,
    );
    // A vault file can come from a sync location, so refuse parameters that
    // would hang or exhaust the device instead of trusting them.
    if (p.salt.length < 8 ||
        p.memoryKib < 8 ||
        p.memoryKib > 1 << 20 ||
        p.iterations < 1 ||
        p.iterations > 64 ||
        p.lanes < 1 ||
        p.lanes > 16) {
      throw VaultFormatError('Vault header has invalid key parameters');
    }
    return p;
  }

  final Uint8List salt;
  final int memoryKib;
  final int iterations;
  final int lanes;

  Map<String, dynamic> toJson() => {
    'alg': 'argon2id',
    'm': memoryKib,
    't': iterations,
    'p': lanes,
    'salt': base64.encode(salt),
  };

  bool sameAs(KdfParams o) => jsonEncode(toJson()) == jsonEncode(o.toJson());
}

Uint8List deriveKeySync(String password, KdfParams p) {
  final gen = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        p.salt,
        desiredKeyLength: 32,
        iterations: p.iterations,
        memory: p.memoryKib,
        lanes: p.lanes,
      ),
    );
  return gen.process(Uint8List.fromList(utf8.encode(password)));
}

/// Derives the vault key off the UI thread.
Future<Uint8List> deriveKey(String password, KdfParams p) =>
    Isolate.run(() => deriveKeySync(password, p));

/// The on-disk and on-sync-target representation of a vault: a small JSON
/// document holding the KDF header and an AES-256-GCM ciphertext.
class Envelope {
  Envelope(this.kdf, this.nonce, this.ciphertext);

  factory Envelope.parse(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      throw VaultFormatError('Not a Marsa vault file');
    }
    if (j is! Map<String, dynamic> || j['marsa'] != 1) {
      throw VaultFormatError('Not a Marsa vault file');
    }
    try {
      return Envelope(
        KdfParams.fromJson(j['kdf'] as Map<String, dynamic>),
        base64.decode(j['nonce'] as String),
        base64.decode(j['ct'] as String),
      );
    } on TypeError {
      throw VaultFormatError('Vault file is damaged');
    } on FormatException {
      throw VaultFormatError('Vault file is damaged');
    }
  }

  final KdfParams kdf;
  final Uint8List nonce;
  final Uint8List ciphertext;

  String encode() => jsonEncode({
    'marsa': 1,
    'kdf': kdf.toJson(),
    'nonce': base64.encode(nonce),
    'ct': base64.encode(ciphertext),
  });
}

// The header is authenticated so the KDF parameters cannot be swapped.
Uint8List _aad(KdfParams kdf) =>
    Uint8List.fromList(utf8.encode('marsa1${jsonEncode(kdf.toJson())}'));

GCMBlockCipher _gcm(
  bool encrypt,
  Uint8List key,
  Uint8List nonce,
  KdfParams k,
) =>
    GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, _aad(k)));

String seal(Uint8List key, KdfParams kdf, Object? json) {
  final plain = gzip.encode(utf8.encode(jsonEncode(json)));
  final nonce = randomBytes(12);
  final ct = _gcm(true, key, nonce, kdf).process(Uint8List.fromList(plain));
  return Envelope(kdf, nonce, ct).encode();
}

dynamic open(Uint8List key, Envelope env) {
  final Uint8List plain;
  try {
    plain = _gcm(false, key, env.nonce, env.kdf).process(env.ciphertext);
  } on InvalidCipherTextException {
    throw WrongPassword();
  } on ArgumentError {
    throw WrongPassword();
  }
  return jsonDecode(utf8.decode(gzip.decode(plain)));
}
