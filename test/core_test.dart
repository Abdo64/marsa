import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/crypto.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/sync.dart';
import 'package:marsa/core/vault.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<VaultRegistry> device(String name) async {
    final r = VaultRegistry(Directory('${tmp.path}/$name'));
    await r.load();
    return r;
  }

  SyncConfig shared() =>
      SyncConfig(type: SyncConfig.folder, path: '${tmp.path}/cloud/team.marsa');

  test('seal/open round-trips and rejects a wrong key or tampering', () {
    final kdf = KdfParams(salt: randomBytes(16), memoryKib: 64, iterations: 1);
    final key = deriveKeySync('correct horse', kdf);
    final text = seal(key, kdf, {'hello': 'عالم'});
    expect(text.contains('hello'), isFalse);
    expect(open(key, Envelope.parse(text)), {'hello': 'عالم'});

    final other = deriveKeySync('wrong', kdf);
    expect(
      () => open(other, Envelope.parse(text)),
      throwsA(isA<WrongPassword>()),
    );

    final env = Envelope.parse(text);
    env.ciphertext[0] ^= 1;
    expect(() => open(key, env), throwsA(isA<WrongPassword>()));
    expect(() => Envelope.parse('{"x":1}'), throwsA(isA<VaultFormatError>()));
  });

  test('table merge is last-write-wins and deletes beat stale copies', () {
    final a = VaultData();
    final b = VaultData();
    final h = Host(label: 'web', address: '10.0.0.1');
    a.hosts.put(h);
    b.load(a.toJson());

    b.hosts[h.id]!.label = 'web-renamed';
    b.hosts.put(b.hosts[h.id]!);
    a.merge(b);
    expect(a.hosts[h.id]!.label, 'web-renamed');

    a.hosts.remove(h.id);
    b.merge(a);
    expect(b.hosts.all, isEmpty);
    // The stale copy must not resurrect the record.
    a.merge(
      VaultData()..load({
        'hosts': {
          'items': [h.toJson()],
        },
      }),
    );
    expect(a.hosts.all, isEmpty);
  });

  test('a vault survives lock/unlock and rejects a wrong password', () async {
    final reg = await device('a');
    final v = await reg.create('Personal', 'pw-one');
    v.data.hosts.put(Host(label: 'db', address: 'db.example.com'));
    v.data.keys.put(SshKey(label: 'k', privateKey: 'SECRET-PEM'));
    await v.commit();
    await v.lock();

    final raw = reg.fileOf(v.info.id).readAsStringSync();
    expect(raw.contains('SECRET-PEM'), isFalse);
    expect(raw.contains('db.example.com'), isFalse);

    final again = await device('a');
    expect(again.vaults.single.name, 'Personal');
    await expectLater(
      again.unlock(again.vaults.single, 'nope'),
      throwsA(isA<WrongPassword>()),
    );
    final u = await again.unlock(again.vaults.single, 'pw-one');
    expect(u.data.hosts.all.single.address, 'db.example.com');
  });

  test('two devices converge through a shared folder', () async {
    final a = await (await device('a')).create('Team', 'pw');
    a.data.hosts.put(Host(label: 'from-a', address: 'a.example.com'));
    await a.setSync(shared());
    expect(a.syncState, SyncState.idle, reason: a.syncError);

    final regB = await device('b');
    await expectLater(
      regB.join('Team', 'bad', shared()),
      throwsA(isA<WrongPassword>()),
    );
    final b = await regB.join('Team', 'pw', shared());
    expect(b.data.hosts.all.single.label, 'from-a');

    b.data.snippets.put(Snippet(label: 'up', command: 'uptime'));
    b.data.hosts.remove(b.data.hosts.all.single.id);
    await b.syncNow();
    await a.syncNow();
    expect(a.data.hosts.all, isEmpty);
    expect(a.data.snippets.all.single.command, 'uptime');

    // The sync target never sees plaintext or the local sync settings.
    final cloud = File(shared().path).readAsStringSync();
    expect(cloud.contains('uptime'), isFalse);
    await a.lock();
    await b.lock();
  });

  test('a password change propagates to the other device', () async {
    final a = await (await device('a')).create('Team', 'old');
    await a.setSync(shared());
    final regB = await device('b');
    final b = await regB.join('Team', 'old', shared());

    await a.changePassword('new');
    a.data.hosts.put(Host(label: 'after', address: 'x'));
    await a.syncNow();

    await b.syncNow();
    expect(b.syncState, SyncState.passwordChanged);
    await expectLater(
      b.adoptRemotePassword('old'),
      throwsA(isA<WrongPassword>()),
    );
    await b.adoptRemotePassword('new');
    expect(b.syncState, SyncState.idle, reason: b.syncError);
    expect(b.data.hosts.all.single.label, 'after');
    await b.lock();

    final u = await regB.unlock(regB.vaults.single, 'new');
    expect(u.data.hosts.all.single.label, 'after');
    await a.lock();
    await u.lock();
  });

  test(
    'a remembered vault opens without the password until it is forgotten',
    () async {
      final store = _MemoryKeyStore();
      Future<VaultRegistry> boot() async {
        final r = VaultRegistry(Directory('${tmp.path}/a'), keyStore: store);
        await r.load();
        return r;
      }

      var reg = await boot();
      final v = await reg.create('Personal', 'pw-one');
      v.data.hosts.put(Host(label: 'db', address: 'db.example.com'));
      await v.commit();
      expect(await reg.unlockRemembered(v.info), isNull);
      await reg.remember(v);
      await v.lock();
      // The stored secret is the vault key, never the password itself.
      expect(store.keys.values.single.length, 32);

      reg = await boot();
      expect(reg.lastId, reg.vaults.single.id);
      expect(reg.vaults.single.remembered, isTrue);
      final again = (await reg.unlockRemembered(reg.vaults.single))!;
      expect(again.data.hosts.all.single.label, 'db');

      // Changing the password keeps the device remembered with the new key.
      await again.changePassword('pw-two');
      await again.lock();
      reg = await boot();
      final third = (await reg.unlockRemembered(reg.vaults.single))!;
      await third.lock();
      await expectLater(
        reg.unlock(reg.vaults.single, 'pw-one'),
        throwsA(isA<WrongPassword>()),
      );

      // A stored key that no longer fits is dropped, not trusted.
      store.keys[reg.vaults.single.id] = randomBytes(32);
      expect(await reg.unlockRemembered(reg.vaults.single), isNull);
      expect(reg.vaults.single.remembered, isFalse);
      expect(store.keys, isEmpty);

      // An unreadable store asks for the password but keeps the setting.
      final byPassword = await reg.unlock(reg.vaults.single, 'pw-two');
      await reg.remember(byPassword);
      store.broken = true;
      expect(await reg.unlockRemembered(reg.vaults.single), isNull);
      expect(reg.vaults.single.remembered, isTrue);
      store.broken = false;

      await reg.forget(reg.vaults.single);
      expect(store.keys, isEmpty);
      expect(await reg.unlockRemembered(reg.vaults.single), isNull);
      await byPassword.lock();
    },
  );

  test('reads the vault list written by the first release', () async {
    final dir = Directory('${tmp.path}/old')..createSync();
    File(
      '${dir.path}/vaults.json',
    ).writeAsStringSync('[{"id":"abc","name":"Personal"}]');
    final reg = VaultRegistry(dir);
    await reg.load();
    expect(reg.vaults.single.name, 'Personal');
    expect(reg.vaults.single.remembered, isFalse);
    expect(reg.lastId, isNull);
  });

  test('a different vault at the sync location is refused', () async {
    final a = await (await device('a')).create('One', 'pw');
    await a.setSync(shared());
    final other = await (await device('c')).create('Two', 'pw');
    await other.setSync(shared());
    expect(other.syncState, isNot(SyncState.idle));
    await a.lock();
    await other.lock();
  });
}

class _MemoryKeyStore implements KeyStore {
  final keys = <String, Uint8List>{};
  bool broken = false;

  @override
  Future<Uint8List?> read(String id) async {
    if (broken) throw StateError('keychain locked');
    return keys[id];
  }

  @override
  Future<void> write(String id, Uint8List key) async =>
      keys[id] = Uint8List.fromList(key);

  @override
  Future<void> delete(String id) async => keys.remove(id);
}
