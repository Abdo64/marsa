import 'package:flutter/material.dart';

import '../ssh/files.dart';
import '../ssh/sessions.dart';
import 'common.dart';

/// One side of the SFTP view: where it is, what is there, what is ticked.
class PaneController extends ChangeNotifier {
  PaneController(this.backend);
  final FileBackend backend;

  String path = '';
  List<FileEntry> entries = [];
  final Set<String> selected = {};
  bool loading = true;
  bool showHidden = false;
  String? error;
  bool _disposed = false;

  Iterable<FileEntry> get visible =>
      showHidden ? entries : entries.where((e) => !e.name.startsWith('.'));

  Future<void> open([String? target]) async {
    loading = true;
    error = null;
    _notify();
    try {
      final dest = target ?? (path.isEmpty ? await backend.home() : path);
      final list = await backend.list(dest);
      list.sort(
        (a, b) => a.isDir != b.isDir
            ? (a.isDir ? -1 : 1)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      if (dest != path) selected.clear();
      path = dest;
      entries = list;
      selected.retainAll(list.map((e) => e.name));
    } catch (e) {
      // Stay where we were; only the attempted folder failed.
      error = e.toString();
    }
    loading = false;
    _notify();
  }

  void toggle(String name) {
    selected.contains(name) ? selected.remove(name) : selected.add(name);
    _notify();
  }

  void setHidden(bool v) {
    showHidden = v;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class SftpTabView extends StatefulWidget {
  const SftpTabView(this.ws, this.tab, {super.key});
  final Workspace ws;
  final SftpTab tab;

  @override
  State<SftpTabView> createState() => _SftpTabViewState();
}

class _SftpTabViewState extends State<SftpTabView> {
  late final _local = PaneController(widget.ws.localFiles)..open();
  PaneController? _remote;

  @override
  void initState() {
    super.initState();
    widget.tab.addListener(_onTab);
    _onTab();
  }

  // A reconnect brings a new SFTP channel; reopen the same remote folder on it.
  void _onTab() {
    final backend = widget.tab.remote;
    if (backend == _remote?.backend) return;
    final previous = _remote;
    _remote = backend == null
        ? null
        : (PaneController(backend)
            ..open(previous?.path.isEmpty ?? true ? null : previous!.path));
    previous?.dispose();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.tab.removeListener(_onTab);
    _local.dispose();
    _remote?.dispose();
    super.dispose();
  }

  Future<void> _send(PaneController from, PaneController to) async {
    final items = from.entries
        .where((e) => from.selected.contains(e.name))
        .toList();
    final clash = items
        .where((e) => to.entries.any((x) => x.name == e.name))
        .map((e) => e.name)
        .toList();
    if (clash.isNotEmpty &&
        !await confirm(
          context,
          'Replace existing items?',
          '${clash.take(5).join(', ')}${clash.length > 5 ? ' and ${clash.length - 5} more' : ''} '
              'already exist in ${to.path}. Files with the same name are '
              'overwritten.',
          action: 'Replace',
        )) {
      return;
    }
    from.selected.clear();
    final dest = to.path;
    final src = from.path;
    final jobs = [
      for (final e in items)
        widget.ws.transfers.copy(from.backend, src, e, to.backend, dest),
    ];
    setState(() {});
    await Future.wait(jobs);
    if (mounted && to.path == dest) await to.open();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) {
        final remote = _remote;
        if (remote == null) {
          return Center(
            child: tab.state == TabState.connecting
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off, size: 40, color: scheme.outline),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          tab.error ?? 'Disconnected',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed: tab.start,
                            child: const Text('Reconnect'),
                          ),
                          OutlinedButton(
                            onPressed: () => widget.ws.closeTab(tab),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ],
                  ),
          );
        }
        final stacked = MediaQuery.sizeOf(context).width < 900;
        final panes = [
          Expanded(
            child: _Pane(
              _local,
              'Upload',
              () => _send(_local, remote),
              local: true,
            ),
          ),
          stacked ? const Divider() : const VerticalDivider(width: 1),
          Expanded(
            child: _Pane(
              remote,
              'Download',
              () => _send(remote, _local),
              local: false,
            ),
          ),
        ];
        return Column(
          children: [
            Expanded(
              child: stacked ? Column(children: panes) : Row(children: panes),
            ),
            _Transfers(widget.ws.transfers),
          ],
        );
      },
    );
  }
}

