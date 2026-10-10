import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/sync.dart';
import '../ssh/device_keys.dart';
import 'common.dart';

/// Collects a sync target. With [joining] the target must already hold a
/// vault file; otherwise it is where this vault will be uploaded. [data]
/// (when a vault is open) lets the form be filled from a saved host.
Future<SyncConfig?> showSyncDialog(
  BuildContext context, {
  required String vaultName,
  bool joining = false,
  VaultData? data,
  SyncConfig? current,
}) => showDialog<SyncConfig>(
  context: context,
  builder: (_) => _SyncDialog(vaultName, joining, data, current),
);

class _SyncDialog extends StatefulWidget {
  const _SyncDialog(this.vaultName, this.joining, this.data, this.current);
  final String vaultName;
  final bool joining;
  final VaultData? data;
  final SyncConfig? current;

  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  late String _type = widget.current?.type ?? SyncConfig.sftp;
  late final _fileName =
      '${widget.vaultName.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')}'
      '.marsa';
  late final _folderPath = TextEditingController(
    text: widget.current?.type == SyncConfig.folder ? widget.current!.path : '',
  );
  late final _host = TextEditingController(text: widget.current?.host ?? '');
  late final _port = TextEditingController(
    text: '${widget.current?.port ?? 22}',
  );
  late final _user = TextEditingController(
    text: widget.current?.username ?? '',
  );
  late final _password = TextEditingController(
    text: widget.current?.password ?? '',
  );
  late final _key = TextEditingController(
    text: widget.current?.privateKey ?? '',
  );
  late final _remotePath = TextEditingController(
    text: widget.current?.type == SyncConfig.sftp
        ? widget.current!.path
        : 'marsa/$_fileName',
  );

  Future<void> _browse() async {
    if (widget.joining) {
      final f = await FilePicker.pickFile(dialogTitle: 'Choose the vault file');
      if (f?.path != null) setState(() => _folderPath.text = f!.path!);
    } else {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose the folder to sync through',
      );
      if (dir != null) {
        setState(
          () => _folderPath.text = '$dir${Platform.pathSeparator}$_fileName',
        );
      }
    }
  }

  Future<void> _loadKey() async {
    final f = await FilePicker.pickFile(dialogTitle: 'Choose a private key');
    if (f?.path != null) {
      final text = await File(f!.path!).readAsString();
      setState(() => _key.text = text);
    }
  }

  late bool _deviceKeys = widget.current?.deviceKeys ?? DeviceKeys.available;
  final _link = TextEditingController();

  void _pasteLink(String text) {
    final cfg = SyncConfig.fromLink(text);
    if (cfg == null) return;
    setState(() {
      _type = SyncConfig.sftp;
      _host.text = cfg.host;
      _port.text = '${cfg.port}';
      _user.text = cfg.username;
      _remotePath.text = cfg.path;
      // Fall back to asking for a password where this device has no keys.
      _deviceKeys = cfg.deviceKeys && DeviceKeys.available;
    });
  }

  void _fillFrom(Host? h) {
    if (h == null) return;
    final c = widget.data!.credentialsFor(h);
    setState(() {
      _host.text = h.address;
      _port.text = '${h.port}';
      _user.text = c.username;
      _password.text = c.password;
      _key.text = c.key?.privateKey ?? '';
      _deviceKeys = h.useDeviceKeys;
    });
  }

  void _save() {
    final SyncConfig cfg;
    if (_type == SyncConfig.folder) {
      if (_folderPath.text.trim().isEmpty) return;
      cfg = SyncConfig(type: _type, path: _folderPath.text.trim());
    } else {
      if (_host.text.trim().isEmpty ||
          _user.text.trim().isEmpty ||
          _remotePath.text.trim().isEmpty) {
        toast(context, 'Server, username and path are required');
        return;
      }
      final same =
          widget.current?.host == _host.text.trim() &&
          widget.current?.port == (int.tryParse(_port.text) ?? 22);
      cfg = SyncConfig(
        type: _type,
        path: _remotePath.text.trim(),
        host: _host.text.trim(),
        port: int.tryParse(_port.text) ?? 22,
        username: _user.text.trim(),
        password: _deviceKeys ? '' : _password.text,
        privateKey: _deviceKeys ? '' : _key.text,
        deviceKeys: _deviceKeys,
        // Keep the pinned key only while it is still the same server.
        fingerprint: same ? widget.current!.fingerprint : '',
      );
    }
    Navigator.pop(context, cfg);
  }

  @override
  Widget build(BuildContext context) {
    final hosts = widget.data?.hosts.all.toList() ?? const <Host>[];
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return FormDialog(
      title: widget.joining ? 'Join a synced vault' : 'Sync this vault',
      saveLabel: widget.joining ? 'Continue' : 'Save and sync',
      onSave: _save,
      children: [
        if (widget.joining)
          labeled(
            'Sync link (optional)',
            TextField(
              controller: _link,
              style: mono.copyWith(fontSize: 12.5),
              decoration: const InputDecoration(
                hintText: 'Paste a link copied from another device',
              ),
              onChanged: _pasteLink,
            ),
          ),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: SyncConfig.sftp,
              icon: Icon(Icons.dns_outlined),
              label: Text('Your server (SFTP)'),
            ),
            ButtonSegment(
              value: SyncConfig.folder,
              icon: Icon(Icons.folder_outlined),
              label: Text('Folder'),
            ),
          ],
          selected: {_type},
          onSelectionChanged: (s) => setState(() => _type = s.first),
        ),
        if (_type == SyncConfig.folder) ...[
          Text(
            widget.joining
                ? 'Pick the .marsa file inside your cloud-drive or shared '
                      'folder.'
                : 'Pick a folder that your devices already share: iCloud '
                      'Drive, OneDrive, Dropbox, Syncthing, a network share.',
            style: muted,
          ),
          Row(
            children: [
              Expanded(child: field(_folderPath, 'Vault file', code: true)),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _browse, child: const Text('Browse')),
            ],
          ),
        ] else ...[
          Text(
            'The encrypted vault file is kept on a server you control and '
            'every device reads and writes it over SFTP. The server never '
            'sees its contents.',
            style: muted,
          ),
          if (hosts.isNotEmpty)
            choice<Host>('Fill in from a saved host', null, {
              null: 'Choose…',
              for (final h in hosts) h: h.title,
            }, _fillFrom),
          Row(
            children: [
              Expanded(flex: 3, child: field(_host, 'Server address')),
              const SizedBox(width: 8),
              Expanded(child: field(_port, 'Port')),
            ],
          ),
          field(_user, 'Username'),
          SwitchListTile(
            value: _deviceKeys,
            onChanged: (v) => setState(() => _deviceKeys = v),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Log in with this device\'s SSH keys (~/.ssh)'),
            subtitle: const Text(
              'Each device uses its own keys, so every device you sync must '
              'already be able to ssh into this server.',
            ),
          ),
          if (!_deviceKeys)
            field(_password, 'Server login password', obscure: true),
          if (!_deviceKeys)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: field(
                    _key,
                    'Private key (optional, unencrypted PEM)',
                    lines: 3,
                    code: true,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _loadKey, child: const Text('Load')),
              ],
            ),
          field(
            _remotePath,
            'Path of the vault file on the server',
            code: true,
          ),
        ],
      ],
    );
  }
}
