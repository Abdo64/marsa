import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../ssh/sessions.dart';
import 'theme.dart';

class TerminalTabView extends StatefulWidget {
  const TerminalTabView(
    this.ws,
    this.tab,
    this.settings, {
    super.key,
    required this.visible,
  });
  final Workspace ws;
  final TerminalTab tab;
  final AppSettings settings;
  final bool visible;

  @override
  State<TerminalTabView> createState() => _TerminalTabViewState();
}

class _TerminalTabViewState extends State<TerminalTabView> {
  final _focus = FocusNode();

  TerminalTab get _tab => widget.tab;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _focus.requestFocus();
  }

  @override
  void didUpdateWidget(TerminalTabView old) {
    super.didUpdateWidget(old);
    // Typing should land in the terminal as soon as its tab is shown.
    if (widget.visible && !old.visible) _focus.requestFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _copyOrPaste() async {
    final selection = _tab.controller.selection;
    if (selection != null) {
      await Clipboard.setData(
        ClipboardData(text: _tab.terminal.buffer.getText(selection)),
      );
      _tab.controller.clearSelection();
      return;
    }
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null) _tab.terminal.paste(clip!.text!);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final theme = resolveTerminalTheme(
      widget.settings.terminalTheme,
      t.brightness,
    );
    final snippets = widget.ws.vault.data.snippets.all.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return ListenableBuilder(
      listenable: _tab,
      builder: (context, _) => Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 14, right: 4),
            color: scheme.surfaceContainerLowest,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_tab.host.title}  ·  ${switch (_tab.state) {
                      TabState.connecting => 'connecting…',
                      TabState.connected => 'connected',
                      TabState.closed => 'disconnected',
                    }}',
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_tab.state == TabState.closed)
                  TextButton.icon(
                    onPressed: _tab.start,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reconnect'),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Run a snippet',
                  enabled:
                      snippets.isNotEmpty && _tab.state == TabState.connected,
                  icon: const Icon(Icons.code, size: 18),
                  onSelected: (cmd) {
                    _tab.send('$cmd\r');
                    _focus.requestFocus();
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
                  icon: const Icon(Icons.folder_copy_outlined, size: 18),
                  onPressed: () => widget.ws.openSftp(_tab.host),
                ),
                IconButton(
                  tooltip: 'Close session',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => widget.ws.closeTab(_tab),
                ),
              ],
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: theme.background,
              child: ListenableBuilder(
                listenable: widget.settings,
                builder: (context, _) => TerminalView(
                  _tab.terminal,
                  controller: _tab.controller,
                  focusNode: _focus,
                  theme: theme,
                  textStyle: TerminalStyle(fontSize: widget.settings.fontSize),
                  padding: const EdgeInsets.all(8),
                  onSecondaryTapDown: (_, _) => _copyOrPaste(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
