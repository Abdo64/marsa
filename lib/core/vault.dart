import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'crypto.dart';
import 'models.dart';
import 'sync.dart';

class VaultInfo {
  VaultInfo(this.id, this.name);
  final String id;
  String name;
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// The remote copy is encrypted with a different master password than the
/// local one: someone changed it on another device.
class RemotePasswordChanged implements Exception {
  @override
  String toString() => 'The vault password was changed on another device';
}

/// The list of vaults on this device. Names and ids are not secret; everything
/// else lives in each vault's encrypted file.
class VaultRegistry extends ChangeNotifier {
  VaultRegistry(this.dir);

  final Directory dir;
  final List<VaultInfo> vaults = [];

  File get _index => File('${dir.path}/vaults.json');
  File fileOf(String id) => File('${dir.path}/$id.vault');

  Future<void> load() async {
    await dir.create(recursive: true);
    vaults.clear();
    if (await _index.exists()) {
      for (final v in jsonDecode(await _index.readAsString()) as List) {
        vaults.add(VaultInfo(v['id'] as String, v['name'] as String));
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    await _index.writeAsString(jsonEncode(vaults));
    notifyListeners();
  }

  Future<VaultSession> create(String name, String password) async {
    final kdf = KdfParams.fresh();
    final s = VaultSession._(this, VaultInfo(newId(), name), kdf,
        await deriveKey(password, kdf), VaultData(), null);
    await s._saveLocal();
    vaults.add(s.info);
    await _save();
    return s;
  }

  Future<VaultSession> unlock(VaultInfo info, String password) async {
    final env = Envelope.parse(await fileOf(info.id).readAsString());
    final key = await deriveKey(password, env.kdf);
    final body = open(key, env) as Map<String, dynamic>;
    final sync = body['sync'] as Map<String, dynamic>?;
    return VaultSession._(
      this,
      info,
      env.kdf,
      key,
      VaultData()..load(body['data'] as Map<String, dynamic>),
      sync == null ? null : SyncConfig.fromJson(sync),
    );
  }

  /// Adds a vault that already exists at a sync target to this device.
  Future<VaultSession> join(
      String name, String password, SyncConfig cfg) async {
    final text = await withSyncTarget(cfg, (io) => io.read());
    if (text == null) {
      throw SyncError('No vault file found at ${cfg.summary}');
    }
    final env = Envelope.parse(text);
    final key = await deriveKey(password, env.kdf);
    final body = open(key, env) as Map<String, dynamic>;
    final id = body['vault'] as String;
    if (vaults.any((v) => v.id == id)) {
      throw SyncError('This vault is already on this device');
    }
    final s = VaultSession._(this, VaultInfo(id, name), env.kdf, key,
        VaultData()..load(body['data'] as Map<String, dynamic>), cfg);
    await s._saveLocal();
    vaults.add(s.info);
    await _save();
    return s;
  }

  Future<void> rename(VaultInfo info, String name) async {
    info.name = name;
    await _save();
  }

  /// Removes the vault from this device only; a synced copy is left alone.
  Future<void> remove(VaultInfo info) async {
    vaults.removeWhere((v) => v.id == info.id);
    final f = fileOf(info.id);
    if (await f.exists()) await f.delete();
    await _save();
  }
}

enum SyncState { off, idle, syncing, error, passwordChanged }

/// An unlocked vault.
class VaultSession extends ChangeNotifier {
  VaultSession._(
      this._registry, this.info, this._kdf, this._key, this.data, this._sync) {
    if (_sync != null) {
      syncState = SyncState.idle;
      _startTimer();
    }
  }

  final VaultRegistry _registry;
  final VaultInfo info;
  final VaultData data;
  KdfParams _kdf;
  Uint8List _key;
  SyncConfig? _sync;

  SyncState syncState = SyncState.off;
  String? syncError;
  DateTime? lastSynced;

  Timer? _debounce;
  Timer? _periodic;
  Future<void> _writes = Future.value();
  Future<void>? _running;
  bool _closed = false;

  SyncConfig? get sync => _sync;

  /// Persists edits made to [data] and schedules a sync.
  Future<void> commit() async {
    notifyListeners();
    await _saveLocal();
    if (_sync != null) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), syncNow);
    }
  }

