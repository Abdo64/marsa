// Drives the real app, on a real desktop window, through the journey a new
// user takes: create a vault, add a host, open a terminal and SFTP on it,
// turn on "remember", lock, and get back in without the password.
//
//     flutter test integration_test -d macos
//
// Both tests live in this one file because Flutter can only run a single
// integration test file per launch on desktop.
//
// Like the SSH tests it talks to a throwaway local sshd, and it keeps its
// vault in a temp folder, so your own vaults and ~/.ssh are not involved.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:marsa/core/crypto.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/main.dart';
import 'package:marsa/platform/keystore.dart';
import 'package:marsa/ssh/device_keys.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ui/shell.dart';
import 'package:marsa/ui/theme.dart';

const _sshd = '/usr/sbin/sshd';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a vault key round-trips through the OS credential store', (
    tester,
  ) async {
    final store = SystemKeyStore();
    final id = 'integration-test-${newId()}';
    final key = randomBytes(32);
    try {
      expect(await store.read(id), isNull);
      await store.write(id, key);
      expect(await store.read(id), key);
      final replaced = randomBytes(32);
      await store.write(id, replaced);
      expect(await store.read(id), replaced);
    } finally {
      await store.delete(id);
    }
    expect(await store.read(id), isNull);
  });

  testWidgets('new user journey', (tester) async {
    final tmp = await Directory.systemTemp.createTemp('marsa_flow');
    final user = Platform.environment['USER']!;
    final probe = await ServerSocket.bind('127.0.0.1', 0);
    final port = probe.port;
    await probe.close();

    // A server, and a "device key" it accepts.
    final home = Directory('${tmp.path}/dot-ssh')..createSync();
    Future<void> keygen(String path) => Process.run('ssh-keygen', [
      '-q', '-t', 'ed25519', '-N', '', '-f', path, //
    ]);
    await keygen('${tmp.path}/hostkey');
    await keygen('${home.path}/id_ed25519');
    File('${home.path}/id_ed25519.pub').copySync('${tmp.path}/authorized');
    final server = await Process.start(_sshd, [
      '-D', '-e', '-f', '/dev/null', '-p', '$port', //
      '-o', 'ListenAddress=127.0.0.1',
      '-o', 'HostKey=${tmp.path}/hostkey',
      '-o', 'AuthorizedKeysFile=${tmp.path}/authorized',
      '-o', 'PidFile=${tmp.path}/sshd.pid',
      '-o', 'UsePAM=no',
      '-o', 'StrictModes=no',
      '-o', 'Subsystem=sftp internal-sftp',
    ]);
    server.stderr.drain<void>();
    DeviceKeys.directory = home;

    final registry = VaultRegistry(
      Directory('${tmp.path}/vaults'),
      keyStore: SystemKeyStore(),
    );
    await registry.load();
    final settings = AppSettings(File('${tmp.path}/settings.json'));

    Future<void> until(bool Function() done, String what) async {
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (done()) return;
      }
      fail('Timed out waiting for $what');
    }

    bool shown(String text) => find.text(text).evaluate().isNotEmpty;
    Finder inDialog(Type t) =>
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(t));

    try {
      await tester.pumpWidget(MarsaApp(registry: registry, settings: settings));
      await tester.pumpAndSettle();

      // Create a vault.
      await tester.tap(find.text('New vault'));
      await tester.pumpAndSettle();
      await tester.enterText(inDialog(TextField).at(0), 'Flow');
      await tester.enterText(inDialog(TextField).at(1), 'correct-horse');
      await tester.enterText(inDialog(TextField).at(2), 'correct-horse');
      await tester.tap(find.text('Create'));
      await until(() => shown('No hosts yet'), 'the empty hosts screen');

      // Add a host; device keys are preselected because this device has some.
      await tester.tap(find.text('New host').first);
      await tester.pumpAndSettle();
      expect(find.text('This device\'s SSH keys (~/.ssh)'), findsOneWidget);
      await tester.enterText(inDialog(TextField).at(0), 'local box');
      await tester.enterText(inDialog(TextField).at(1), '127.0.0.1');
      await tester.enterText(inDialog(TextField).at(2), '$port');
      await tester.enterText(inDialog(TextField).at(5), user);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('local box'), findsOneWidget);

      // Connect: first contact asks to trust the server's key.
      await tester.tap(find.text('local box'));
      await until(() => shown('Trust this server?'), 'the host key prompt');
      await tester.tap(find.text('Trust and connect'));
      final ws = tester.widget<AppShell>(find.byType(AppShell)).workspace;
      final term = ws.tabs.single as TerminalTab;
      await until(() => term.state != TabState.connecting, 'the shell');
      expect(term.state, TabState.connected, reason: term.error);

      String screen() => [
        for (var i = 0; i < term.terminal.buffer.lines.length; i++)
          term.terminal.buffer.lines[i].toString(),
      ].join('\n');
      term.send('echo flow-\$((40+2))\r');
      await until(() => screen().contains('flow-42'), 'command output');

      // SFTP on the same server, from the tab strip.
      await tester.tap(find.byTooltip('Browse this server\'s files (SFTP)'));
      await until(() => ws.tabs.length == 2, 'the SFTP tab');
      final sftp = ws.tabs.last as SftpTab;
      await until(() => sftp.state != TabState.connecting, 'the SFTP session');
      expect(sftp.state, TabState.connected, reason: sftp.error);
      await until(() => shown('This computer'), 'the file panes');
      expect(find.text('NAME'), findsNWidgets(2));
      // The key was pinned without a second prompt.
      expect(ws.vault.data.knownHosts['127.0.0.1:$port'], isNotNull);

      // Remember on this device, through the real OS credential store.
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await until(() => ws.vault.info.remembered, 'the key to be stored');

      // Lock (confirming, since sessions are open), then return passwordless.
      await tester.tap(find.text('Lock vault'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lock'));
      await until(() => shown('Unlock'), 'the unlock screen');
      expect(find.text('Remembered on this device'), findsWidgets);
      await tester.tap(find.text('Unlock'));
      await until(() => shown('local box'), 'the vault to reopen');
    } finally {
      for (final v in registry.vaults.toList()) {
        await registry.forget(v);
      }
      server.kill();
      await tmp.delete(recursive: true);
    }
  }, skip: !File(_sshd).existsSync());
}
