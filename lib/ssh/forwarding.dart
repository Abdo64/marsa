import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/vault.dart';
import 'connector.dart';

class RunningForward {
  bool starting = true;
  String? error;
  Connection? _conn;
  final List<Future<void> Function()> _closers = [];
}

/// Runs the port-forwarding rules the user switched on.
class ForwardManager extends ChangeNotifier {
  ForwardManager(this.vault, this.ui);

  final VaultSession vault;
  final Prompter ui;
  final Map<String, RunningForward> _running = {};

  RunningForward? stateOf(String id) => _running[id];
  bool isOn(String id) => _running[id] != null && _running[id]!.error == null;

  Future<void> start(PortForward rule) async {
    await stop(rule.id);
    final run = _running[rule.id] = RunningForward();
    notifyListeners();
    try {
      final host = vault.data.hosts[rule.hostId];
      if (host == null) throw ConnectError('The rule\'s host no longer exists');
      final conn = run._conn = await connect(vault, host, ui);
      await _open(rule, conn.client, run);
      // Stopped while we were still connecting.
      if (_running[rule.id] != run) return _close(run);
      unawaited(
        conn.client.done.catchError((_) {}).whenComplete(() {
          if (_running[rule.id] == run && run.error == null) {
            run.error = 'Connection closed';
            _close(run);
            notifyListeners();
          }
        }),
      );
    } catch (e) {
      run.error = e.toString();
      await _close(run);
    }
    run.starting = false;
    notifyListeners();
  }

  Future<void> _open(
    PortForward r,
    SSHClient client,
    RunningForward run,
  ) async {
    switch (r.kind) {
      case ForwardKind.local:
        final server = await ServerSocket.bind(r.bindHost, r.bindPort);
        run._closers.add(() async => server.close());
        server.listen((socket) async {
          try {
            final ch = await client.forwardLocal(r.destHost, r.destPort);
            _pipe(socket, ch);
          } catch (_) {
            socket.destroy();
          }
        });
      case ForwardKind.remote:
        final fwd = await client.forwardRemote(
          host: r.bindHost,
          port: r.bindPort,
        );
        if (fwd == null) {
          throw ConnectError(
            'The server refused to listen on ${r.bindHost}:${r.bindPort}',
          );
        }
        run._closers.add(() async => fwd.close());
        fwd.connections.listen((ch) async {
          try {
            _pipe(await Socket.connect(r.destHost, r.destPort), ch);
          } catch (_) {
            ch.destroy();
          }
        });
      case ForwardKind.dynamic:
        final socks = await client.forwardDynamic(
          bindHost: r.bindHost,
          bindPort: r.bindPort,
        );
        run._closers.add(socks.close);
    }
  }

  void _pipe(Socket socket, SSHForwardChannel ch) {
    ch.stream.listen(
      socket.add,
      onDone: socket.destroy,
      onError: (_) => socket.destroy(),
    );
    socket.listen(
      ch.sink.add,
      onDone: ch.close,
      onError: (_) => ch.destroy(),
      cancelOnError: true,
    );
  }

  Future<void> _close(RunningForward run) async {
    for (final c in run._closers) {
      try {
        await c();
      } catch (_) {}
    }
    run._closers.clear();
    run._conn?.close();
  }

  Future<void> stop(String id) async {
    final run = _running.remove(id);
    if (run != null) {
      await _close(run);
      notifyListeners();
    }
  }

  Future<void> stopAll() async {
    for (final id in _running.keys.toList()) {
      await stop(id);
    }
  }
}
