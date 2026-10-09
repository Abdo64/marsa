import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../ssh/connector.dart';
import '../ssh/keys.dart';
import '../ssh/sessions.dart';
import 'common.dart';

class KeychainPage extends StatelessWidget {
  const KeychainPage(this.ws, {super.key});
  final Workspace ws;

  VaultData get _data => ws.vault.data;

  Future<void> _add(BuildContext context, SshKey? key) async {
    if (key == null) return;
    _data.keys.put(key);
    await ws.vault.commit();
    if (context.mounted) toast(context, 'Key "${key.label}" added');
  }

  Future<void> _generate(BuildContext context, bool rsa) async {
    final r = await promptFields(context,
        rsa ? 'Generate RSA 3072 key' : 'Generate Ed25519 key',
        labels: ['Label'], action: 'Generate');
    if (r == null || r.first.trim().isEmpty || !context.mounted) return;
    final label = r.first.trim();
    final key = await busy(context,
        () async => rsa ? await generateRsa(label) : generateEd25519(label));
    if (context.mounted) await _add(context, key);
  }

  Future<void> _import(BuildContext context, {required bool fromFile}) async {
    String pem;
    var label = '';
    if (fromFile) {
      final f = await FilePicker.pickFile(dialogTitle: 'Choose a private key');
      if (f?.path == null) return;
      pem = await File(f!.path!).readAsString();
      label = f.name;
    } else {
      if (!context.mounted) return;
      final r = await showDialog<String>(
          context: context, builder: (_) => const _PasteKeyDialog());
      if (r == null) return;
      pem = r;
    }
    if (!context.mounted) return;
    final encrypted = isEncryptedKey(pem);
    final r = await promptFields(
      context,
      'Import key',
      message: encrypted
          ? 'This key is passphrase-protected. It is unlocked once and then '
              'protected by the vault instead.'
          : null,
      labels: ['Label', if (encrypted) 'Key passphrase'],
      obscure: [false, if (encrypted) true],
      initial: [label, if (encrypted) ''],
      action: 'Import',
    );
    if (r == null || r.first.trim().isEmpty || !context.mounted) return;
    final key = await busy(context, () async {
      try {
        return await importKey(r.first.trim(), pem, encrypted ? r[1] : null);
      } catch (_) {
        throw ConnectError(encrypted
            ? 'Could not unlock the key. Check the passphrase.'
            : 'That is not a private key this app can read.');
      }
    });
    if (context.mounted) await _add(context, key);
  }

