import 'package:flutter/material.dart';
import 'mirpg_remote_theme.dart';

final RegExp _avdNamePattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final RegExp _avdReservedName =
    RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$', caseSensitive: false);

bool isValidAvdName(String name) =>
    _avdNamePattern.hasMatch(name) &&
    !name.startsWith('.') &&
    !_avdReservedName.hasMatch(name);

/// Asks for an emulator name. Returns the chosen name, or null if dismissed.
Future<String?> showAvdNameSheet(
  BuildContext context, {
  required String title,
  required String initialName,
  required String note,
  required bool Function(String) isTaken,
  String confirmLabel = 'Create',
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AvdNameSheet(
        title: title,
        initialName: initialName,
        note: note,
        isTaken: isTaken,
        confirmLabel: confirmLabel,
      ),
    );

Future<bool> confirmAvdDelete(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $name?'),
        content: Text('Permanently deletes $name and everything in it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    ) ??
    false;

class _AvdNameSheet extends StatefulWidget {
  const _AvdNameSheet({
    required this.title,
    required this.initialName,
    required this.note,
    required this.isTaken,
    required this.confirmLabel,
  });

  final String title;
  final String initialName;
  final String note;
  final bool Function(String) isTaken;
  final String confirmLabel;

  @override
  State<_AvdNameSheet> createState() => _AvdNameSheetState();
}

class _AvdNameSheetState extends State<_AvdNameSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _problem(String name) {
    if (name.isEmpty) return null;
    if (!isValidAvdName(name)) return 'Use letters, numbers, . _ -';
    if (widget.isTaken(name)) return 'Name already used';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final name = value.text;
        final problem = _problem(name);
        final valid = name.isNotEmpty && problem == null;
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              MirpgRemoteTheme.pageMargin,
              4,
              MirpgRemoteTheme.pageMargin,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    errorText: problem,
                  ),
                  onSubmitted: (_) {
                    if (valid) Navigator.pop(context, name);
                  },
                ),
                const SizedBox(height: 8),
                Text(widget.note, style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: valid ? () => Navigator.pop(context, name) : null,
                      child: Text(widget.confirmLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
