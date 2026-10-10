import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../core/models.dart';
import '../core/vault.dart';
import 'connector.dart';
import 'device_keys.dart';
import 'files.dart';
import 'forwarding.dart';

enum TabState { connecting, connected, closed }

abstract class AppTab extends ChangeNotifier {
  AppTab(this.host);
  final Host host;
  TabState state = TabState.connecting;
  String? error;
  bool _disposed = false;

  Future<void> start();
  void close();

  void _set(TabState s, [String? err]) {
    if (_disposed) return;
    state = s;
    error = err;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }
}

class TerminalTab extends AppTab {
  TerminalTab(super.host, this._vault, this._ui) {
    terminal.onOutput = (data) => _shell?.write(utf8.encode(data));
    terminal.onResize = (w, h, pw, ph) => _shell?.resizeTerminal(w, h, pw, ph);
  }

  final VaultSession _vault;
  final Prompter _ui;
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();

  /// Keyboard focus of this tab's terminal view.
  final focusNode = FocusNode();
  Connection? _conn;
  SSHSession? _shell;

  @override
  Future<void> start() async {
    close();
    _set(TabState.connecting);
    terminal.write('Connecting to ${host.address}:${host.port}…\r\n');
    try {
      final conn = _conn = await connect(_vault, host, _ui);
      final shell = _shell = await conn.client.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );
      if (_disposed) return close();
      // Clear the "Connecting…" line so the remote banner starts clean.
      terminal.write('\x1b[2J\x1b[H');
      _set(TabState.connected);
      const decoder = Utf8Decoder(allowMalformed: true);
      shell.stdout.cast<List<int>>().transform(decoder).listen(terminal.write);
      shell.stderr.cast<List<int>>().transform(decoder).listen(terminal.write);
      unawaited(
        shell.done.catchError((_) {}).whenComplete(() {
          if (_shell != shell) return;
          close();
          terminal.write('\r\n\x1b[2m[session closed]\x1b[0m\r\n');
          _set(TabState.closed);
        }),
      );
    } catch (e) {
      close();
      terminal.write('\x1b[31m$e\x1b[0m\r\n');
      _set(TabState.closed, e.toString());
    }
  }

  /// Types [text] into the session, as if pasted.
  void send(String text) =>
      _shell?.write(Uint8List.fromList(utf8.encode(text)));

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  @override
  void close() {
    _shell = null;
    _conn?.close();
    _conn = null;
  }
}

/// One pane of an SFTP tab: this computer, or a server it is connected to.
class SftpSide {
  /// Null means this computer.
  Host? host;
  FileBackend? files;
  TabState state = TabState.connecting;
  String? error;
  Connection? _conn;

  void _drop() {
    files = null;
    _conn?.close();
    _conn = null;
  }
}

/// A two-pane file view. Either pane can show this computer or any saved
/// host, so files can go computer to server or straight from one server to
/// another (relayed through this app; the servers never talk to each other).
class SftpTab extends AppTab {
  SftpTab(super.host, this._vault, this._ui, {FileBackend? local})
    : _local = local ?? LocalFiles();

  final VaultSession _vault;
  final Prompter _ui;
  final FileBackend _local;

  /// Left and right pane. Starts as this computer and the tab's host.
  final sides = [SftpSide(), SftpSide()];

  /// The second pane's files, which is the tab's own host unless changed.
  FileBackend? get remote => sides[1].files;
  set remote(FileBackend? files) => sides[1].files = files;

  @override
  Future<void> start() async {
    if (sides[1].host == null && sides[1].files == null) sides[1].host = host;
    await Future.wait([for (var i = 0; i < 2; i++) show(i, sides[i].host)]);
  }

  /// Points pane [index] at [target] (null for this computer) and connects.
  Future<void> show(int index, Host? target) async {
    final side = sides[index];
    side._drop();
    side
      ..host = target
      ..error = null
      ..state = TabState.connecting;
    _refresh();
    if (target == null) {
      side
        ..files = _local
        ..state = TabState.connected;
      return _refresh();
    }
    try {
      final conn = side._conn = await connect(_vault, target, _ui);
      final files = RemoteFiles(await conn.client.sftp(), target.title);
      // Closed, or switched to something else, while we were connecting.
      if (_disposed || side._conn != conn) return conn.close();
      side
        ..files = files
        ..state = TabState.connected;
      unawaited(
        conn.client.done.catchError((_) {}).whenComplete(() {
          if (side._conn != conn) return;
          side._drop();
          side
            ..state = TabState.closed
            ..error = 'Connection closed';
          _refresh();
        }),
      );
    } catch (e) {
      side._drop();
      side
        ..state = TabState.closed
        ..error = e.toString();
    }
    _refresh();
  }

  // The tab's own status is its least healthy pane.
  void _refresh() {
    final states = sides.map((s) => s.state);
    final bad = sides.where((s) => s.state == TabState.closed).firstOrNull;
    _set(
      bad != null
          ? TabState.closed
          : states.contains(TabState.connecting)
          ? TabState.connecting
          : TabState.connected,
      bad?.error,
    );
  }

  @override
  void close() {
    for (final s in sides) {
      s._drop();
    }
  }
}

enum Section { hosts, keychain, forwards, snippets, knownHosts, settings }

/// Everything that lives while a vault is unlocked: open tabs, running
/// forwards, transfers and which view is showing.
class Workspace extends ChangeNotifier {
  Workspace(this.vault, this.ui) : forwards = ForwardManager(vault, ui);

  final VaultSession vault;
  final Prompter ui;
  final ForwardManager forwards;
  final transfers = TransferManager();

  /// The "this computer" side of SFTP views.
  FileBackend localFiles = LocalFiles();
  final List<AppTab> tabs = [];

  Section section = Section.hosts;
  AppTab? active;

  void show(Section s) {
    section = s;
    active = null;
    notifyListeners();
  }

  void focus(AppTab tab) {
    active = tab;
    notifyListeners();
  }

  void _open(AppTab tab) {
    tabs.add(tab);
    active = tab;
    notifyListeners();
    tab.start();
  }

  void openTerminal(Host h) => _open(TerminalTab(h, vault, ui));
  void openSftp(Host h) => _open(SftpTab(h, vault, ui, local: localFiles));

  void closeTab(AppTab tab) {
    final i = tabs.indexOf(tab);
    if (i < 0) return;
    tabs.removeAt(i);
    if (active == tab) {
      active = tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)];
    }
    tab.dispose();
    notifyListeners();
  }

  Future<void> shutdown() async {
    for (final t in tabs.toList()) {
      t.dispose();
    }
    tabs.clear();
    await forwards.stopAll();
    DeviceKeys.lock();
    await vault.lock();
  }
}
