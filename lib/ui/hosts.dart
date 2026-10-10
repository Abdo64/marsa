import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/importers.dart';
import '../core/models.dart';
import '../ssh/device_keys.dart';
import '../ssh/keys.dart';
import '../ssh/sessions.dart';
import 'common.dart';
import 'theme.dart';

class HostsPage extends StatefulWidget {
  const HostsPage(this.ws, {super.key});
  final Workspace ws;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  String _query = '';

  /// The group picked in the groups panel; null shows every host.
  String? _group;

  /// The tag picked in the groups panel, if any.
  String? _tag;

  Future<void> _moveTo(Host h, String group) async {
    if (h.group == group) return;
    h.group = group;
    _data.hosts.put(h);
    await widget.ws.vault.commit();
  }

  /// Asks which group [h] belongs in: an existing one or a new name.
  Future<void> _askGroup(Host h) async {
    final existing = {
      for (final x in _data.hosts.all)
        if (x.group.isNotEmpty) x.group,
    }.toList()..sort();
    final r = await promptFields(
      context,
      'Move ${h.title} to a group',
      message: existing.isEmpty
          ? 'Type a name to create the first group.'
          : 'Type a new name, or one of: ${existing.join(', ')}. Leave it '
                'empty to take the host out of its group.',
      labels: ['Group'],
      initial: [h.group],
      action: 'Move',
    );
    if (r != null) await _moveTo(h, r.first.trim());
  }

  VaultData get _data => widget.ws.vault.data;

