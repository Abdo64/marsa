import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../ssh/device_keys.dart';
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
      context: context,
      builder: (_) => _HostDialog(_data, host),
    );
    if (saved == null) return;
    _data.hosts.put(saved);
    await widget.ws.vault.commit();
  }

  Future<void> _delete(Host h) async {
    if (!await confirm(
      context,
      'Delete ${h.title}?',
      'The host is removed from this vault on every synced device.',
      action: 'Delete',
      danger: true,
    )) {
      return;
    }
    _data.hosts.remove(h.id);
    await widget.ws.vault.commit();
  }

  Future<void> _importSshConfig() async {
    final home =
        Platform.environment['HOME'] ??
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
                .where(
                  (k) =>
                      k.publicKey.split(' ')[1] == key.publicKey.split(' ')[1],
                )
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
        // No key named in the config means ssh tries the default ones.
        useDeviceKeys: keyId == null,
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
                'passphrase-protected or unreadable, import those from Keychain' : ''}',
    );
  }

  static final _adHoc = RegExp(r'^([^@\s]+)@([^\s:@]+)(?::(\d{1,5}))?$');

  /// A typed `user@host[:port]` that is not saved: connect to it directly.
  Host? get _quickTarget {
    final m = _adHoc.firstMatch(_query.trim());
    if (m == null) return null;
    return Host(
      address: m[2]!,
      port: int.tryParse(m[3] ?? '') ?? 22,
      username: m[1]!,
      useDeviceKeys: DeviceKeys.available,
    );
  }

  void _submitSearch(List<Host> shown) {
    final quick = _quickTarget;
    if (quick != null) {
      widget.ws.openTerminal(quick);
    } else if (shown.length == 1) {
      widget.ws.openTerminal(shown.single);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = _query.trim().toLowerCase();
    final hosts =
        _data.hosts.all
            .where(
              (h) =>
                  q.isEmpty ||
                  '${h.label} ${h.address} ${h.group} ${h.tags.join(' ')}'
                      .toLowerCase()
                      .contains(q),
            )
            .toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
    final groups = <String, List<Host>>{};
    for (final h in hosts) {
      groups.putIfAbsent(h.group, () => []).add(h);
    }
    // Named groups first, alphabetically; ungrouped hosts last.
    final names = groups.keys.toList()
      ..sort(
        (a, b) => a.isEmpty
            ? 1
            : b.isEmpty
            ? -1
            : a.toLowerCase().compareTo(b.toLowerCase()),
      );
    final quick = _quickTarget;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Hosts',
          actions: [
            SizedBox(
              width: 300,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search, or type user@host to connect',
                  prefixIcon: Icon(Icons.search, size: 17),
                  prefixIconConstraints: BoxConstraints(minWidth: 36),
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) => _submitSearch(hosts),
              ),
            ),
            PopupMenuButton<VoidCallback>(
              tooltip: 'More',
              icon: const Icon(Icons.more_horiz, size: 18),
              onSelected: (f) => f(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _importSshConfig,
                  child: const Text('Import from ~/.ssh/config'),
                ),
              ],
            ),
            FilledButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('New host'),
            ),
          ],
        ),
        if (quick != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: Icon(Icons.bolt, color: t.colorScheme.primary),
                title: Text('Connect to ${_query.trim()}'),
                subtitle: const Text(
                  'Quick connect without saving. Press Enter.',
                ),
                trailing: const Icon(Icons.keyboard_return, size: 16),
                onTap: () => widget.ws.openTerminal(quick),
              ),
            ),
          ),
        Expanded(
          child: hosts.isEmpty
              ? (quick != null
                    ? const SizedBox.shrink()
                    : EmptyState(
                        Icons.dns_outlined,
                        _query.isEmpty ? 'No hosts yet' : 'Nothing matches',
                        _query.isEmpty
                            ? 'Add a server to open a terminal on it or '
                                  'browse its files over SFTP.'
                            : 'Try a different search.',
                        action: _query.isEmpty
                            ? FilledButton.icon(
                                onPressed: _edit,
                                icon: const Icon(Icons.add, size: 17),
                                label: const Text('New host'),
                              )
                            : null,
                      ))
              : CustomScrollView(
                  slivers: [
                    for (final g in names) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(26, 6, 24, 8),
                          child: Row(
                            children: [
                              Text(
                                (g.isEmpty
                                        ? (names.length > 1
                                              ? 'Ungrouped'
                                              : 'All hosts')
                                        : g)
                                    .toUpperCase(),
                                style: t.textTheme.labelSmall?.copyWith(
                                  letterSpacing: .6,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${groups[g]!.length}',
                                style: t.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 420,
                                mainAxisExtent: 62,
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

const _avatarColors = [
  Color(0xFF14B8A6),
  Color(0xFF3B82F6),
  Color(0xFF8B5CF6),
  Color(0xFFF59E0B),
  Color(0xFFEC4899),
  Color(0xFF22C55E),
];

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
    // Hosts in the same group share a colour, so groups read at a glance.
    final seed = host.group.isEmpty ? host.title : host.group;
    final color =
        _avatarColors[seed.codeUnits.fold(0, (a, b) => a + b) %
            _avatarColors.length];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onConnect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 2, 0),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  host.title.characters.first.toUpperCase(),
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.title,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.titleSmall,
                          ),
                        ),
                        for (final tag in host.tags.take(2))
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(tag, style: t.textTheme.labelSmall),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                      style: mono.copyWith(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Open terminal',
                icon: Icon(Icons.terminal, size: 17, color: scheme.primary),
                onPressed: onConnect,
              ),
              IconButton(
                tooltip: 'Browse files (SFTP)',
                icon: const Icon(Icons.folder_copy_outlined, size: 17),
                onPressed: onSftp,
              ),
              PopupMenuButton<VoidCallback>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert, size: 17),
                onSelected: (f) => f(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: onEdit, child: const Text('Edit')),
                  PopupMenuItem(value: onDelete, child: const Text('Delete')),
                ],
              ),
            ],
          ),
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
  // What the "Sign in with" menu shows: an identity id, or one of these.
  static const _device = '\u0000device';
  late String? _identityId = _h == null
      ? (DeviceKeys.available ? _device : null)
      : (_h.useDeviceKeys ? _device : _h.identityId);
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
        useDeviceKeys: _identityId == _device,
        identityId: _identityId == _device ? null : _identityId,
        keyId: _identityId == _device ? null : _keyId,
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
        Row(
          children: [
            Expanded(
              flex: 3,
              child: field(_address, 'Address', hint: 'IP or domain'),
            ),
            const SizedBox(width: 8),
            Expanded(child: field(_port, 'Port')),
          ],
        ),
        Row(
          children: [
            Expanded(child: field(_group, 'Group')),
            const SizedBox(width: 8),
            Expanded(child: field(_tags, 'Tags', hint: 'comma, separated')),
          ],
        ),
        choice<String>('Sign in with', _identityId, {
          _device: 'This device\'s SSH keys (~/.ssh)',
          null: 'Password or a key from the keychain',
          for (final i in d.identities.all) i.id: 'Identity: ${i.title}',
        }, (v) => setState(() => _identityId = v)),
        if (_identityId == _device) ...[
          field(_username, 'Username'),
          Text(
            'Signs in with the keys already on whichever device is '
            'connecting, the same ones the ssh command uses. Nothing is '
            'copied into the vault.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_identityId == null) ...[
          field(_username, 'Username'),
          field(
            _password,
            'Password',
            obscure: true,
            hint: 'Leave empty to be asked, or to use a key',
          ),
          choice<String>('SSH key', _keyId, {
            null: 'None',
            for (final k in d.keys.all) k.id: k.label,
          }, (v) => setState(() => _keyId = v)),
        ],
        choice<String>('Connect through (jump host)', _jumpId, {
          null: 'Direct connection',
          for (final h in d.hosts.all)
            if (h.id != _h?.id) h.id: h.title,
        }, (v) => setState(() => _jumpId = v)),
      ],
    );
  }
}
