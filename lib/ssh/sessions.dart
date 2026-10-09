import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
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
  void close() {
    _shell = null;
    _conn?.close();
    _conn = null;
  }
}

class SftpTab extends AppTab {
  SftpTab(super.host, this._vault, this._ui);

  final VaultSession _vault;
  final Prompter _ui;
  Connection? _conn;
  RemoteFiles? remote;

  @override
  Future<void> start() async {
    close();
    _set(TabState.connecting);
    try {
      final conn = _conn = await connect(_vault, host, _ui);
      remote = RemoteFiles(await conn.client.sftp(), host.title);
      if (_disposed) return close();
      _set(TabState.connected);
      unawaited(
        conn.client.done.catchError((_) {}).whenComplete(() {
          if (_conn != conn) return;
          close();
          _set(TabState.closed, 'Connection closed');
        }),
      );
    } catch (e) {
      close();
      _set(TabState.closed, e.toString());
    }
  }

  @override
  void close() {
    remote = null;
    _conn?.close();
    _conn = null;
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
  void openSftp(Host h) => _open(SftpTab(h, vault, ui));

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