  Future<void> _edit([Host? host]) async {
    final saved = await showDialog<Host>(
      context: context,
      builder: (_) => _HostDialog(_data, host, initialGroup: _group),
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

  String get _home =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  /// Reads hosts from [load], shows what was found and adds what is new.
  Future<void> _import(Future<Uint8List?> Function() load) async {
    final ImportResult found;
    try {
      final bytes = await load();
      if (bytes == null) return;
      found = parseImport(decodeText(bytes));
    } catch (e) {
      if (mounted) toast(context, e.toString());
      return;
    }
    bool have(ImportedHost i) => _data.hosts.all.any(
      (h) =>
          h.address == i.address &&
          h.port == i.port &&
          (i.label.isEmpty || h.label == i.label),
    );
    final fresh = found.hosts.where((i) => !have(i)).toList();
    final skipped = found.hosts.length - fresh.length;
    if (!mounted) return;
    if (fresh.isEmpty) {
      return toast(
        context,
        'All ${found.hosts.length} host(s) in that file are already here',
      );
    }
    final preview = fresh
        .take(8)
        .map(
          (i) =>
              '•  ${i.label.isEmpty ? i.address : '${i.label}  (${i.address})'}',
        )
        .join('\n');
    if (!await confirm(
      context,
      'Import ${fresh.length} host(s) from ${found.source}?',
      '$preview'
          '${fresh.length > 8 ? '\n…and ${fresh.length - 8} more' : ''}'
          '${skipped > 0 ? '\n\n$skipped already in this vault will be skipped.' : ''}',
      action: 'Import',
    )) {
      return;
    }

    final byLabel = <String, Host>{};
    var skippedKeys = 0;
    for (final i in fresh) {
      String? keyId;
      if (i.identityFile != null) {
        final path = i.identityFile!.replaceFirst(RegExp(r'^~'), _home);
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
        label: i.label,
        address: i.address,
        port: i.port,
        // Like ssh itself, an OpenSSH entry without a user means "me".
        username: i.username.isEmpty && found.source == 'OpenSSH config'
            ? Platform.environment['USER'] ?? ''
            : i.username,
        password: i.password,
        keyId: keyId,
        // Nothing to sign in with came along: use this device's own keys.
        useDeviceKeys: keyId == null && i.password.isEmpty,
        group: i.group.isEmpty ? 'Imported' : i.group,
        tags: i.tags,
      );
      if (i.label.isNotEmpty) byLabel[i.label] = h;
      _data.hosts.put(h);
    }
    for (final i in fresh) {
      final jump = byLabel[i.proxyJump];
      if (jump != null) byLabel[i.label]?.jumpHostId = jump.id;
    }
    await widget.ws.vault.commit();
    if (!mounted) return;
    toast(
      context,
      'Imported ${fresh.length} host(s)'
      '${skippedKeys > 0 ? '; $skippedKeys key file(s) were '
                'passphrase-protected or unreadable, import those from Keychain' : ''}',
    );
  }

  Future<Uint8List?> _pickImportFile() async {
    final f = await FilePicker.pickFile(
      dialogTitle:
          'Choose an export file (CSV, ssh config, .reg, .mxtsessions)',
    );
    return f?.path == null ? null : File(f!.path!).readAsBytes();
  }

  Future<Uint8List?> _readSshConfig() async {
    final file = File('$_home/.ssh/config');
    if (!await file.exists()) {
      throw ImportError('No ${file.path} on this computer');
    }
    return file.readAsBytes();
  }

  /// Windows only: PuTTY keeps its sessions in the registry.
  Future<Uint8List?> _readPuttyRegistry() async {
    final out = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}marsa-putty.reg',
    );
    final r = await Process.run('reg', [
      'export',
      r'HKCU\Software\SimonTatham\PuTTY\Sessions',
      out.path,
      '/y',
    ]);
    if (r.exitCode != 0 || !await out.exists()) {
      throw ImportError('No PuTTY sessions found on this PC');
    }
    try {
      return await out.readAsBytes();
    } finally {
      await out.delete();
    }
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
    // The groups panel counts what the search found, before the selected
    // group narrows the list.
    final counts = <String, int>{};
    for (final h in hosts) {
      counts[h.group] = (counts[h.group] ?? 0) + 1;
    }
    final total = hosts.length;
    final tagCounts = <String, int>{};
    for (final h in hosts) {
      for (final tag in h.tags) {
        tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
      }
    }
    final group = counts.containsKey(_group) ? _group : null;
    final tag = tagCounts.containsKey(_tag) ? _tag : null;
    if (group != null) hosts.removeWhere((h) => h.group != group);
    if (tag != null) hosts.removeWhere((h) => !h.tags.contains(tag));
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
                  value: () => _import(_pickImportFile),
                  child: const Text('Import from a file…'),
                ),
                PopupMenuItem(
                  value: () => _import(_readSshConfig),
                  child: const Text('Import from ~/.ssh/config'),
                ),
                if (Platform.isWindows)
                  PopupMenuItem(
                    value: () => _import(_readPuttyRegistry),
                    child: const Text('Import PuTTY sessions from this PC'),
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
          child: _GroupsLayout(
            counts: counts,
            tags: tagCounts,
            total: total,
            selected: group,
            selectedTag: tag,
            onSelect: (g) => setState(() {
              _group = g;
              _tag = null;
            }),
            onSelectTag: (t) => setState(() {
              _tag = t == _tag ? null : t;
              _group = null;
            }),
            onDrop: _moveTo,
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
                                onMove: () => _askGroup(h),
                                onDelete: () => _delete(h),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// The colour a group (or an ungrouped host) is shown in everywhere.
Color groupColor(String seed) =>
    _avatarColors[seed.codeUnits.fold(0, (a, b) => a + b) %
        _avatarColors.length];

/// Puts the groups panel beside the host list: a column on a wide window, a
/// strip of chips on a narrow one. It lists groups and tags; both filter the
/// list, and a host card can be dropped on a group to move it there.
class _GroupsLayout extends StatelessWidget {
  const _GroupsLayout({
    required this.counts,
    required this.tags,
    required this.total,
    required this.selected,
    required this.selectedTag,
    required this.onSelect,
    required this.onSelectTag,
    required this.onDrop,
    required this.child,
  });
  final Map<String, int> counts;
  final Map<String, int> tags;
  final int total;
  final String? selected;
  final String? selectedTag;
  final ValueChanged<String?> onSelect;
  final ValueChanged<String> onSelectTag;
  final void Function(Host host, String group) onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final named = counts.keys.where((g) => g.isNotEmpty).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final tagNames = tags.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (total == 0 && named.isEmpty) return child;
    final t = Theme.of(context);
    final scheme = t.colorScheme;

    Widget entry({
      required String label,
      required int count,
      required bool on,
      required VoidCallback onTap,
      required Widget lead,
      required bool chip,
      String? dropGroup,
    }) {
      Widget tile(bool hovering) => Padding(
        padding: chip
            ? const EdgeInsets.only(right: 6)
            : const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: hovering
              ? scheme.primaryContainer
              : on
              ? scheme.surfaceContainerHigh
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: chip ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  lead,
                  const SizedBox(width: 10),
                  Flexible(
                    fit: chip ? FlexFit.loose : FlexFit.tight,
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: on
                            ? scheme.onSurface
                            : Palette.of(context).muted,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('$count', style: t.textTheme.labelSmall),
                ],
              ),
            ),
          ),
        ),
      );
      if (dropGroup == null) return tile(false);
      return DragTarget<Host>(
        onWillAcceptWithDetails: (d) => d.data.group != dropGroup,
        onAcceptWithDetails: (d) => onDrop(d.data, dropGroup),
        builder: (context, candidates, _) => tile(candidates.isNotEmpty),
      );
    }

    Widget dot(Color? fill) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: fill == null ? Border.all(color: scheme.outline) : null,
      ),
    );

    List<Widget> groupEntries(bool chip) => [
      entry(
        label: 'All hosts',
        count: total,
        on: selected == null && selectedTag == null,
        onTap: () => onSelect(null),
        lead: dot(scheme.outline),
        chip: chip,
      ),
      for (final g in named)
        entry(
          label: g,
          count: counts[g]!,
          on: selected == g,
          onTap: () => onSelect(g),
          lead: dot(groupColor(g)),
          chip: chip,
          dropGroup: g,
        ),
      if (named.isNotEmpty && counts.containsKey(''))
        entry(
          label: 'Ungrouped',
          count: counts['']!,
          on: selected == '',
          onTap: () => onSelect(''),
          lead: dot(null),
          chip: chip,
          dropGroup: '',
        ),
    ];
    List<Widget> tagEntries(bool chip) => [
      for (final tag in tagNames)
        entry(
          label: tag,
          count: tags[tag]!,
          on: selectedTag == tag,
          onTap: () => onSelectTag(tag),
          lead: Icon(Icons.sell_outlined, size: 13, color: scheme.outline),
          chip: chip,
        ),
    ];
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 0, 8),
      child: Text(
        text,
        style: t.textTheme.labelSmall?.copyWith(
          letterSpacing: .6,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 720
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 200,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                    children: [
                      heading('GROUPS'),
                      ...groupEntries(false),
                      if (named.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 6, 0),
                          child: Text(
                            'No groups yet. Use "Move to group…" in a '
                            'host\'s ⋮ menu to start one, then drag hosts '
                            'onto it.',
                            style: t.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w400,
                              height: 1.4,
                            ),
                          ),
                        ),
                      if (tagNames.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        heading('TAGS'),
                        ...tagEntries(false),
                      ],
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(24, 0, 18, 6),
                    children: [...groupEntries(true), ...tagEntries(true)],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
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
    required this.onMove,
    required this.onDelete,
  });
  final Host host;
  final String subtitle;
  final VoidCallback onConnect, onSftp, onEdit, onMove, onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    // Hosts in the same group share a colour, so groups read at a glance.
    final color = groupColor(host.group.isEmpty ? host.title : host.group);
    // Draggable onto a group in the groups panel.
    return Draggable<Host>(
      data: host,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(host.title, style: t.textTheme.titleSmall),
        ),
      ),
      child: _card(context, t, scheme, color),
    );
  }

  Widget _card(
    BuildContext context,
    ThemeData t,
    ColorScheme scheme,
    Color color,
  ) {
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
                  PopupMenuItem(
                    value: onMove,
                    child: const Text('Move to group…'),
                  ),
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
  const _HostDialog(this.data, this.host, {this.initialGroup});
  final VaultData data;
  final Host? host;

  /// The group a new host starts in: the one being browsed.
  final String? initialGroup;

  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  late final Host? _h = widget.host;
  late final _label = TextEditingController(text: _h?.label);
  late final _address = TextEditingController(text: _h?.address);
  late final _port = TextEditingController(text: '${_h?.port ?? 22}');
  late final _group = TextEditingController(
    text: _h?.group ?? widget.initialGroup,
  );
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
