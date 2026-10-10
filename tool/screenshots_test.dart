// Renders the app's screens to PNG files with demo data, for the README and
// for reviewing design changes without clicking through the app:
//
//     flutter test --update-goldens tool/screenshots_test.dart
//
// Output goes to docs/screenshots/. Not part of the normal test run.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/files.dart';
import 'package:marsa/ssh/keys.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ui/common.dart';
import 'package:marsa/ui/shell.dart';
import 'package:marsa/ui/theme.dart';
import 'package:marsa/ui/unlock.dart';

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) {
      loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
  }
  await loader.load();
}

class _DemoFiles implements FileBackend {
  _DemoFiles(this.label, this._home, this._entries);
  @override
  final String label;
  final String _home;
  final List<FileEntry> _entries;

  @override
  Future<String> home() async => _home;
  @override
  String join(String dir, String name) => '$dir/$name';
  @override
  String parent(String path) => path;
  @override
  Future<List<FileEntry>> list(String path) async => _entries;
  @override
  Future<void> mkdir(String path) async {}
  @override
  Future<void> rename(String from, String to) async {}
  @override
  Future<void> delete(String path, {required bool isDir}) async {}
  @override
  Stream<Uint8List> read(String path) => const Stream.empty();
  @override
  Future<void> write(String path, Stream<Uint8List> data) async {}
  @override
  Future<void> chmod(String path, int mode) async {}
}

FileEntry _e(String name, {bool dir = false, int size = 0, int mode = 0x1A4}) =>
    FileEntry(
      name,
      dir,
      size,
      DateTime(2026, 10, 3, 14, 20),
      dir ? 0x1ED : mode,
    );

