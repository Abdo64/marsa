import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/vault.dart';
import 'ssh/sessions.dart';
import 'ui/common.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/unlock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  final registry = VaultRegistry(Directory('${dir.path}/vaults'));
  await registry.load();
  final settings = AppSettings(File('${dir.path}/settings.json'));
  await settings.load();
  runApp(MarsaApp(registry: registry, settings: settings));
}

class MarsaApp extends StatefulWidget {
  const MarsaApp({super.key, required this.registry, required this.settings});
  final VaultRegistry registry;
  final AppSettings settings;

  @override
  State<MarsaApp> createState() => _MarsaAppState();
}

class _MarsaAppState extends State<MarsaApp> {
  Workspace? _workspace;

  Future<void> _lock() async {
    final ws = _workspace;
    setState(() => _workspace = null);
    await ws?.shutdown();
    ws?.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) => MaterialApp(
          title: 'Marsa',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: widget.settings.themeMode,
          home: _workspace == null
              ? UnlockPage(
                  registry: widget.registry,
                  onUnlocked: (vault) => setState(
                      () => _workspace = Workspace(vault, DialogPrompter())),
                )
              : AppShell(
                  workspace: _workspace!,
                  registry: widget.registry,
                  settings: widget.settings,
                  onLock: _lock,
                ),
        ),
      );
}
