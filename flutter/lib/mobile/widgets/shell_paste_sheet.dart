import 'package:flutter/material.dart';
import '../../models/input_modifier_utils.dart';
import 'mirpg_remote_theme.dart';

class ShellPasteSheet extends StatelessWidget {
  const ShellPasteSheet({
    super.key,
    required this.targetLabel,
    required this.text,
  });

  final String targetLabel;
  final String text;

  @override
  Widget build(BuildContext context) {
    final inspection = inspectTerminalPaste(text);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          MirpgRemoteTheme.pageMargin,
          16,
          MirpgRemoteTheme.pageMargin,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Review Shell paste', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Target: $targetLabel',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (inspection.hasLineBreaks)
              const _PasteWarning(
                icon: Icons.play_disabled_outlined,
                text:
                    'Multiline text is staged locally. Nothing below is sent or run until you use Run / Enter.',
              ),
            if (inspection.hasControlWarning) ...[
              const SizedBox(height: 8),
              _PasteWarning(
                icon: Icons.warning_amber_rounded,
                text:
                    'Control characters: ${inspection.controlCharacters.join(', ')}',
              ),
            ],
            const SizedBox(height: 12),
            Text('Exact text', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectionArea(
                  child: Text(
                    text,
                    key: const ValueKey('shell-paste-exact-text'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
            if (inspection.hasControlWarning) ...[
              const SizedBox(height: 12),
              Text('Visible controls', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(
                terminalPasteVisibleControls(text),
                key: const ValueKey('shell-paste-visible-controls'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Insert text'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PasteWarning extends StatelessWidget {
  const _PasteWarning({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: MirpgRemoteTheme.raised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MirpgRemoteTheme.outline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      );
}
