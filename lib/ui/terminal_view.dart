import 'dart:io';

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

  /// Copies the selected text, if any, and clears the selection.
  bool _copy() {
    final selection = _tab.controller.selection;
    if (selection == null) return false;
    Clipboard.setData(
      ClipboardData(text: _tab.terminal.buffer.getText(selection)),
    );
    _tab.controller.clearSelection();
    return true;
  }

  Future<void> _copyOrPaste() async {
    if (_copy()) return;
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text != null) _tab.terminal.paste(clip!.text!);
  }

  // Ctrl+C copies while text is selected and interrupts otherwise, like
  // Windows Terminal. Ctrl+Shift+C (and Cmd+C on a Mac) always copies.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyC ||
        !HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    return _copy() || shift ? KeyEventResult.handled : KeyEventResult.ignored;
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
                  // The package's text-input path is refused by Flutter on
                  // Windows (it attaches without a view), so nothing typed
                  // arrives. Reading key presses directly works everywhere
                  // except for macOS input methods, which keep the text path.
                  hardwareKeyboardOnly: !Platform.isMacOS,
                  theme: theme,
                  textStyle: TerminalStyle(fontSize: widget.settings.fontSize),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  onSecondaryTapDown: (_, _) => _copyOrPaste(),
                  onKeyEvent: _onKey,
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
                      Text(
                        'Press Enter or',
                        style: t.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
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
