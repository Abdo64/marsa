import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../ssh/sessions.dart';
import 'theme.dart';

class TerminalTabView extends StatefulWidget {
  const TerminalTabView(
    this.tab,
    this.settings, {
    super.key,
    required this.visible,
  });
  final TerminalTab tab;
  final AppSettings settings;
  final bool visible;

  @override
  State<TerminalTabView> createState() => _TerminalTabViewState();
}

class _TerminalTabViewState extends State<TerminalTabView> {
  TerminalTab get _tab => widget.tab;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _tab.focusNode.requestFocus();
  }

  @override
  void didUpdateWidget(TerminalTabView old) {
    super.didUpdateWidget(old);
    // Typing should land in the terminal as soon as its tab is shown.
    if (widget.visible && !old.visible) _tab.focusNode.requestFocus();
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
    return ListenableBuilder(
      listenable: Listenable.merge([_tab, widget.settings]),
      builder: (context, _) {
        final theme = resolveTerminalTheme(
          widget.settings.terminalTheme,
          t.brightness,
        );
        return ColoredBox(
          color: theme.background,
          child: Column(
            children: [
              Expanded(
                child: TerminalView(
                  _tab.terminal,
                  controller: _tab.controller,
                  focusNode: _tab.focusNode,
                  theme: theme,
                  textStyle: TerminalStyle(fontSize: widget.settings.fontSize),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  onSecondaryTapDown: (_, _) => _copyOrPaste(),
                ),
              ),
              if (_tab.state == TabState.closed)
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    border: Border(
                      top: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.link_off, size: 16, color: scheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _tab.error ?? 'Session ended',
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodySmall,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _tab.start,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Reconnect'),
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
