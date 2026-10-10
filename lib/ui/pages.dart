import 'package:flutter/material.dart';

import '../core/models.dart';
import '../ssh/sessions.dart';
import 'common.dart';

class ForwardsPage extends StatelessWidget {
  const ForwardsPage(this.ws, {super.key});
  final Workspace ws;

  Future<void> _edit(BuildContext context, [PortForward? rule]) async {
    if (ws.vault.data.hosts.all.isEmpty) {
      return toast(context, 'Add a host first');
    }
    final saved = await showDialog<PortForward>(
      context: context,
      builder: (_) => _ForwardDialog(ws.vault.data, rule),
    );
    if (saved == null) return;
    await ws.forwards.stop(saved.id);
    ws.vault.data.forwards.put(saved);
    await ws.vault.commit();
  }

  String _describe(PortForward r, String host) => switch (r.kind) {
    ForwardKind.local =>
      '${r.bindHost}:${r.bindPort} here  →  ${r.destHost}:${r.destPort} via $host',
    ForwardKind.remote =>
      '${r.bindHost}:${r.bindPort} on $host  →  ${r.destHost}:${r.destPort} here',
    ForwardKind.dynamic =>
      'SOCKS proxy on ${r.bindHost}:${r.bindPort} via $host',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rules = ws.vault.data.forwards.all.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Port forwarding',
          actions: [
            FilledButton.icon(
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New rule'),
            ),
          ],
        ),
        Expanded(
          child: rules.isEmpty
              ? const EmptyState(
                  Icons.swap_horiz,
                  'No forwarding rules',
                  'Reach a database or web panel behind a server, expose a '
                      'local port to it, or run a SOCKS proxy through it.',
                )
              : ListenableBuilder(
                  listenable: ws.forwards,
                  builder: (context, _) => ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                    children: [
                      for (final r in rules)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Card(
                            child: Builder(
                              builder: (context) {
                                final run = ws.forwards.stateOf(r.id);
                                final host = ws.vault.data.hosts[r.hostId];
                                return ListTile(
                                  leading: Switch(
                                    value: run != null && run.error == null,
                                    onChanged: run?.starting == true
                                        ? null
                                        : (on) => on
                                              ? ws.forwards.start(r)
                                              : ws.forwards.stop(r.id),
                                  ),
                                  title: Text(
                                    r.label.isEmpty ? r.kind.name : r.label,
                                  ),
                                  subtitle: Text(
                                    run?.error ??
                                        (run?.starting == true
                                            ? 'Connecting…'
                                            : _describe(
                                                r,
                                                host?.title ?? '(deleted host)',
                                              )),
                                    textDirection: TextDirection.ltr,
                                    style: TextStyle(
                                      color: run?.error != null
                                          ? scheme.error
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  onTap: () => _edit(context, r),
                                  trailing: IconButton(
                                    tooltip: 'Delete',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                    ),
                                    onPressed: () async {
                                      await ws.forwards.stop(r.id);
                                      ws.vault.data.forwards.remove(r.id);
                                      await ws.vault.commit();
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _ForwardDialog extends StatefulWidget {
  const _ForwardDialog(this.data, this.rule);
  final VaultData data;
  final PortForward? rule;

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  late final _r = widget.rule;
  late ForwardKind _kind = _r?.kind ?? ForwardKind.local;
  late String? _hostId =
      widget.data.hosts[_r?.hostId]?.id ?? widget.data.hosts.all.first.id;
  late final _label = TextEditingController(text: _r?.label);
  late final _bindHost = TextEditingController(
    text: _r?.bindHost ?? '127.0.0.1',
  );
  late final _bindPort = TextEditingController(
    text: _r == null ? '' : '${_r.bindPort}',
  );
  late final _destHost = TextEditingController(
    text: _r?.destHost ?? '127.0.0.1',
  );
  late final _destPort = TextEditingController(
    text: _r == null ? '' : '${_r.destPort}',
  );

  void _save() {
    final bind = int.tryParse(_bindPort.text.trim());
    final dest = int.tryParse(_destPort.text.trim());
    final needsDest = _kind != ForwardKind.dynamic;
    bool bad(int? p) => p == null || p < 1 || p > 65535;
    if (_hostId == null || bad(bind) || (needsDest && bad(dest))) {
      toast(context, 'Ports must be numbers between 1 and 65535');
      return;
    }
    Navigator.pop(
      context,
      PortForward(
        id: _r?.id,
        label: _label.text.trim(),
        kind: _kind,
        hostId: _hostId!,
        bindHost: _bindHost.text.trim(),
        bindPort: bind!,
        destHost: needsDest ? _destHost.text.trim() : '',
        destPort: needsDest ? dest! : 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remote = _kind == ForwardKind.remote;
    return FormDialog(
      title: _r == null ? 'New forwarding rule' : 'Edit forwarding rule',
      onSave: _save,
      children: [
        SegmentedButton<ForwardKind>(
          segments: const [
            ButtonSegment(value: ForwardKind.local, label: Text('Local')),
            ButtonSegment(value: ForwardKind.remote, label: Text('Remote')),
            ButtonSegment(
              value: ForwardKind.dynamic,
              label: Text('Dynamic (SOCKS)'),
            ),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        field(_label, 'Label'),
        choice<String>('Through host', _hostId, {
          for (final h in widget.data.hosts.all) h.id: h.title,
        }, (v) => setState(() => _hostId = v)),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: field(
                _bindHost,
                remote
                    ? 'Listen address on the server'
                    : 'Listen address on this computer',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: field(_bindPort, 'Port')),
          ],
        ),
        if (_kind != ForwardKind.dynamic)
          Row(
            children: [
              Expanded(
                flex: 3,
                child: field(
                  _destHost,
                  remote
                      ? 'Destination, as seen from this computer'
                      : 'Destination, as seen from the server',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: field(_destPort, 'Port')),
            ],
          ),
      ],
    );
  }
}

class SnippetsPage extends StatelessWidget {
  const SnippetsPage(this.ws, {super.key});
  final Workspace ws;

  Future<void> _edit(BuildContext context, [Snippet? s]) async {
    final label = TextEditingController(text: s?.label);
    final command = TextEditingController(text: s?.command);
    final saved = await showDialog<Snippet>(
      context: context,
      builder: (c) => FormDialog(
        title: s == null ? 'New snippet' : 'Edit snippet',
        onSave: () {
          if (command.text.trim().isEmpty) return;
          Navigator.pop(
            c,
            Snippet(
              id: s?.id,
              label: label.text.trim(),
              command: command.text.trimRight(),
            ),
          );
        },
        children: [
          field(label, 'Label'),
          field(command, 'Command', lines: 6, code: true),
        ],
      ),
    );
    if (saved == null) return;
    ws.vault.data.snippets.put(saved);
    await ws.vault.commit();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 12,
    );
    final snippets = ws.vault.data.snippets.all.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Snippets',
          actions: [
            FilledButton.icon(
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New snippet'),
            ),
          ],
        ),
        Expanded(
          child: snippets.isEmpty
              ? const EmptyState(
                  Icons.code,
                  'No snippets',
                  'Save commands you run often, then send them to any open '
                      'terminal from its toolbar.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  children: [
                    for (final s in snippets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Card(
                          child: ListTile(
                            leading: const Icon(Icons.code),
                            title: Text(
                              s.label.isEmpty ? s.command : s.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              s.command,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textDirection: TextDirection.ltr,
                              style: muted.merge(mono),
                            ),
                            onTap: () => _edit(context, s),
                            trailing: IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () async {
                                ws.vault.data.snippets.remove(s.id);
                                await ws.vault.commit();
                              },
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class KnownHostsPage extends StatelessWidget {
  const KnownHostsPage(this.ws, {super.key});
  final Workspace ws;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 12,
    );
    final known = ws.vault.data.knownHosts.all.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader('Known hosts'),
        Expanded(
          child: known.isEmpty
              ? const EmptyState(
                  Icons.verified_user_outlined,
                  'No servers trusted yet',
                  'The key of each server you connect to is pinned here and '
                      'synced, so a changed key is noticed on every device.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  children: [
                    for (final k in known)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Card(
                          child: ListTile(
                            leading: const Icon(Icons.verified_user_outlined),
                            title: Text(k.id, textDirection: TextDirection.ltr),
                            subtitle: Text(
                              '${k.type}  ${k.fingerprint}',
                              overflow: TextOverflow.ellipsis,
                              style: muted.merge(mono),
                            ),
                            trailing: IconButton(
                              tooltip: 'Forget this key',
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () async {
                                ws.vault.data.knownHosts.remove(k.id);
                                await ws.vault.commit();
                              },
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
