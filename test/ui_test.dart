import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/keys.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ssh/ssh_config.dart';
import 'package:marsa/ui/common.dart';
import 'package:marsa/ui/shell.dart';
import 'package:marsa/ui/theme.dart';
import 'package:marsa/ui/unlock.dart';

void main() {
  test('ssh config parsing keeps concrete hosts and skips patterns', () {
    final entries = parseSshConfig('''
# comment
Host *
  User everyone
Host web db-1
  HostName 10.0.0.5
  User deploy
  Port 2222
  IdentityFile "~/.ssh/id_ed25519"
Host inner
  HostName=inner.lan
  ProxyJump web
Match host foo
  User nope
''');
    expect(entries.map((e) => e.alias), ['web', 'db-1', 'inner']);
    expect(entries[0].hostName, '10.0.0.5');
    expect(entries[1].user, 'deploy');
    expect(entries[0].port, 2222);
    expect(entries[0].identityFile, '~/.ssh/id_ed25519');
    expect(entries[2].hostName, 'inner.lan');
    expect(entries[2].proxyJump, 'web');
    expect(entries[2].user, isNull);
  });

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_ui'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pumpShell(WidgetTester tester, Size size, ThemeMode mode) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final registry = VaultRegistry(tmp);
    final vault = (await tester.runAsync(() async {
      await registry.load();
      return registry.create('Team vault', 'password-1');
    }))!;
    final key = generateEd25519('deploy key');
    vault.data.keys.put(key);
    final ident = Identity(label: 'Ops', username: 'ops', keyId: key.id);
    vault.data.identities.put(ident);
    final host = Host(
      label: 'A very long production web server label that must ellipsize',
      address: 'web-01.example.internal',
      port: 2222,
      username: 'deploy',
      group: 'Production',
      tags: ['web', 'eu'],
      keyId: key.id,
    );
    vault.data.hosts
      ..put(host)
      ..put(Host(address: '10.0.0.9', identityId: ident.id));
    vault.data.snippets.put(Snippet(label: 'Disk', command: 'df -h\nfree -m'));
    vault.data.forwards.put(
      PortForward(
        label: 'Postgres',
        hostId: host.id,
        bindPort: 5433,
        destPort: 5432,
      ),
    );
    vault.data.knownHosts.put(
      KnownHost(
        id: 'web-01.example.internal:2222',
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG',
      ),
    );

    final settings = AppSettings(File('${tmp.path}/settings.json'))
      ..themeMode = mode;
    final ws = Workspace(vault, DialogPrompter());
    await tester.pumpWidget(
      MaterialApp(
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
    expect(find.textContaining('deploy@web-01'), findsOneWidget);
    expect(find.text('Production'), findsOneWidget);

    await tester.tap(find.text('New host'));
    await tester.pumpAndSettle();
    expect(find.text('Connect through (jump host)'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    for (final s in Section.values) {
      ws.show(s);
      await tester.pumpAndSettle();
    }
    expect(find.text('Remember on this device'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Open-source licenses'),
      200,
      scrollable: find.byType(Scrollable).last,
    );

    ws.show(Section.forwards);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dynamic (SOCKS)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Tabs are shown without connecting anywhere.
    final term = TerminalTab(host, vault, ws.ui);
    term.terminal.write('hello \x1b[32mgreen\x1b[0m\r\n');
    final sftp = SftpTab(host, vault, ws.ui)
      ..state = TabState.closed
      ..error = 'Cannot reach web-01.example.internal:2222';
    ws.tabs.addAll([term, sftp]);
    ws.focus(term);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('connecting'), findsOneWidget);
    ws.focus(sftp);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Reconnect'), findsWidgets);
    ws.closeTab(sftp);
    ws.closeTab(term);
    await tester.pumpAndSettle();
    expect(ws.active, isNull);
    await tester.runAsync(vault.lock);
  }

  testWidgets('every screen lays out on a wide dark window', (t) async {
    await pumpShell(t, const Size(1440, 900), ThemeMode.dark);
  });

  testWidgets('every screen lays out on a narrow light window', (t) async {
    await pumpShell(t, const Size(520, 720), ThemeMode.light);
  });

  testWidgets('unlock screen: first run and with vaults', (tester) async {
    final registry = VaultRegistry(tmp);
    await tester.runAsync(registry.load);
    await tester.pumpWidget(
      MaterialApp(
        home: UnlockPage(registry: registry, onUnlocked: (_) {}),
      ),
    );
    expect(find.text('New vault'), findsOneWidget);
    expect(find.text('Unlock'), findsNothing);
    await tester.tap(find.text('New vault'));
    await tester.pumpAndSettle();
    expect(find.text('Repeat master password'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final v = await tester.runAsync(
      () => registry.create('Personal', 'pw-12345'),
    );
    await tester.runAsync(v!.lock);
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        home: UnlockPage(registry: registry, onUnlocked: (_) {}),
      ),
    );
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.text('Remember on this device'), findsOneWidget);
    expect(find.text('Master password'), findsOneWidget);
  });
}