String _size(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 100 ? 0 : 1)} ${units[u]}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _date(DateTime? d) {
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${_months[d.month - 1]} ${d.day}';
  // Like `ls -l`: the time for recent files, the year for old ones.
  return DateTime.now().difference(d).inDays.abs() < 180
      ? '$day, ${two(d.hour)}:${two(d.minute)}'
      : '$day, ${d.year}';
}

class _Pane extends StatelessWidget {
  const _Pane(this.pane, this.sendLabel, this.onSend, {required this.local});
  final PaneController pane;
  final String sendLabel;
  final VoidCallback onSend;
  final bool local;

  Future<void> _guard(BuildContext context, Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (context.mounted) toast(context, e.toString());
    }
    await pane.open();
  }

  Future<void> _newFolder(BuildContext context) async {
    final r = await promptFields(
      context,
      'New folder',
      labels: ['Name'],
      action: 'Create',
    );
    final name = r?.first.trim() ?? '';
    if (name.isEmpty || !context.mounted) return;
    await _guard(
      context,
      () => pane.backend.mkdir(pane.backend.join(pane.path, name)),
    );
  }

  Future<void> _rename(BuildContext context, FileEntry e) async {
    final r = await promptFields(
      context,
      'Rename',
      labels: ['Name'],
      initial: [e.name],
      action: 'Rename',
    );
    final name = r?.first.trim() ?? '';
    if (name.isEmpty || name == e.name || !context.mounted) return;
    await _guard(
      context,
      () => pane.backend.rename(
        pane.backend.join(pane.path, e.name),
        pane.backend.join(pane.path, name),
      ),
    );
  }

  Future<void> _chmod(BuildContext context, FileEntry e) async {
    final r = await promptFields(
      context,
      'Permissions for ${e.name}',
      labels: ['Octal mode, e.g. 644'],
      initial: [e.mode!.toRadixString(8).padLeft(3, '0')],
      action: 'Apply',
    );
    final mode = int.tryParse(r?.first.trim() ?? '', radix: 8);
    if (r == null || !context.mounted) return;
    if (mode == null || mode > 0xFFF) {
      return toast(context, 'Enter an octal mode such as 644 or 755');
    }
    await _guard(
      context,
      () => pane.backend.chmod(pane.backend.join(pane.path, e.name), mode),
    );
  }

  Future<void> _delete(BuildContext context, List<FileEntry> items) async {
    if (!await confirm(
      context,
      'Delete ${items.length == 1 ? items.first.name : '${items.length} items'}?',
      'This permanently deletes ${items.any((e) => e.isDir) ? 'the selection, including everything inside folders,' : 'the selection'} '
          'from ${pane.backend.label}. It cannot be undone.',
      action: 'Delete',
      danger: true,
    )) {
      return;
    }
    if (!context.mounted) return;
    await _guard(context, () async {
      for (final e in items) {
        await pane.backend.delete(
          pane.backend.join(pane.path, e.name),
          isDir: e.isDir,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(fontSize: 11.5);
    final head = t.textTheme.labelSmall?.copyWith(letterSpacing: .4);
    return ListenableBuilder(
      listenable: pane,
      builder: (context, _) {
        final items = pane.visible.toList();
        final chosen = pane.entries
            .where((e) => pane.selected.contains(e.name))
            .toList();
        final one = chosen.length == 1 ? chosen.first : null;
        Widget tool(String label, VoidCallback? onTap, {bool danger = false}) =>
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                foregroundColor: danger ? scheme.error : scheme.onSurface,
              ),
              child: Text(label),
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
              child: Row(
                children: [
                  Icon(
                    local ? Icons.laptop_mac : Icons.dns_outlined,
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      pane.backend.label,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Parent folder',
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    onPressed: () => pane.open(pane.backend.parent(pane.path)),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, size: 16),
                    onPressed: pane.open,
                  ),
                  IconButton(
                    tooltip: pane.showHidden
                        ? 'Hide dotfiles'
                        : 'Show hidden dotfiles',
                    icon: Icon(
                      pane.showHidden
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 16,
                    ),
                    onPressed: () => pane.setHidden(!pane.showHidden),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                key: ValueKey(pane.path),
                controller: TextEditingController(text: pane.path),
                style: mono.copyWith(fontSize: 12),
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  hintText: 'Path',
                  prefixIcon: Icon(Icons.folder_open, size: 15),
                  prefixIconConstraints: BoxConstraints(minWidth: 34),
                  contentPadding: EdgeInsets.symmetric(vertical: 9),
                ),
                onSubmitted: pane.open,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
              child: Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: chosen.isEmpty ? null : onSend,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 30),
                    ),
                    icon: Icon(local ? Icons.upload : Icons.download, size: 15),
                    label: Text(
                      chosen.isEmpty
                          ? sendLabel
                          : '$sendLabel ${chosen.length}',
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          tool('New folder', () => _newFolder(context)),
                          tool(
                            'Rename',
                            one == null ? null : () => _rename(context, one),
                          ),
                          tool(
                            'Permissions',
                            one?.mode == null
                                ? null
                                : () => _chmod(context, one!),
                          ),
                          tool(
                            'Delete',
                            chosen.isEmpty
                                ? null
                                : () => _delete(context, chosen),
                            danger: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 26,
              padding: const EdgeInsets.only(right: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border.symmetric(
                  horizontal: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 66),
                  Expanded(child: Text('NAME', style: head)),
                  SizedBox(width: 44, child: Text('MODE', style: head)),
                  SizedBox(
                    width: 70,
                    child: Text('SIZE', textAlign: TextAlign.end, style: head),
                  ),
                  SizedBox(
                    width: 104,
                    child: Text(
                      'MODIFIED',
                      textAlign: TextAlign.end,
                      style: head,
                    ),
                  ),
                ],
              ),
            ),
            if (pane.loading) const LinearProgressIndicator(minHeight: 2),
            if (pane.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: Text(
                  pane.error!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            Expanded(
              child: items.isEmpty && !pane.loading
                  ? Center(child: Text('Empty folder', style: small))
                  : ListView.builder(
                      itemCount: items.length,
                      itemExtent: 32,
                      itemBuilder: (context, i) {
                        final e = items[i];
                        final on = pane.selected.contains(e.name);
                        return InkWell(
                          onTap: () => e.isDir
                              ? pane.open(pane.backend.join(pane.path, e.name))
                              : pane.toggle(e.name),
                          child: Container(
                            color: on
                                ? scheme.primary.withValues(alpha: .12)
                                : null,
                            padding: const EdgeInsets.only(right: 14),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 40,
                                  child: Transform.scale(
                                    scale: .82,
                                    child: Checkbox(
                                      value: on,
                                      onChanged: (_) => pane.toggle(e.name),
                                    ),
                                  ),
                                ),
                                Icon(
                                  e.isDir
                                      ? Icons.folder_rounded
                                      : Icons.insert_drive_file_outlined,
                                  size: 16,
                                  color: e.isDir
                                      ? scheme.primary
                                      : scheme.outline,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    e.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    e.mode == null
                                        ? ''
                                        : e.mode!
                                              .toRadixString(8)
                                              .padLeft(3, '0'),
                                    style: small?.merge(mono),
                                  ),
                                ),
                                SizedBox(
                                  width: 70,
                                  child: Text(
                                    e.isDir ? '—' : _size(e.size),
                                    textAlign: TextAlign.end,
                                    style: small,
                                  ),
                                ),
                                SizedBox(
                                  width: 104,
                                  child: Text(
                                    _date(e.modified),
                                    textAlign: TextAlign.end,
                                    style: small,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _Transfers extends StatelessWidget {
  const _Transfers(this.manager);
  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final list = manager.transfers;
        if (list.isEmpty) return const SizedBox.shrink();
        return Container(
          constraints: const BoxConstraints(maxHeight: 132),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Transfers',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: manager.clearFinished,
                    child: const Text('Clear finished'),
                  ),
                ],
              ),
              for (final t in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        t.error != null
                            ? Icons.error_outline
                            : t.cancelled
                            ? Icons.block
                            : t.done
                            ? Icons.check_circle_outline
                            : Icons.sync,
                        size: 15,
                        color: t.error != null ? scheme.error : scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: Text(
                          t.error == null ? t.name : '${t.name}: ${t.error}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: t.done
                            ? Text(
                                t.direction,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              )
                            : LinearProgressIndicator(
                                value: t.total == null || t.total == 0
                                    ? null
                                    : (t.bytes / t.total!)
                                          .clamp(0, 1)
                                          .toDouble(),
                              ),
                      ),
                      SizedBox(
                        width: 78,
                        child: Text(
                          t.cancelled ? 'cancelled' : _size(t.bytes),
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      if (!t.done)
                        InkWell(
                          onTap: () => manager.cancel(t),
                          child: const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.close, size: 14),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
