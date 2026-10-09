import 'package:flutter/material.dart';

import '../core/crypto.dart';
import '../core/vault.dart';
import 'common.dart';
import 'sync_dialog.dart';

class UnlockPage extends StatefulWidget {
  const UnlockPage(
      {super.key, required this.registry, required this.onUnlocked});
  final VaultRegistry registry;
  final ValueChanged<VaultSession> onUnlocked;

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  VaultInfo? _selected;
  bool _working = false;
  String? _error;

  VaultRegistry get _reg => widget.registry;

  @override
  void initState() {
    super.initState();
    if (_reg.vaults.isNotEmpty) _selected = _reg.vaults.first;
  }

  Future<void> _run(Future<VaultSession?> Function() work) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final v = await work();
      if (v != null) return widget.onUnlocked(v);
    } on WrongPassword {
      _error = 'Wrong master password';
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _working = false);
  }

  void _unlock() {
    final v = _selected;
    if (v == null || _password.text.isEmpty) return;
    _run(() => _reg.unlock(v, _password.text));
  }

  Future<List<String>?> _askNewVault(String title) async {
    final r = await promptFields(
      context,
      title,
      message: 'The master password encrypts everything in the vault. It is '
          'never stored and cannot be recovered if you forget it.',
      labels: ['Vault name', 'Master password', 'Repeat master password'],
      obscure: [false, true, true],
      initial: [_reg.vaults.isEmpty ? 'Personal' : '', '', ''],
      action: 'Create',
    );
    if (r == null || !mounted) return null;
    if (r[0].trim().isEmpty || r[1].length < 8) {
      toast(context, 'Give the vault a name and a password of 8+ characters');
      return null;
    }
    if (r[1] != r[2]) {
      toast(context, 'The two passwords do not match');
      return null;
    }
    return r;
  }

  Future<void> _create() async {
    final r = await _askNewVault('New vault');
    if (r != null) _run(() => _reg.create(r[0].trim(), r[1]));
  }

  Future<void> _join() async {
    final r = await promptFields(
      context,
      'Join a synced vault',
      message: 'Use this on a new device, or to add a vault a teammate '
          'shared with you. You need the vault\'s master password and '
          'access to where it is synced.',
      labels: ['Name for this vault', 'Master password'],
      obscure: [false, true],
      action: 'Next',
    );
    if (r == null || !mounted || r[0].trim().isEmpty) return;
    final cfg =
        await showSyncDialog(context, vaultName: r[0].trim(), joining: true);
    if (cfg != null) _run(() => _reg.join(r[0].trim(), r[1], cfg));
  }

  Future<void> _remove(VaultInfo v) async {
    final ok = await confirm(
      context,
      'Remove "${v.name}" from this device?',
      'The local copy is deleted. A synced copy and other devices are not '
          'touched. If this vault is not synced, its contents are gone for '
          'good.',
      action: 'Remove',
      danger: true,
    );
    if (!ok) return;
    await _reg.remove(v);
    setState(() => _selected = _reg.vaults.isEmpty ? null : _reg.vaults.first);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.anchor, size: 40, color: scheme.primary),
                const SizedBox(height: 8),
                Text('Marsa',
                    textAlign: TextAlign.center,
                    style: t.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                    _reg.vaults.isEmpty
                        ? 'Create a vault to keep your servers and keys in.'
                        : 'Unlock a vault to continue.',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 24),
                if (_reg.vaults.isNotEmpty) ...[
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: [
                      for (final v in _reg.vaults)
                        ListTile(
                          selected: v == _selected,
                          selectedTileColor: scheme.primaryContainer,
                          leading: Icon(v == _selected
                              ? Icons.lock_open_outlined
                              : Icons.lock_outline),
                          title: Text(v.name),
                          trailing: IconButton(
                            tooltip: 'Remove from this device',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: _working ? null : () => _remove(v),
                          ),
                          onTap: () {
                            setState(() => _selected = v);
                            _focus.requestFocus();
                          },
                        ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    focusNode: _focus,
                    autofocus: true,
                    obscureText: true,
                    enabled: !_working,
                    decoration:
                        const InputDecoration(labelText: 'Master password'),
                    onSubmitted: (_) => _unlock(),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _working ? null : _unlock,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(_working ? 'Unlocking…' : 'Unlock'),
                    ),
                  ),
                ] else if (_working)
                  const Center(child: CircularProgressIndicator()),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error)),
                ],
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _working ? null : _create,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New vault'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _working ? null : _join,
                      icon: const Icon(Icons.cloud_download_outlined, size: 18),
                      label: const Text('Join a synced vault'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
