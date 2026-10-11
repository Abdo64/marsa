// Cloud-drive sync against a stand-in for Dropbox and Google Drive that runs
// on this machine: nothing here talks to the real services.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/cloud.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/sync.dart';
import 'package:marsa/core/vault.dart';
import 'package:pointycastle/export.dart';

class FakeCloud {
  late HttpServer server;
  String get url => 'http://127.0.0.1:${server.port}';

  /// What the sign-in page was asked, and what the token endpoint was sent.
  Map<String, String> authorize = {};
  final exchanges = <Map<String, String>>[];
  var refreshes = 0;
  var revoked = false;

  final dropboxFiles = <String, List<int>>{};
  final driveFiles = <String, ({String name, List<int> body})>{};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    final path = req.uri.path;
    void reply(int status, Object? json, [List<int>? raw]) {
      req.response.statusCode = status;
      raw != null
          ? req.response.add(raw)
          : req.response.write(jsonEncode(json));
      req.response.close();
    }

    if (path == '/token') {
      final form = Uri.splitQueryString(utf8.decode(body));
      exchanges.add(form);
      if (form['grant_type'] == 'authorization_code') {
        // PKCE: the verifier must hash to the challenge the browser carried.
        final hash = base64Url
            .encode(
              SHA256Digest().process(
                Uint8List.fromList(ascii.encode(form['code_verifier']!)),
              ),
            )
            .replaceAll('=', '');
        if (form['code'] != 'the-code' || hash != authorize['code_challenge']) {
          return reply(400, {'error': 'invalid_grant'});
        }
        return reply(200, {'refresh_token': 'refresh-1', 'access_token': 'a'});
      }
      if (revoked || form['refresh_token'] != 'refresh-1') {
        return reply(400, {'error': 'invalid_grant'});
      }
      refreshes++;
      return reply(200, {'access_token': 'access-1', 'expires_in': 3600});
    }
    if (req.headers.value('authorization') != 'Bearer access-1') {
      return reply(401, {'error': 'unauthorized'});
    }

    // Dropbox.
    if (path.startsWith('/2/files/')) {
      final arg =
          jsonDecode(req.headers.value('dropbox-api-arg')!)
              as Map<String, dynamic>;
      final name = arg['path'] as String;
      if (path.endsWith('/download')) {
        final file = dropboxFiles[name];
        return file == null
            ? reply(409, {'error_summary': 'path/not_found/..'})
            : reply(200, null, file);
      }
      expect(arg['mode'], 'overwrite');
      dropboxFiles[name] = body;
      return reply(200, {'name': name});
    }

    // Google Drive.
    if (path == '/drive/v3/files') {
      expect(req.uri.queryParameters['spaces'], 'appDataFolder');
      final q = req.uri.queryParameters['q']!;
      return reply(200, {
        'files': [
          for (final e in driveFiles.entries)
            if (q.contains("'${e.value.name}'")) {'id': e.key},
        ],
      });
    }
    if (path.startsWith('/drive/v3/files/')) {
      return reply(200, null, driveFiles[path.split('/').last]!.body);
    }
    if (path == '/upload/drive/v3/files') {
      final parts = utf8.decode(body).split('--marsa-vault-upload');
      final meta =
          jsonDecode(parts[1].split('\r\n\r\n')[1]) as Map<String, dynamic>;
      expect(meta['parents'], ['appDataFolder']);
      final content = parts[2].split('\r\n\r\n')[1];
      driveFiles['id-${driveFiles.length + 1}'] = (
        name: meta['name'] as String,
        body: utf8.encode(content.substring(0, content.length - 2)),
      );
      return reply(200, {'id': 'new'});
    }
    if (path.startsWith('/upload/drive/v3/files/')) {
      final id = path.split('/').last;
      driveFiles[id] = (name: driveFiles[id]!.name, body: body);
      return reply(200, {'id': id});
    }
    reply(404, {'error': 'unexpected $path'});
  }
}

