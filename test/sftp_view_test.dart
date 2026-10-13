import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/sessions.dart';
import 'package:marsa/ui/common.dart';
import 'package:marsa/ui/sftp_view.dart';
import 'package:marsa/ui/theme.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('marsa_sftp'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('folders open on double click and drag between panes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final sep = Platform.pathSeparator;
    final left = '${tmp.path}${sep}left';
    final right = '${tmp.path}${sep}right';
    Directory('$left${sep}docs').createSync(recursive: true);
    File('$left${sep}docs${sep}inside.txt').writeAsStringSync('in');
    File('$left${sep}notes.txt').writeAsStringSync('hello');
    File('$left${sep}move-me.txt').writeAsStringSync('moved');
    Directory(right).createSync();

    final registry = VaultRegistry(Directory('${tmp.path}${sep}vaults'));
    final vault = (await tester.runAsync(() async {
      await registry.load();
      return registry.create('T', 'password-1');
    }))!;
    final ws = Workspace(vault, DialogPrompter());
    final tab = SftpTab(Host(address: 'unused'), vault, ws.ui);
    await tab.show(0, null);
    await tab.show(1, null);

    // Real file I/O only moves on outside the test's fake clock.
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SftpTabView(ws, tab)),
      ),
    );
    await settle();

    Future<void> goTo(int pane, String path) async {
      await tester.enterText(find.byType(TextField).at(pane), path);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle();
    }

    await goTo(0, left);
    await goTo(1, right);
    String path(int pane) => tester
        .widget<TextField>(find.byType(TextField).at(pane))
        .controller!
        .text;
    expect(path(0), left);

    // One click ticks a folder, it does not open it.
    // Double clicks are timed by the wall clock, not the test's.
    Future<void> pause() => tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.tap(find.text('docs'));
    await pause();
    await settle();
    expect(path(0), left);
    expect(find.text('Copy 1 across'), findsOneWidget);
    await tester.tap(find.text('docs'));
    await pause();
    await tester.pump();
    expect(find.text('Copy across'), findsNWidgets(2));

    Future<void> drag(Finder what, Offset to) async {
      final from = tester.getCenter(what);
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 20));
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 6)!);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await g.up();
      await settle();
    }

    // A folder and a file dragged to the other pane are copied there.
    final rightList = tester.getRect(find.text('Empty folder'));
    await drag(find.text('docs'), rightList.center);
    await drag(find.text('notes.txt'), rightList.center);
    await settle();
    expect(File('$right${sep}docs${sep}inside.txt').readAsStringSync(), 'in');
    expect(File('$right${sep}notes.txt').readAsStringSync(), 'hello');
    expect(Directory('$left${sep}docs').existsSync(), isTrue);

    // A file dropped on a folder in its own pane moves into it.
    await drag(
      find.text('move-me.txt'),
      tester.getCenter(find.text('docs').first),
    );
    expect(File('$left${sep}move-me.txt').existsSync(), isFalse);
    expect(
      File('$left${sep}docs${sep}move-me.txt').readAsStringSync(),
      'moved',
    );

    // Two quick clicks open the folder.
    await pause();
    await tester.tap(find.text('docs').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('docs').first);
    await settle();
    expect(path(0), '$left${sep}docs');

    tab.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(vault.lock);
  });
}
