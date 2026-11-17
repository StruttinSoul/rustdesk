import 'package:flutter/material.dart';
import '../../common.dart' show translate;
import '../../models/emulator_labels.dart';
import 'mirpg_remote_theme.dart';

final RegExp _avdNamePattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final RegExp _avdReservedName =
    RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$', caseSensitive: false);

bool isValidAvdName(String name) =>
    _avdNamePattern.hasMatch(name) &&
    !name.startsWith('.') &&
    !_avdReservedName.hasMatch(name);

String _untranslated(String key) => key;

/// Asks for an emulator name (Rename). Returns the chosen name, or null if
/// dismissed.
Future<String?> showAvdNameSheet(
  BuildContext context, {
  required String title,
  required String initialName,
  required String note,
  required bool Function(String) isTaken,
  String confirmLabel = 'Create',
  String Function(String) tr = _untranslated,
}) async {
  final result = await _showNameSheet(context,
      title: title,
      initialName: initialName,
      note: note,
      isTaken: isTaken,
      confirmLabel: confirmLabel,
      withLabel: false,
      tr: tr);
  return result?.name;
}

typedef AvdCreateResult = ({String name, String label});

/// Asks for an emulator name and an optional phone-side label (New and
/// Clone). Returns null if dismissed; `label` is `''` when left empty.
Future<AvdCreateResult?> showAvdCreateSheet(
  BuildContext context, {
  required String title,
  required String initialName,
  required String note,
  required bool Function(String) isTaken,
  String confirmLabel = 'Create',
  String Function(String) tr = translate,
}) =>
    _showNameSheet(context,
        title: title,
        initialName: initialName,
        note: note,
        isTaken: isTaken,
        confirmLabel: confirmLabel,
        withLabel: true,
        tr: tr);

Future<AvdCreateResult?> _showNameSheet(
  BuildContext context, {
  required String title,
  required String initialName,
  required String note,
  required bool Function(String) isTaken,
  required String confirmLabel,
  required bool withLabel,
  required String Function(String) tr,
}) =>
    showModalBottomSheet<AvdCreateResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AvdNameSheet(
        title: title,
        initialName: initialName,
        note: note,
        isTaken: isTaken,
        confirmLabel: confirmLabel,
        withLabel: withLabel,
        tr: tr,
      ),
    );

/// A two-button confirmation whose confirming button is the destructive red.
Future<bool> showDestructiveConfirmation(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required String cancelLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(cancelLabel)),
          FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MirpgRemoteTheme.destructiveFill,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(confirmLabel)),
        ],
      ),
    ) ??
    false;

Future<bool> confirmAvdDelete(
  BuildContext context,
  String name, {
  String Function(String) tr = translate,
}) =>
    showDestructiveConfirmation(
      context,
      title: tr('Delete {$name}?'),
      body: tr(
          "Deletes {$name} and everything in it, including the game sign-in. This can't be undone."),
      confirmLabel: tr('Delete'),
      cancelLabel: tr('Cancel'),
    );

class _AvdNameSheet extends StatefulWidget {
  const _AvdNameSheet({
    required this.title,
    required this.initialName,
    required this.note,
    required this.isTaken,
    required this.confirmLabel,
    required this.withLabel,
    required this.tr,
  });

  final String title;
  final String initialName;
  final String note;
  final bool Function(String) isTaken;
  final String confirmLabel;
  final bool withLabel;
  final String Function(String) tr;

  @override
  State<_AvdNameSheet> createState() => _AvdNameSheetState();
}

class _AvdNameSheetState extends State<_AvdNameSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);
  final TextEditingController _label = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _label.dispose();
    super.dispose();
  }

  String? _problem(String name) {
    if (name.isEmpty) return null;
    if (!isValidAvdName(name)) return widget.tr('Use letters, numbers, . _ -');
    if (widget.isTaken(name)) return widget.tr('Name already used');
    return null;
  }

  void _submit(String name) => Navigator.pop<AvdCreateResult>(
      context, (name: name, label: normalizeEmulatorLabel(_label.text)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tr = widget.tr;
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
                    labelText: tr('Name'),
                    errorText: problem,
                  ),
                  onSubmitted: (_) {
                    if (valid) _submit(name);
                  },
                ),
                if (widget.withLabel) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _label,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: tr('Label (optional)'),
                      helperText: tr('Shown on this phone only'),
                    ),
                    onSubmitted: (_) {
                      if (valid) _submit(name);
                    },
                  ),
                ],
                const SizedBox(height: 8),
                Text(widget.note, style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(tr('Cancel'))),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: valid ? () => _submit(name) : null,
                      child: Text(tr(widget.confirmLabel)),
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
