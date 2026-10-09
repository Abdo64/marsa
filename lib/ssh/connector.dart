import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../core/models.dart';
import '../core/vault.dart';
import 'device_keys.dart';

/// Questions a connection may need answered by the person at the keyboard.
abstract class Prompter {
  /// A server we have no pinned key for. Return true to trust and remember it.
  Future<bool> confirmNewHost(String host, String type, String fingerprint);

  /// The server's key differs from the pinned one. Return true only if the
  /// user explicitly chose to replace the pinned key.
  Future<bool> confirmChangedHost(
    String host,
    String type,
    String oldFingerprint,
    String fingerprint,
  );

  Future<String?> askSecret(String title, String prompt);

  Future<List<String>?> askInteractive(
    String title,
    String instruction,
    List<SSHUserInfoPrompt> prompts,
  );
}

class ConnectError implements Exception {
  ConnectError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An authenticated client plus the jump-host clients it tunnels through.
class Connection {
  Connection(this.client, this._parents);
  final SSHClient client;
  final List<SSHClient> _parents;

  void close() {
    client.close();
    for (final p in _parents) {
      p.close();
    }
  }
}

Future<Connection> connect(VaultSession vault, Host host, Prompter ui) =>
    _connect(vault, host, ui, {});

Future<Connection> _connect(
  VaultSession vault,
  Host host,
  Prompter ui,
  Set<String> chain,
) async {
  if (!chain.add(host.id)) {
    throw ConnectError('Jump hosts form a loop at ${host.title}');
  }
  final creds = vault.data.credentialsFor(host);
  if (creds.username.isEmpty) {
    throw ConnectError('${host.title} has no username set');
  }
  final where = '${host.address}:${host.port}';

  // Read (and if needed unlock) the keys before opening the connection, so a
  // passphrase prompt cannot run into the server's login timeout.
  final identities = <SSHKeyPair>[
    if (creds.key != null) ...SSHKeyPair.fromPem(creds.key!.privateKey),
    if (host.useDeviceKeys) ...await DeviceKeys.load(ui),
  ];

  final parents = <SSHClient>[];
  final SSHSocket socket;
  try {
    final jump = vault.data.hosts[host.jumpHostId];
    if (jump != null) {
      final via = await _connect(vault, jump, ui, chain);
      parents
        ..add(via.client)
        ..addAll(via._parents);
      socket = await via.client.forwardLocal(host.address, host.port);
    } else {
      socket = await SSHSocket.connect(
        host.address,
        host.port,
        timeout: const Duration(seconds: 20),
      );
    }
  } catch (e) {
    for (final p in parents) {
      p.close();
    }
    if (e is ConnectError) rethrow;
    throw ConnectError('Cannot reach $where ($e)');
  }

  String? rejected;
  var passwordTries = 0;
  final client = SSHClient(
    socket,
    username: creds.username,
    identities: identities.isEmpty ? null : identities,
    onVerifyHostKey: (type, raw) async {
      final seen = utf8.decode(raw);
      final known = vault.data.knownHosts[where];
      if (known != null && known.fingerprint == seen) return true;
      final ok = known == null
          ? await ui.confirmNewHost(where, type, seen)
          : await ui.confirmChangedHost(where, type, known.fingerprint, seen);
      if (!ok) {
        rejected = 'Host key for $where was not accepted';
        return false;
      }
      vault.data.knownHosts.put(
        KnownHost(id: where, type: type, fingerprint: seen),
      );
      await vault.commit();
      return true;
    },
    onPasswordRequest: () {
      // Offer the saved password once; after that, ask.
      if (passwordTries++ == 0 && creds.password.isNotEmpty) {
        return creds.password;
      }
      return ui.askSecret(host.title, 'Password for ${creds.username}@$where');
    },
    onUserInfoRequest: (req) async {
      if (req.prompts.isEmpty) return [];
      // A lone hidden prompt is almost always the account password.
      if (req.prompts.length == 1 &&
          !req.prompts.first.echo &&
          passwordTries++ == 0 &&
          creds.password.isNotEmpty) {
        return [creds.password];
      }
      return ui.askInteractive(
        req.name.isEmpty ? host.title : req.name,
        req.instruction,
        req.prompts,
      );
    },
  );

  try {
    await client.authenticated;
  } catch (e) {
    client.close();
    for (final p in parents) {
      p.close();
    }
    if (rejected != null) throw ConnectError(rejected!);
    if (e is SSHAuthError) {
      throw ConnectError('Authentication failed for ${creds.username}@$where');
    }
    throw ConnectError('Connection to $where failed ($e)');
  }
  return Connection(client, parents);
}
