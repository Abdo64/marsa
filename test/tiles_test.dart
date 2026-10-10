import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/models.dart';
import 'package:marsa/core/vault.dart';
import 'package:marsa/ssh/connector.dart';
import 'package:marsa/ssh/sessions.dart';

class _NoUi implements Prompter {
  @override
  Future<bool> confirmNewHost(String h, String t, String f) async => false;
  @override
  Future<bool> confirmChangedHost(
    String h,
    String t,
    String o,
    String f,
  ) async => false;
  @override
  Future<String?> askSecret(String title, String prompt) async => null;
  @override
  Future<List<String>?> askInteractive(
    String t,
    String i,
    List<SSHUserInfoPrompt> p,
  ) async => null;
}

/// Describes a layout as text: `a|b` side by side, `a/b` stacked.
String shape(Tile? t) => switch (t) {
  null => '-',
  TileLeaf(:final tab) => tab.host.label,
  TileSplit(:final axis, :final first, :final second) =>
    '(${shape(first)}${axis == TileAxis.row ? '|' : '/'}${shape(second)})',
};

void main() {
  late Directory tmp;
  late Workspace ws;
  late VaultSession vault;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('marsa_tiles');
    final reg = VaultRegistry(tmp);
    await reg.load();
    vault = await reg.create('T', 'password-1');
    ws = Workspace(vault, _NoUi());
  });
  tearDown(() async {
    await vault.lock();
    tmp.deleteSync(recursive: true);
  });

  // A tab that is never started, so nothing connects anywhere.
  AppTab add(String name) {
    final tab = TerminalTab(Host(label: name, address: name), vault, ws.ui);
    ws.tabs.add(tab);
    return tab;
  }

  test('tabs replace the focused tile until they are split', () {
    final a = add('a'), b = add('b'), c = add('c');
    ws.focus(a);
    expect(shape(ws.layout), 'a');
    ws.focus(b);
    expect(shape(ws.layout), 'b', reason: 'one tile: a plain tab switch');

    ws.split(b, a, TileSide.left);
    expect(shape(ws.layout), '(a|b)');
    expect(ws.active, a);

    // A tab not on screen takes the focused tile; the split keeps its shape.
    ws.focus(b);
    ws.focus(c);
    expect(shape(ws.layout), '(a|c)');
    expect(ws.active, c);
    // Focusing a tab that is on screen moves nothing.
    ws.focus(a);
    expect(shape(ws.layout), '(a|c)');
  });

  test('splits nest in all four directions and tabs can be moved', () {
    final a = add('a'), b = add('b'), c = add('c'), d = add('d');
    ws.focus(a);
    ws.split(a, b, TileSide.right);
    ws.split(b, c, TileSide.bottom);
    ws.split(a, d, TileSide.top);
    expect(shape(ws.layout), '((d/a)|(b/c))');
    expect(ws.tiled.map((t) => t.host.label), ['d', 'a', 'b', 'c']);

    // Dragging a tiled tab elsewhere moves it rather than duplicating it.
    ws.split(c, d, TileSide.right);
    expect(shape(ws.layout), '(a|(b/(c|d)))');
    // Dropping a tab on itself, or an unknown tab, changes nothing.
    ws.split(a, a, TileSide.left);
    ws.split(a, TerminalTab(Host(label: 'x'), vault, ws.ui), TileSide.left);
    expect(shape(ws.layout), '(a|(b/(c|d)))');
  });

  test('closing and un-tiling collapse the split', () {
    final a = add('a'), b = add('b'), c = add('c');
    ws.focus(a);
    ws.split(a, b, TileSide.right);
    ws.split(b, c, TileSide.bottom);
    (ws.layout! as TileSplit).ratio = .3;

    ws.untile(c);
    expect(shape(ws.layout), '(a|b)');
    expect((ws.layout! as TileSplit).ratio, .3, reason: 'sizes are kept');
    expect(ws.tabs, contains(c), reason: 'still open in the tab strip');
    expect(ws.active, a);

    ws.closeTab(a);
    expect(shape(ws.layout), 'b');
    expect(ws.active, b, reason: 'focus follows to the tile that is left');
    ws.untile(b);
    expect(shape(ws.layout), 'b', reason: 'the last tile cannot be removed');

    // Closing the only tile shows a neighbouring tab instead of nothing.
    ws.closeTab(b);
    expect(shape(ws.layout), 'c');
    expect(ws.active, c);
    ws.closeTab(c);
    expect(ws.layout, isNull);
    expect(ws.active, isNull);
  });

  test('a section page keeps the split for when you come back', () {
    final a = add('a'), b = add('b');
    ws.focus(a);
    ws.split(a, b, TileSide.bottom);
    ws.show(Section.settings);
    expect(ws.active, isNull);
    expect(shape(ws.layout), '(a/b)');
    ws.focus(a);
    expect(shape(ws.layout), '(a/b)');
  });
}