void main() {
  late Directory tmp;
  late FakeCloud fake;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('marsa_cloud');
    fake = FakeCloud();
    Cloud.forgetSessions();
    await fake.start();
    for (final s in Cloud.all) {
      s
        ..clientId = 'marsa-test'
        ..authorizeUrl = '${fake.url}/authorize'
        ..tokenUrl = '${fake.url}/token'
        ..apiUrl = fake.url;
    }
    Cloud.google.clientSecret = 'not-a-secret';
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Cloud.redirectPort = probe.port;
    await probe.close();
  });
  tearDown(() async {
    await fake.server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  // Stands in for the user approving in their browser.
  void browser({String answer = 'code=the-code'}) {
    Cloud.openBrowser = (url) async {
      fake.authorize = Uri.parse(url).queryParameters;
      final client = HttpClient();
      final back = Uri.parse(
        '${fake.authorize['redirect_uri']}?$answer'
        '&state=${fake.authorize['state']}',
      );
      // A browser also asks for things that are not the answer.
      await (await client.getUrl(
        back.replace(path: '/favicon.ico', query: ''),
      )).close();
      await (await client.getUrl(back)).close();
      client.close();
    };
  }

  Future<VaultRegistry> device(String name) async {
    final reg = VaultRegistry(Directory('${tmp.path}/$name'));
    await reg.load();
    return reg;
  }

  test('sign-in hands back a token without Marsa seeing a password', () async {
    browser();
    final token = await Cloud.signIn(Cloud.dropbox).token;
    expect(token, 'refresh-1');
    expect(fake.authorize['client_id'], 'marsa-test');
    expect(fake.authorize['code_challenge_method'], 'S256');
    expect(fake.authorize['token_access_type'], 'offline');
    expect(fake.authorize['redirect_uri'], Cloud.redirectUri);
    expect(fake.exchanges.single.containsKey('client_secret'), isFalse);

    await Cloud.signIn(Cloud.google).token;
    expect(fake.authorize['scope'], contains('drive.appdata'));
    expect(fake.exchanges.last['client_secret'], 'not-a-secret');
  });

  test('a refused or abandoned sign-in fails cleanly', () async {
    browser(answer: 'error=access_denied');
    await expectLater(
      Cloud.signIn(Cloud.dropbox).token,
      throwsA(
        isA<SyncError>().having(
          (e) => e.message,
          'message',
          contains('cancelled'),
        ),
      ),
    );

    Cloud.openBrowser = (_) async {};
    final waiting = Cloud.signIn(Cloud.dropbox);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    waiting.cancel();
    await expectLater(waiting.token, throwsA(isA<SyncError>()));
    // The port is free again for the next attempt.
    browser();
    expect(await Cloud.signIn(Cloud.dropbox).token, 'refresh-1');
  });

  for (final service in Cloud.all) {
    test('two devices converge through ${service.name}', () async {
      SyncConfig target() => SyncConfig(
        type: service.type,
        path: 'Team.marsa',
        token: 'refresh-1',
      );
      final a = await (await device('a')).create('Team', 'password-1');
      a.data.hosts.put(Host(label: 'web', address: '10.0.0.1'));
      await a.setSync(target());
      expect(a.syncState, SyncState.idle, reason: a.syncError);

      final b = await (await device('b')).join('Team', 'password-1', target());
      expect(b.data.hosts.all.single.label, 'web');
      b.data.hosts.put(Host(label: 'db', address: '10.0.0.2'));
      await b.commit();
      await b.syncNow();
      await a.syncNow();
      expect(a.syncState, SyncState.idle, reason: a.syncError);
      expect(a.data.hosts.all.map((h) => h.label).toSet(), {'web', 'db'});

      // One file, encrypted, and it does not carry the sign-in.
      final stored = service == Cloud.dropbox
          ? fake.dropboxFiles.values
          : fake.driveFiles.values.map((f) => f.body);
      expect(stored, hasLength(1));
      final text = utf8.decode(stored.single);
      expect(text, isNot(contains('10.0.0.1')));
      expect(text, isNot(contains('refresh-1')));
      // The local copy does keep it, so the next launch needs no sign-in.
      expect(a.sync!.token, 'refresh-1');
      expect(fake.refreshes, 1, reason: 'the access token is reused');

      await a.lock();
      await b.lock();
    });
  }

  test(
    'withdrawn access is reported, and a missing file is not an error',
    () async {
      final cfg = SyncConfig(
        type: SyncConfig.dropbox,
        path: 'None.marsa',
        token: 'refresh-1',
      );
      expect(await withSyncTarget(cfg, (io) => io.read()), isNull);

      fake.revoked = true;
      final other = SyncConfig(
        type: SyncConfig.google,
        path: 'None.marsa',
        token: 'refresh-2',
      );
      await expectLater(
        withSyncTarget(other, (io) => io.read()),
        throwsA(
          isA<SyncError>().having(
            (e) => e.message,
            'message',
            contains('no longer accepts'),
          ),
        ),
      );
    },
  );

  test('a sync link names the drive and file but carries no sign-in', () {
    final cfg = SyncConfig(
      type: SyncConfig.google,
      path: 'Team.marsa',
      token: 'refresh-1',
    );
    final link = cfg.link!;
    expect(
      utf8.decode(base64Url.decode(link.split(':').last)),
      isNot(contains('refresh-1')),
    );
    final back = SyncConfig.fromLink(link)!;
    expect(back.type, SyncConfig.google);
    expect(back.path, 'Team.marsa');
    expect(back.token, isEmpty);
    expect(cfg.summary, 'Google Drive · Team.marsa');
  });
}
