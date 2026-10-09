import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../ssh/keys.dart';
import '../ssh/sessions.dart';
import '../ssh/ssh_config.dart';
import 'common.dart';

class HostsPage extends StatefulWidget {
  const HostsPage(this.ws, {super.key});
  final Workspace ws;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  String _query = '';

  VaultData get _data => widget.ws.vault.data;

  Future<void> _edit([Host? host]) async {
    final saved = await showDialog<Host>(
        context: context, builder: (_) => _HostDialog(_data, host));
    if (saved == null) return;
    _data.hosts.put(saved);
    await widget.ws.vault.commit();
  }

  Future<void> _delete(Host h) async {
    if (!await confirm(context, 'Delete ${h.title}?',
        'The host is removed from this vault on every synced device.',
        action: 'Delete', danger: true)) {
      return;
    }
    _data.hosts.remove(h.id);
    await widget.ws.vault.commit();
  }

  Future<void> _importSshConfig() async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final file = File('$home/.ssh/config');
    if (!await file.exists()) {
      if (mounted) toast(context, 'No ${file.path} on this computer');
      return;
    }
    final entries = parseSshConfig(await file.readAsString());
    final existing = {for (final h in _data.hosts.all) h.label};
    final byAlias = <String, Host>{};
    var skippedKeys = 0;
    for (final e in entries) {
      if (existing.contains(e.alias)) continue;
      String? keyId;
      if (e.identityFile != null) {
        final path = e.identityFile!.replaceFirst(RegExp(r'^~'), home);
        try {
          final pem = await File(path).readAsString();
          if (isEncryptedKey(pem)) {
            skippedKeys++;
          } else {
            final key = await importKey(path.split('/').last, pem);
            // The same key file is usually shared by many hosts.
            final same = _data.keys.all
                .where((k) => k.publicKey.split(' ')[1] ==
                    key.publicKey.split(' ')[1])
                .firstOrNull;
            if (same == null) _data.keys.put(key);
            keyId = (same ?? key).id;
          }
        } catch (_) {
          skippedKeys++;
        }
      }
      final h = Host(
        label: e.alias,
        address: e.hostName ?? e.alias,
        port: e.port,
        username: e.user ?? Platform.environment['USER'] ?? '',
        keyId: keyId,
        group: 'Imported',
      );
      byAlias[e.alias] = h;
      _data.hosts.put(h);
    }
    for (final e in entries) {
      final jump = byAlias[e.proxyJump];
      if (jump != null) byAlias[e.alias]?.jumpHostId = jump.id;
    }
    await widget.ws.vault.commit();
    if (!mounted) return;
    toast(
        context,
        'Imported ${byAlias.length} host(s)'
        '${skippedKeys > 0 ? '; $skippedKeys key file(s) were '
            'passphrase-protected or unreadable, import those from Keychain' : ''}');
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final hosts = _data.hosts.all
        .where((h) =>
            q.isEmpty ||
            '${h.label} ${h.address} ${h.group} ${h.tags.join(' ')}'
                .toLowerCase()
                .contains(q))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final groups = <String, List<Host>>{};
    for (final h in hosts) {
      groups.putIfAbsent(h.group, () => []).add(h);
    }
    final names = groups.keys.toList()
      ..sort((a, b) => a.isEmpty
          ? -1
          : b.isEmpty
              ? 1
              : a.toLowerCase().compareTo(b.toLowerCase()));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader('Hosts', actions: [
          SizedBox(
            width: 220,
            child: TextField(
              decoration: const InputDecoration(
                  hintText: 'Search', prefixIcon: Icon(Icons.search, size: 18)),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _importSshConfig,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: const Text('Import ~/.ssh/config'),
          ),
          FilledButton.icon(
            onPressed: _edit,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New host'),
          ),
        ]),
        Expanded(
          child: hosts.isEmpty
              ? EmptyState(
                  Icons.dns_outlined,
                  _query.isEmpty ? 'No hosts yet' : 'Nothing matches',
                  _query.isEmpty
                      ? 'Add a server to connect to it over SSH or browse it '
                          'over SFTP.'
                      : 'Try a different search.')
              : CustomScrollView(
                  slivers: [
                    for (final g in names) ...[
                      if (g.isNotEmpty || names.length > 1)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                            child: Text(g.isEmpty ? 'Ungrouped' : g,
                                style: Theme.of(context).textTheme.titleSmall),
                          ),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 340,
                            mainAxisExtent: 84,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: groups[g]!.length,
                          itemBuilder: (context, i) {
                            final h = groups[g]![i];
                            return _HostCard(
                              host: h,
                              subtitle:
                                  '${_data.credentialsFor(h).username}@${h.address}'
                                  '${h.port == 22 ? '' : ':${h.port}'}',
                              onConnect: () => widget.ws.openTerminal(h),
                              onSftp: () => widget.ws.openSftp(h),
                              onEdit: () => _edit(h),
                              onDelete: () => _delete(h),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.subtitle,
    required this.onConnect,
    required this.onSftp,
    required this.onEdit,
    required this.onDelete,
  });
  final Host host;
  final String subtitle;
  final VoidCallback onConnect, onSftp, onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onConnect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(Icons.dns_outlined,
                  size: 18, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(host.title,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.titleSmall),
                  Text(subtitle,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                      style: t.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (host.tags.isNotEmpty)
                    Text(host.tags.map((t) => '#$t').join(' '),
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.labelSmall
                            ?.copyWith(color: scheme.primary)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Browse files (SFTP)',
              icon: const Icon(Icons.folder_copy_outlined, size: 18),
              onPressed: onSftp,
            ),
            PopupMenuButton<VoidCallback>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (f) => f(),
              itemBuilder: (_) => [
                PopupMenuItem(value: onConnect, child: const Text('Connect')),
                PopupMenuItem(value: onSftp, child: const Text('SFTP')),
                PopupMenuItem(value: onEdit, child: const Text('Edit')),
                PopupMenuItem(value: onDelete, child: const Text('Delete')),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _HostDialog extends StatefulWidget {
  const _HostDialog(this.data, this.host);
  final VaultData data;
  final Host? host;

  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  late final Host? _h = widget.host;
  late final _label = TextEditingController(text: _h?.label);
  late final _address = TextEditingController(text: _h?.address);
  late final _port = TextEditingController(text: '${_h?.port ?? 22}');
  late final _group = TextEditingController(text: _h?.group);
  late final _tags = TextEditingController(text: _h?.tags.join(', '));
  late final _username = TextEditingController(text: _h?.username);
  late final _password = TextEditingController(text: _h?.password);
  late String? _identityId = _h?.identityId;
  late String? _keyId = _h?.keyId;
  late String? _jumpId = _h?.jumpHostId;

  void _save() {
    final address = _address.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (address.isEmpty || port == null || port < 1 || port > 65535) {
      toast(context, 'Enter an address and a valid port');
      return;
    }
    Navigator.pop(
      context,
      Host(
        id: _h?.id,
        label: _label.text.trim(),
        address: address,
        port: port,
        group: _group.text.trim(),
        tags: [
          for (final t in _tags.text.split(','))
            if (t.trim().isNotEmpty) t.trim(),
        ],
        username: _username.text.trim(),
        password: _password.text,
        identityId: _identityId,
        keyId: _keyId,
        jumpHostId: _jumpId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    return FormDialog(
      title: _h == null ? 'New host' : 'Edit host',
      onSave: _save,
      children: [
        field(_label, 'Label', hint: 'Shown in the list; optional'),
        Row(children: [
          Expanded(
              flex: 3, child: field(_address, 'Address', hint: 'IP or domain')),
          const SizedBox(width: 8),
          Expanded(child: field(_port, 'Port')),
        ]),
        Row(children: [
          Expanded(child: field(_group, 'Group')),
          const SizedBox(width: 8),
          Expanded(child: field(_tags, 'Tags', hint: 'comma, separated')),
        ]),
        choice<String>(
          'Sign in with',
          _identityId,
          {
            null: 'Credentials entered below',
            for (final i in d.identities.all) i.id: 'Identity: ${i.title}',
          },
          (v) => setState(() => _identityId = v),
        ),
        if (_identityId == null) ...[
          field(_username, 'Username'),
          field(_password, 'Password',
              obscure: true, hint: 'Leave empty to be asked, or to use a key'),
          choice<String>(
            'SSH key',
            _keyId,
            {null: 'None', for (final k in d.keys.all) k.id: k.label},
            (v) => setState(() => _keyId = v),
          ),
        ],
        choice<String>(
          'Connect through (jump host)',
          _jumpId,
          {
            null: 'Direct connection',
            for (final h in d.hosts.all)
              if (h.id != _h?.id) h.id: h.title,
          },
          (v) => setState(() => _jumpId = v),
        ),
      ],
    );
  }
}
