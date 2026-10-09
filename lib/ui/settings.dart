import 'package:flutter/material.dart';

import '../core/vault.dart';
import '../ssh/sessions.dart';
import 'common.dart';
import 'sync_dialog.dart';
import 'theme.dart';

const appVersion = '0.1.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
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

  VaultSession get _vault => workspace.vault;

  Future<void> _configureSync(BuildContext context) async {
    final cfg = await showSyncDialog(
      context,
      vaultName: _vault.info.name,
      data: _vault.data,
      current: _vault.sync,
    );
    if (cfg == null || !context.mounted) return;
    await busy(context, () => _vault.setSync(cfg));
    if (context.mounted) {
      toast(context, _vault.syncError ?? 'Sync is on and up to date');
    }
  }

  Future<void> _stopSync(BuildContext context) async {
    if (!await confirm(
      context,
      'Stop syncing this vault?',
      'This device keeps its copy. The file at the sync location is left as it is.',
      action: 'Stop syncing',
    )) {
      return;
    }
    await _vault.setSync(null);
  }

  Future<void> _changePassword(BuildContext context) async {
    final r = await promptFields(
      context,
      'Change master password',
      message: _vault.sync == null
          ? null
          : 'Other devices will be asked for the new password the next time '
                'they sync.',
      labels: ['New master password', 'Repeat new master password'],
      obscure: [true, true],
      action: 'Change',
    );
    if (r == null || !context.mounted) return;
    if (r[0].length < 8 || r[0] != r[1]) {
      return toast(
        context,
        'Passwords must match and be at least 8 characters long',
      );
    }
    final ok = await busy(context, () async {
      await _vault.changePassword(r[0]);
      return true;
    });
    if (ok == true && context.mounted) {
      toast(context, 'Master password changed');
    }
  }

  Future<void> _setRemember(BuildContext context, bool on) async {
    try {
      on ? await registry.remember(_vault) : await registry.forget(_vault.info);
    } catch (e) {
      if (context.mounted) toast(context, 'Could not remember this vault: $e');
    }
  }

  Future<void> _rename(BuildContext context) async {
    final r = await promptFields(
      context,
      'Rename vault',
      labels: ['Name'],
      initial: [_vault.info.name],
    );
    if (r == null || r.first.trim().isEmpty) return;
    await registry.rename(_vault.info, r.first.trim());
    await _vault.commit();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(
      color: t.colorScheme.onSurfaceVariant,
    );
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.textTheme.titleSmall),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );

    final sync = _vault.sync;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        children: [
          const PageHeader('Settings'),
          section('Appearance', [
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark'),
                ),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) =>
                  settings.update(() => settings.themeMode = s.first),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: 320,
              child: choice<String>(
                'Terminal colours',
                settings.terminalTheme,
                {
                  'auto': 'Follow the app theme',
                  for (final name in terminalThemes.keys) name: name,
                },
                (v) => settings.update(() => settings.terminalTheme = v!),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('Terminal font size  ${settings.fontSize.round()}'),
                Expanded(
                  child: Slider(
                    min: 9,
                    max: 24,
                    divisions: 15,
                    value: settings.fontSize,
                    onChanged: (v) =>
                        settings.update(() => settings.fontSize = v),
                  ),
                ),
              ],
            ),
          ]),
          section('Vault: ${_vault.info.name}', [
            Text(
              switch (_vault.syncState) {
                SyncState.off =>
                  'This vault lives only on this device. Turn on sync to '
                      'use it on your other devices or share it with your '
                      'team.',
                SyncState.error => 'Sync failed: ${_vault.syncError}',
                SyncState.passwordChanged =>
                  'The master password was changed on another device. Use '
                      'the cloud icon in the sidebar to enter the new one.',
                _ =>
                  'Syncing through ${sync?.summary}'
                      '${_vault.lastSynced == null ? '' : '\nLast synced at ${TimeOfDay.fromDateTime(_vault.lastSynced!).format(context)}'}',
              },
              style:
                  _vault.syncState == SyncState.error ||
                      _vault.syncState == SyncState.passwordChanged
                  ? TextStyle(color: t.colorScheme.error)
                  : muted,
            ),
            if (sync?.fingerprint.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Sync server key: ${sync!.fingerprint}',
                  style: muted?.merge(mono),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _configureSync(context),
                  child: Text(sync == null ? 'Set up sync' : 'Change sync'),
                ),
                if (sync != null) ...[
                  OutlinedButton(
                    onPressed: () => busy(context, _vault.syncNow),
                    child: const Text('Sync now'),
                  ),
                  OutlinedButton(
                    onPressed: () => _stopSync(context),
                    child: const Text('Stop syncing'),
                  ),
                ],
                OutlinedButton(
                  onPressed: () => _rename(context),
                  child: const Text('Rename'),
                ),
                OutlinedButton(
                  onPressed: () => _changePassword(context),
                  child: const Text('Change master password'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              value: _vault.info.remembered,
              onChanged: (on) => _setRemember(context, on),
              contentPadding: EdgeInsets.zero,
              title: const Text('Remember on this device'),
              subtitle: Text(
                'Open this vault without the master password. Its key is '
                'kept in this computer\'s credential store, so anyone who '
                'can use your signed-in account can open the vault. Sync and '
                'other devices are not affected.',
                style: muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'To share a vault with teammates, give them the sync location '
              'and the master password; they add it with "Join a synced '
              'vault" on the unlock screen. Keep personal and team servers '
              'in separate vaults.',
              style: muted,
            ),
          ]),
          section('About', [
            Text('Marsa $appVersion', style: t.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              'Open-source SSH and SFTP client with encrypted, self-synced '
              'vaults. Released under the MIT License.',
              style: muted,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Marsa',
                applicationVersion: appVersion,
              ),
              child: const Text('Open-source licenses'),
            ),
          ]),
        ],
      ),
    );
  }
}
