import 'package:flutter/material.dart';

import '../core/vault.dart';
import '../ssh/sessions.dart';
import 'common.dart';
import 'hosts.dart';
import 'keychain.dart';
import 'pages.dart';
import 'settings.dart';
import 'sftp_view.dart';
import 'terminal_view.dart';
import 'theme.dart';

const _sections = {
  Section.hosts: ('Hosts', Icons.dns_outlined),
  Section.keychain: ('Keychain', Icons.key_outlined),
  Section.forwards: ('Port forwarding', Icons.swap_horiz),
  Section.snippets: ('Snippets', Icons.code),
  Section.knownHosts: ('Known hosts', Icons.verified_user_outlined),
  Section.settings: ('Settings', Icons.settings_outlined),
};

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.workspace,
    required this.registry,
    required this.settings,
    required this.onLock,
  });
  final Workspace workspace;
  final VaultRegistry registry;
  final AppSettings settings;
  final Future<void> Function() onLock;

  Future<void> _lock(BuildContext context) async {
    final ws = workspace;
    final open =
        ws.tabs.length +
        ws.vault.data.forwards.all.where((f) => ws.forwards.isOn(f.id)).length;
    if (open > 0 &&
        !await confirm(
          context,
          'Lock the vault?',
          'This closes $open open session(s) and forward(s).',
          action: 'Lock',
        )) {
      return;
    }
    await onLock();
  }

  Widget _page() => switch (workspace.section) {
    Section.hosts => HostsPage(workspace),
    Section.keychain => KeychainPage(workspace),
    Section.forwards => ForwardsPage(workspace),
    Section.snippets => SnippetsPage(workspace),
    Section.knownHosts => KnownHostsPage(workspace),
    Section.settings => SettingsPage(
      workspace: workspace,
      registry: registry,
      settings: settings,
      onLock: onLock,
    ),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([workspace, workspace.vault, registry]),
    builder: (context, _) {
      final ws = workspace;
      final compact = MediaQuery.sizeOf(context).width < 820;
      final index = ws.active == null ? 0 : 1 + ws.tabs.indexOf(ws.active!);
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              _Sidebar(ws, compact, () => _lock(context)),
              const VerticalDivider(width: 1),
              Expanded(
                child: IndexedStack(
                  index: index,
                  children: [
                    _page(),
                    for (final tab in ws.tabs)
                      KeyedSubtree(
                        key: ObjectKey(tab),
                        child: tab is TerminalTab
                            ? TerminalTabView(
                                ws,
                                tab,
                                settings,
                                visible: tab == ws.active,
                              )
                            : SftpTabView(ws, tab as SftpTab),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(this.ws, this.compact, this.onLock);
  final Workspace ws;
  final bool compact;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: compact ? 56 : 220,
      color: scheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 14,
              12,
              compact ? 4 : 6,
              8,
            ),
            child: Row(
              children: [
                if (!compact) ...[
                  Icon(Icons.anchor, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ws.vault.info.name,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
                _SyncButton(ws.vault),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final e in _sections.entries)
                  _Item(
                    icon: e.value.$2,
                    label: e.value.$1,
                    compact: compact,
                    selected: ws.active == null && ws.section == e.key,
                    onTap: () => ws.show(e.key),
                  ),
                if (ws.tabs.isNotEmpty) ...[
                  const Divider(height: 17),
                  if (!compact)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 2, 0, 4),
                      child: Text(
                        'SESSIONS',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final tab in ws.tabs)
                    ListenableBuilder(
                      listenable: tab,
                      builder: (context, _) => _Item(
                        icon: tab is TerminalTab
                            ? Icons.terminal
                            : Icons.folder_copy_outlined,
                        iconColor: switch (tab.state) {
                          TabState.connected => Colors.green,
                          TabState.connecting => Colors.amber,
                          TabState.closed => scheme.error,
                        },
                        label: tab.host.title,
                        compact: compact,
                        selected: ws.active == tab,
                        onTap: () => ws.focus(tab),
                        onClose: () => ws.closeTab(tab),
                      ),
                    ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(6),
            child: _Item(
              icon: Icons.lock_outline,
              label: 'Lock vault',
              compact: compact,
              selected: false,
              onTap: onLock,
            ),
          ),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    required this.compact,
    required this.selected,
    required this.onTap,
    this.iconColor,
    this.onClose,
  });
  final IconData icon;
  final String label;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;
  final Color? iconColor;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Tooltip(
        message: compact ? label : '',
        child: Material(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            // The compact rail has no room for a close button.
            onLongPress: compact ? onClose : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 0 : 10,
                vertical: 8,
              ),
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: iconColor ?? fg),
                  if (!compact) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontSize: 13),
                      ),
                    ),
                    if (onClose != null)
                      InkWell(
                        onTap: onClose,
                        borderRadius: BorderRadius.circular(10),
                        child: Icon(Icons.close, size: 15, color: fg),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton(this.vault);
  final VaultSession vault;

  Future<void> _tap(BuildContext context) async {
    switch (vault.syncState) {
      case SyncState.off:
        toast(context, 'Sync is off. Turn it on in Settings.');
      case SyncState.passwordChanged:
        final r = await promptFields(
          context,
          'Vault password changed',
          message:
              'The master password was changed on another device. Enter '
              'the new one to keep syncing.',
          labels: ['New master password'],
          obscure: [true],
        );
        if (r == null || !context.mounted) return;
        await busy(context, () => vault.adoptRemotePassword(r.first));
      default:
        await vault.syncNow();
        if (context.mounted) {
          toast(context, vault.syncError ?? 'Vault is in sync');
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, tip) = switch (vault.syncState) {
      SyncState.off => (Icons.cloud_off_outlined, scheme.outline, 'Not synced'),
      SyncState.idle => (
        Icons.cloud_done_outlined,
        scheme.primary,
        'Synced. Click to sync now.',
      ),
      SyncState.syncing => (Icons.sync, scheme.primary, 'Syncing…'),
      SyncState.error => (
        Icons.sync_problem,
        scheme.error,
        'Sync failed: ${vault.syncError}',
      ),
      SyncState.passwordChanged => (
        Icons.key_off_outlined,
        scheme.error,
        'Password changed on another device',
      ),
    };
    return IconButton(
      tooltip: tip,
      icon: Icon(icon, size: 18, color: color),
      onPressed: vault.syncState == SyncState.syncing
          ? null
          : () => _tap(context),
    );
  }
}