void main() {
  late Directory tmp;

  setUpAll(() async {
    final fonts =
        '${Platform.environment['FLUTTER_ROOT']}'
        '/bin/cache/artifacts/material_fonts';
    await _font('Roboto', [
      '$fonts/Roboto-Regular.ttf',
      '$fonts/Roboto-Medium.ttf',
      '$fonts/Roboto-Bold.ttf',
    ]);
    await _font('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
    await _font('Menlo', ['/System/Library/Fonts/Monaco.ttf']);
    await _font('monospace', ['/System/Library/Fonts/Monaco.ttf']);
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_shots'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> shot(String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../docs/screenshots/$name.png'),
  );

  Future<void> tour(WidgetTester tester, ThemeMode mode, String suffix) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final registry = VaultRegistry(tmp);
    final vault = (await tester.runAsync(() async {
      await registry.load();
      return registry.create('Personal', 'password-1');
    }))!;
    final d = vault.data;
    final key = generateEd25519('laptop');
    d.keys
      ..put(key)
      ..put(generateEd25519('deploy-bot'));
    final ops = Identity(label: 'Ops team', username: 'ops', keyId: key.id);
    d.identities.put(ops);
    Host h(
      String label,
      String addr,
      String group, {
      List<String> tags = const [],
      String user = 'root',
      int port = 22,
    }) {
      final x = Host(
        label: label,
        address: addr,
        group: group,
        tags: tags,
        username: user,
        port: port,
        useDeviceKeys: true,
      );
      d.hosts.put(x);
      return x;
    }

    final web = h('web-01', '203.0.113.10', 'Production', tags: ['web', 'eu']);
    h('web-02', '203.0.113.11', 'Production', tags: ['web', 'eu']);
    h(
      'db-primary',
      '203.0.113.20',
      'Production',
      tags: ['postgres'],
      user: 'deploy',
    );
    h('cache', '203.0.113.21', 'Production', user: 'deploy');
    h('staging', 'staging.example.com', 'Staging', user: 'deploy', port: 2222);
    h('ci-runner', '198.51.100.7', 'Staging');
    h('home-nas', '192.168.1.40', '', user: 'adnan');
    d.snippets
      ..put(Snippet(label: 'Disk usage', command: 'df -h'))
      ..put(
        Snippet(
          label: 'Restart nginx',
          command: 'sudo systemctl restart nginx',
        ),
      )
      ..put(
        Snippet(label: 'Tail app log', command: 'journalctl -u app -f -n 100'),
      );
    d.forwards
      ..put(
        PortForward(
          label: 'Postgres',
          hostId: web.id,
          bindPort: 5433,
          destPort: 5432,
        ),
      )
      ..put(
        PortForward(
          label: 'SOCKS proxy',
          kind: ForwardKind.dynamic,
          hostId: web.id,
          bindPort: 1080,
        ),
      );
    d.knownHosts.put(
      KnownHost(
        id: '203.0.113.10:22',
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:Zk3nC0uW8mXr5Qe1Yb7vT2pL9sHd4gFa6jKoNi0wRxE',
      ),
    );

    final settings = AppSettings(File('${tmp.path}/settings.json'))
      ..themeMode = mode;
    final ws = Workspace(vault, DialogPrompter())
      ..localFiles = _DemoFiles('This computer', '/Users/adnan/Projects/site', [
        _e('assets', dir: true),
        _e('src', dir: true),
        _e('README.md', size: 4212),
        _e('deploy.sh', size: 912, mode: 0x1ED),
        _e('package.json', size: 1650),
      ]);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: AppShell(
          workspace: ws,
          registry: registry,
          settings: settings,
          onLock: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await shot('hosts-$suffix');

    await tester.tap(find.text('New host'));
    await tester.pumpAndSettle();
    await shot('host-dialog-$suffix');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    for (final s in [
      Section.keychain,
      Section.forwards,
      Section.snippets,
      Section.knownHosts,
      Section.settings,
    ]) {
      ws.show(s);
      await tester.pumpAndSettle();
      await shot('${s.name}-$suffix');
    }

    final term = TerminalTab(web, vault, ws.ui)..state = TabState.connected;
    term.terminal.write(
      'Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)\r\n\r\n'
      '  System load:  0.08              Processes:             132\r\n'
      '  Usage of /:   41.2% of 77GB     Users logged in:       1\r\n'
      '  Memory usage: 23%               IPv4 address for eth0: 203.0.113.10\r\n\r\n'
      'Last login: Fri Oct  9 21:14:03 2026 from 198.51.100.24\r\n'
      '\x1b[1;32mroot@web-01\x1b[0m:\x1b[1;34m~\x1b[0m# systemctl status nginx\r\n'
      '\x1b[1;32m●\x1b[0m nginx.service - A high performance web server\r\n'
      '     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)\r\n'
      '     Active: \x1b[1;32mactive (running)\x1b[0m since Mon 2026-10-05 09:12:44 UTC\r\n'
      '   Main PID: 812 (nginx)\r\n'
      '      Tasks: 5 (limit: 9484)\r\n'
      '\x1b[1;32mroot@web-01\x1b[0m:\x1b[1;34m~\x1b[0m# ',
    );
    final sftp = SftpTab(web, vault, ws.ui)
      ..state = TabState.connected
      ..remote = _DemoFiles('web-01', '/var/www/site', [
        _e('releases', dir: true),
        _e('shared', dir: true),
        _e('.env', size: 388, mode: 0x180),
        _e('index.html', size: 10844),
        _e('robots.txt', size: 67),
      ]);
    ws.tabs.addAll([term, sftp]);
    ws.focus(term);
    await tester.pump(const Duration(milliseconds: 300));
    await shot('terminal-$suffix');
    ws.focus(sftp);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await shot('sftp-$suffix');
    ws.closeTab(sftp);
    ws.closeTab(term);
    await tester.pumpAndSettle();
    await tester.runAsync(vault.lock);
  }

  testWidgets('dark', (t) => tour(t, ThemeMode.dark, 'dark'));
  testWidgets('light', (t) => tour(t, ThemeMode.light, 'light'));

  testWidgets('unlock', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final registry = VaultRegistry(tmp);
    await tester.runAsync(() async {
      await registry.load();
      await (await registry.create('Personal', 'password-1')).lock();
      await (await registry.create('Team', 'password-1')).lock();
    });
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: UnlockPage(registry: registry, onUnlocked: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    await shot('unlock-dark');
  });
}