  Future<void> _deploy(BuildContext context, SshKey key) async {
    final hosts = _data.hosts.all.toList();
    if (hosts.isEmpty) return toast(context, 'Add a host first');
    final host = await showDialog<Host>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Install public key on'),
        children: [
          for (final h in hosts)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, h), child: Text(h.title)),
        ],
      ),
    );
    if (host == null || !context.mounted) return;
    final done = await busy(context, () async {
      final conn = await connect(ws.vault, host, ws.ui);
      try {
        final line = key.publicKey;
        final r = await conn.client.runWithResult(
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
            "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys "
            "&& { grep -qxF '$line' ~/.ssh/authorized_keys || "
            "echo '$line' >> ~/.ssh/authorized_keys; }");
        if (r.exitCode != 0) {
          throw ConnectError(
              'The server could not save the key: ${utf8.decode(r.stderr, allowMalformed: true).trim()}');
        }
        return true;
      } finally {
        conn.close();
      }
    });
    if (done == true && context.mounted) {
      toast(context, 'Key installed on ${host.title}');
    }
  }

  Future<void> _deleteKey(BuildContext context, SshKey k) async {
    final users = [
      ..._data.hosts.all.where((h) => h.keyId == k.id).map((h) => h.title),
      ..._data.identities.all.where((i) => i.keyId == k.id).map((i) => i.title),
    ];
    if (!await confirm(
        context,
        'Delete key "${k.label}"?',
        users.isEmpty
            ? 'The private key is erased from this vault on every synced '
                'device.'
            : 'It is still used by: ${users.join(', ')}. They will fall back '
                'to password sign-in.',
        action: 'Delete',
        danger: true)) {
      return;
    }
    _data.keys.remove(k.id);
    await ws.vault.commit();
  }

  Future<void> _editIdentity(BuildContext context, [Identity? i]) async {
    final saved = await showDialog<Identity>(
        context: context, builder: (_) => _IdentityDialog(_data, i));
    if (saved == null) return;
    _data.identities.put(saved);
    await ws.vault.commit();
  }

  Future<void> _deleteIdentity(BuildContext context, Identity i) async {
    final n = _data.hosts.all.where((h) => h.identityId == i.id).length;
    if (!await confirm(context, 'Delete identity "${i.title}"?',
        n == 0 ? 'No host uses it.' : '$n host(s) use it and will need new credentials.',
        action: 'Delete', danger: true)) {
      return;
    }
    _data.identities.remove(i.id);
    await ws.vault.commit();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted =
        t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final keys = _data.keys.all.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    final identities = _data.identities.all.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return ListView(
      children: [
        PageHeader('Keys', actions: [
          PopupMenuButton<VoidCallback>(
            onSelected: (f) => f(),
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: () => _import(context, fromFile: true),
                  child: const Text('Import from file')),
              PopupMenuItem(
                  value: () => _import(context, fromFile: false),
                  child: const Text('Paste a key')),
              PopupMenuItem(
                  value: () => _generate(context, true),
                  child: const Text('Generate RSA 3072')),
            ],
            child: const IgnorePointer(
              child: OutlinedButton(onPressed: _noop, child: Text('More…')),
            ),
          ),
          FilledButton.icon(
            onPressed: () => _generate(context, false),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Generate key'),
          ),
        ]),
        if (keys.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: EmptyState(Icons.key_outlined, 'No keys yet',
                'Generate an Ed25519 key or import one you already use.'),
          ),
        for (final k in keys)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(k.label),
                subtitle: Text('${k.type}  ${fingerprintOf(k.publicKey)}',
                    overflow: TextOverflow.ellipsis,
                    style: muted?.merge(mono)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Copy public key',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () =>
                        copyText(context, k.publicKey, 'Public key'),
                  ),
                  PopupMenuButton<VoidCallback>(
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (f) => f(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                          value: () => _deploy(context, k),
                          child: const Text('Install on a host…')),
                      PopupMenuItem(
                          value: () =>
                              copyText(context, k.privateKey, 'Private key'),
                          child: const Text('Copy private key')),
                      PopupMenuItem(
                          value: () => _deleteKey(context, k),
                          child: const Text('Delete')),
                    ],
                  ),
                ]),
              ),
            ),
          ),
        PageHeader('Identities', actions: [
          FilledButton.icon(
            onPressed: () => _editIdentity(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New identity'),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
              'An identity is a username with a password or key that several '
              'hosts can share. Change it once and every host follows.',
              style: muted),
        ),
        for (final i in identities)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(i.title),
                subtitle: Text(
                    [
                      i.username,
                      if (i.password.isNotEmpty) 'password',
                      if (_data.keys[i.keyId] != null)
                        'key: ${_data.keys[i.keyId]!.label}',
                    ].join('  ·  '),
                    style: muted),
                onTap: () => _editIdentity(context, i),
                trailing: IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _deleteIdentity(context, i),
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
      ],
    );
  }
}

void _noop() {}

class _PasteKeyDialog extends StatefulWidget {
  const _PasteKeyDialog();

  @override
  State<_PasteKeyDialog> createState() => _PasteKeyDialogState();
}

class _PasteKeyDialogState extends State<_PasteKeyDialog> {
  final _pem = TextEditingController();

  @override
  Widget build(BuildContext context) => FormDialog(
        title: 'Paste a private key',
        saveLabel: 'Next',
        onSave: () => Navigator.pop(context, _pem.text),
        children: [
          field(_pem, 'Private key',
              hint: '-----BEGIN OPENSSH PRIVATE KEY-----', lines: 8, code: true),
        ],
      );
}

class _IdentityDialog extends StatefulWidget {
  const _IdentityDialog(this.data, this.identity);
  final VaultData data;
  final Identity? identity;

  @override
  State<_IdentityDialog> createState() => _IdentityDialogState();
}

class _IdentityDialogState extends State<_IdentityDialog> {
  late final _i = widget.identity;
  late final _label = TextEditingController(text: _i?.label);
  late final _username = TextEditingController(text: _i?.username);
  late final _password = TextEditingController(text: _i?.password);
  late String? _keyId = _i?.keyId;

  @override
  Widget build(BuildContext context) => FormDialog(
        title: _i == null ? 'New identity' : 'Edit identity',
        onSave: () {
          if (_username.text.trim().isEmpty) {
            toast(context, 'A username is required');
            return;
          }
          Navigator.pop(
            context,
            Identity(
              id: _i?.id,
              label: _label.text.trim(),
              username: _username.text.trim(),
              password: _password.text,
              keyId: _keyId,
            ),
          );
        },
        children: [
          field(_label, 'Label', hint: 'Optional'),
          field(_username, 'Username'),
          field(_password, 'Password', obscure: true),
          choice<String>(
            'SSH key',
            _keyId,
            {
              null: 'None',
              for (final k in widget.data.keys.all) k.id: k.label,
            },
            (v) => setState(() => _keyId = v),
          ),
        ],
      );
}