  Future<void> _saveLocal() {
    // Serialized so two saves can never interleave their temp files.
    return _writes = _writes.catchError((_) {}).then((_) async {
      final f = _registry.fileOf(info.id);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        seal(_key, _kdf, {'data': data.toJson(), 'sync': _sync?.toJson()}),
        flush: true,
      );
      await tmp.rename(f.path);
    });
  }

  String _remoteBody() =>
      seal(_key, _kdf, {'vault': info.id, 'data': data.toJson()});

  void _startTimer() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 3), (_) => syncNow());
  }

  /// Merges with the sync target. Failures land in [syncState]/[syncError].
  Future<void> syncNow() {
    if (_sync == null || _closed) return Future.value();
    return _running ??= _syncGuarded().whenComplete(() => _running = null);
  }

  Future<void> _syncGuarded() async {
    syncState = SyncState.syncing;
    notifyListeners();
    try {
      await _syncOnce();
      syncState = SyncState.idle;
      syncError = null;
      lastSynced = DateTime.now();
    } on RemotePasswordChanged {
      syncState = SyncState.passwordChanged;
      syncError = RemotePasswordChanged().toString();
    } catch (e) {
      syncState = SyncState.error;
      syncError = e is WrongPassword
          ? 'The synced file cannot be decrypted with this vault\'s key'
          : e.toString();
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _syncOnce() async {
    await withSyncTarget(_sync!, (io) async {
      final text = await io.read();
      String? remoteJson;
      if (text != null) {
        final env = Envelope.parse(text);
        if (!env.kdf.sameAs(_kdf)) throw RemotePasswordChanged();
        final remote = _openRemote(_key, env);
        remoteJson = jsonEncode(remote.toJson());
        data.merge(remote);
      }
      if (jsonEncode(data.toJson()) != remoteJson) {
        await io.write(_remoteBody());
      }
    });
    // Keeps the merged records and a newly pinned sync host key.
    await _saveLocal();
  }

  VaultData _openRemote(Uint8List key, Envelope env) {
    final body = open(key, env) as Map<String, dynamic>;
    if (body['vault'] != info.id) {
      throw SyncError('A different vault is stored at this sync location');
    }
    return VaultData()..load(body['data'] as Map<String, dynamic>);
  }

  /// Points the vault at a sync target (or turns sync off with null). If a
  /// file is already there it must be this same vault.
  Future<void> setSync(SyncConfig? cfg) async {
    _debounce?.cancel();
    _periodic?.cancel();
    _sync = cfg;
    syncError = null;
    lastSynced = null;
    syncState = cfg == null ? SyncState.off : SyncState.idle;
    await _saveLocal();
    notifyListeners();
    if (cfg != null) {
      _startTimer();
      await syncNow();
    }
  }

  /// Re-encrypts the vault. With sync on, the target must be reachable so the
  /// other devices can learn about the change.
  Future<void> changePassword(String newPassword) async {
    if (_sync != null) await _syncOnce();
    final kdf = KdfParams.fresh();
    final key = await deriveKey(newPassword, kdf);
    _kdf = kdf;
    _key = key;
    await _saveLocal();
    if (_sync != null) {
      await withSyncTarget(_sync!, (io) => io.write(_remoteBody()));
    }
  }

  /// After [RemotePasswordChanged]: take over the new password and merge.
  Future<void> adoptRemotePassword(String password) async {
    final text = await withSyncTarget(_sync!, (io) => io.read());
    if (text == null) throw SyncError('The synced vault file is gone');
    final env = Envelope.parse(text);
    final key = await deriveKey(password, env.kdf);
    final remote = _openRemote(key, env);
    _kdf = env.kdf;
    _key = key;
    data.merge(remote);
    await _saveLocal();
    notifyListeners();
    await syncNow();
  }

  /// Forgets the key. Wait for pending writes first so nothing is lost.
  Future<void> lock() async {
    _closed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    await _writes.catchError((_) {});
    _key = Uint8List(0);
  }
}
