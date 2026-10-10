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
                child: Column(
                  children: [
                    if (ws.tabs.isNotEmpty) _TabStrip(ws),
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
            ],
          ),
        ),
      );
    },
  );
}

/// Open sessions as tabs across the top, with the active tab's actions on
/// the right.
class _TabStrip extends StatelessWidget {
  const _TabStrip(this.ws);
  final Workspace ws;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = ws.active;
    final snippets = ws.vault.data.snippets.all.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: Palette.of(context).sidebar,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final tab in ws.tabs)
                  ListenableBuilder(
                    listenable: tab,
                    builder: (context, _) => _Tab(
                      tab: tab,
                      selected: tab == active,
                      onTap: () => ws.focus(tab),
                      onClose: () => ws.closeTab(tab),
                    ),
                  ),
              ],
            ),
          ),
          if (active is TerminalTab) ...[
            PopupMenuButton<String>(
              tooltip: 'Run a snippet',
              enabled: snippets.isNotEmpty,
              icon: const Icon(Icons.code, size: 17),
              onSelected: (cmd) {
                active.send('$cmd\r');
                active.focusNode.requestFocus();
              },
              itemBuilder: (_) => [
                for (final s in snippets)
                  PopupMenuItem(
                    value: s.command,
                    child: Text(
                      s.label.isEmpty ? s.command : s.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            IconButton(
              tooltip: 'Browse this server\'s files (SFTP)',
              icon: const Icon(Icons.folder_copy_outlined, size: 17),
              onPressed: () => ws.openSftp(active.host),
            ),
          ],
          if (active is SftpTab)
            IconButton(
              tooltip: 'Open a terminal on this server',
              icon: const Icon(Icons.terminal, size: 17),
              onPressed: () => ws.openTerminal(active.host),
            ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });
  final AppTab tab;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = Palette.of(context);
    final fg = selected ? scheme.onSurface : palette.muted;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 130, maxWidth: 220),
        padding: const EdgeInsets.only(left: 12, right: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.surface : null,
          border: Border(
            top: BorderSide(
              width: 2,
              color: selected ? scheme.primary : Colors.transparent,
            ),
            right: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: switch (tab.state) {
                  TabState.connected => palette.success,
                  TabState.connecting => palette.warning,
                  TabState.closed => scheme.error,
                },
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              tab is TerminalTab ? Icons.terminal : Icons.folder_copy_outlined,
              size: 15,
              color: fg,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                tab.host.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: 'Close',
              child: InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(5),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(Icons.close, size: 14, color: fg),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(this.ws, this.compact, this.onLock);
  final Workspace ws;
  final bool compact;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    Widget item(Section s, String label, IconData icon) => _Item(
      icon: icon,
      label: label,
      compact: compact,
      selected: ws.active == null && ws.section == s,
      onTap: () => ws.show(s),
    );
    return Container(
      width: compact ? 56 : 212,
      color: Palette.of(context).sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 14,
              10,
              compact ? 4 : 4,
              10,
            ),
            child: Row(
              children: [
                if (!compact) ...[
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(
                      Icons.anchor,
                      size: 16,
                      color: scheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ws.vault.info.name,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.titleSmall,
                        ),
                        Text(switch (ws.vault.syncState) {
                          SyncState.off => 'This device only',
                          SyncState.idle => 'Synced',
                          SyncState.syncing => 'Syncing…',
                          SyncState.error => 'Sync failed',
                          SyncState.passwordChanged => 'Password changed',
                        }, style: t.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ],
                _SyncButton(ws.vault),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final e in _sections.entries)
                  item(e.key, e.value.$1, e.value.$2),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                item(Section.settings, 'Settings', Icons.settings_outlined),
                _Item(
                  icon: Icons.lock_outline,
                  label: 'Lock vault',
                  compact: compact,
                  selected: false,
                  onTap: onLock,
                ),
              ],
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
  });
  final IconData icon;
  final String label;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSurface : Palette.of(context).muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Tooltip(
        message: compact ? label : '',
        child: Material(
          color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: onTap,
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
                  Icon(icon, size: 17, color: selected ? scheme.primary : fg),
                  if (!compact) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
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
      icon: Icon(icon, size: 17, color: color),
      onPressed: vault.syncState == SyncState.syncing
          ? null
          : () => _tap(context),
    );
  }
}
