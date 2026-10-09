import 'dart:io';

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
    expect(() => open(other, Envelope.parse(text)),
        throwsA(isA<WrongPassword>()));

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
    a.merge(VaultData()..load({
      'hosts': {
        'items': [h.toJson()]
      }
    }));
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
    await expectLater(again.unlock(again.vaults.single, 'nope'),
        throwsA(isA<WrongPassword>()));
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
        regB.join('Team', 'bad', shared()), throwsA(isA<WrongPassword>()));
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
        b.adoptRemotePassword('old'), throwsA(isA<WrongPassword>()));
    await b.adoptRemotePassword('new');
    expect(b.syncState, SyncState.idle, reason: b.syncError);
    expect(b.data.hosts.all.single.label, 'after');
    await b.lock();

    final u = await regB.unlock(regB.vaults.single, 'new');
    expect(u.data.hosts.all.single.label, 'after');
    await a.lock();
    await u.lock();
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
