import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class SyncError implements Exception {
  SyncError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Where a vault's encrypted file is mirrored. Stored only in the local copy
/// of the vault, never in the synced one.
class SyncConfig {
  SyncConfig({
    required this.type,
    required this.path,
    this.host = '',
    this.port = 22,
    this.username = '',
    this.password = '',
    this.privateKey = '',
    this.fingerprint = '',
  });

  factory SyncConfig.fromJson(Map<String, dynamic> j) => SyncConfig(
    type: j['type'] as String,
    path: j['path'] as String,
    host: j['host'] as String? ?? '',
    port: j['port'] as int? ?? 22,
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    privateKey: j['privateKey'] as String? ?? '',
    fingerprint: j['fingerprint'] as String? ?? '',
  );

  static const folder = 'folder';
  static const sftp = 'sftp';

  /// [folder] (a file in a cloud-drive or shared folder) or [sftp].
  final String type;

  /// Full path of the vault file at the target.
  final String path;
  final String host;
  final int port;
  final String username;
  final String password;
  final String privateKey;

  /// Host key pinned on first contact with the SFTP server.
  String fingerprint;

  String get summary =>
      type == folder ? path : 'sftp://$username@$host:$port/$path';

  Map<String, dynamic> toJson() => {
    'type': type,
    'path': path,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'privateKey': privateKey,
    'fingerprint': fingerprint,
  };
}

abstract class SyncIo {
  /// The vault file's text, or null when nothing has been uploaded yet.
  Future<String?> read();
  Future<void> write(String content);
}

/// Opens the sync target, runs [body] against it and releases it again.
Future<T> withSyncTarget<T>(
  SyncConfig cfg,
  Future<T> Function(SyncIo io) body,
) async {
  if (cfg.type == SyncConfig.folder) return body(_FolderIo(cfg.path));
  if (cfg.type != SyncConfig.sftp) {
    throw SyncError('Unknown sync type: ${cfg.type}');
  }

  final SSHSocket socket;
  try {
    socket = await SSHSocket.connect(
      cfg.host,
      cfg.port,
      timeout: const Duration(seconds: 15),
    );
  } on Exception catch (e) {
    throw SyncError('Cannot reach ${cfg.host}:${cfg.port} ($e)');
  }
  String? mismatch;
  final client = SSHClient(
    socket,
    username: cfg.username,
    identities: cfg.privateKey.trim().isEmpty
        ? null
        : SSHKeyPair.fromPem(cfg.privateKey),
    onPasswordRequest: cfg.password.isEmpty ? null : () => cfg.password,
    onVerifyHostKey: (type, fingerprint) {
      final seen = utf8.decode(fingerprint);
      if (cfg.fingerprint.isEmpty) {
        cfg.fingerprint = seen;
        return true;
      }
      if (cfg.fingerprint == seen) return true;
      mismatch = seen;
      return false;
    },
  );
  try {
    final SftpClient sftp;
    try {
      await client.authenticated;
      sftp = await client.sftp();
    } catch (e) {
      if (mismatch != null) {
        throw SyncError(
          'The sync server\'s host key changed (now $mismatch). Sync is '
          'stopped; set the sync target up again if this is expected.',
        );
      }
      if (e is SSHAuthError) {
        throw SyncError('The sync server rejected the login');
      }
      throw SyncError('Sync connection failed ($e)');
    }
    return await body(_SftpIo(sftp, cfg.path));
  } finally {
    client.close();
  }
}

class _FolderIo implements SyncIo {
  _FolderIo(this.path);
  final String path;

  @override
  Future<String?> read() async {
    final f = File(path);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String content) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(path);
  }
}

class _SftpIo implements SyncIo {
  _SftpIo(this.sftp, this.path);
  final SftpClient sftp;
  final String path;

  @override
  Future<String?> read() async {
    final SftpFile f;
    try {
      f = await sftp.open(path);
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
    try {
      return utf8.decode(await f.readBytes());
    } finally {
      await f.close();
    }
  }

  @override
  Future<void> write(String content) async {
    final parts = path.split('/');
    var dir = path.startsWith('/') ? '/' : '';
    for (final p in parts.sublist(0, parts.length - 1)) {
      if (p.isEmpty) continue;
      dir = dir.isEmpty || dir == '/' ? '$dir$p' : '$dir/$p';
      try {
        await sftp.mkdir(dir);
      } on SftpStatusError {
        // Already there, or not ours to create; the open below reports it.
      }
    }
    final tmp = '$path.tmp';
    final f = await sftp.open(
      tmp,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await f.writeBytes(Uint8List.fromList(utf8.encode(content)));
    } finally {
      await f.close();
    }
    try {
      await sftp.remove(path);
    } on SftpStatusError {
      // First upload: nothing to replace.
    }
    await sftp.rename(tmp, path);
  }
}
