import 'package:flutter/material.dart';

import '../common.dart' show translate;
import '../mobile/widgets/mirpg_remote_theme.dart';

/// Longest label, in user-perceived characters.
const kEmulatorLabelMaxLength = 32;

final RegExp _whitespaceRun = RegExp(r'\s+');
final RegExp _forbidden = RegExp(r'[{}\u0000-\u001F\u007F-\u009F]');

/// Trims, collapses whitespace, drops `{`/`}` (translate placeholders) and
/// control characters, and cuts to [kEmulatorLabelMaxLength] grapheme clusters
/// so an emoji is never split. Whitespace-only input becomes `''`.
String normalizeEmulatorLabel(String raw) {
  final cleaned = raw
      .replaceAll(_whitespaceRun, ' ')
      .replaceAll(_forbidden, '')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  return cleaned.characters.take(kEmulatorLabelMaxLength).toString().trim();
}

/// Phone-side emulator labels, kept per PC and emulator id. The label is a
/// nickname shown instead of the emulator name; it never goes to the PC.
class EmulatorLabelStore extends ChangeNotifier {
  EmulatorLabelStore({
    required this.peerId,
    required String Function(String key) read,
    required Future<void> Function(String key, String value) write,
  })  : _read = read,
        _write = write;

  final String peerId;
  final String Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Map<String, String> _cache = {};
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // A write can finish after the page that owns the store is gone.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  static String storageKey(String peerId, String emulatorId) =>
      'aperture-emulator-label:$peerId:$emulatorId';

  String labelFor(String emulatorId) => _cache.putIfAbsent(
      emulatorId, () => normalizeEmulatorLabel(_read(storageKey(peerId, emulatorId))));

  /// The label when one is set, otherwise the emulator's own name.
  String displayName(String emulatorId, String emulatorName) {
    final label = labelFor(emulatorId);
    return label.isEmpty ? emulatorName : label;
  }

  Future<void> setLabel(String emulatorId, String label) async {
    if (await _store(emulatorId, normalizeEmulatorLabel(label))) {
      notifyListeners();
    }
  }

  Future<void> clearLabel(String emulatorId) => setLabel(emulatorId, '');

  /// Rename: the label follows the emulator. Any label already on [toId] is
  /// replaced, so a re-used name never inherits an old one.
  Future<void> moveLabel(String fromId, String toId) async {
    if (fromId == toId) return;
    final label = labelFor(fromId);
    final movedTo = await _store(toId, label);
    final clearedFrom = await _store(fromId, '');
    if (movedTo || clearedFrom) notifyListeners();
  }

  /// Returns whether the stored value changed.
  Future<bool> _store(String emulatorId, String label) async {
    if (labelFor(emulatorId) == label) return false;
    _cache[emulatorId] = label;
    await _write(storageKey(peerId, emulatorId), label);
    return true;
  }
}

/// Edits the phone-side label. Returns the normalized label (`''` = cleared),
/// or null if dismissed.
Future<String?> showEmulatorLabelSheet(
  BuildContext context, {
  required String emulatorName,
  required String currentLabel,
  String Function(String) tr = translate,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EmulatorLabelSheet(
          emulatorName: emulatorName, currentLabel: currentLabel, tr: tr),
    );

class _EmulatorLabelSheet extends StatefulWidget {
  const _EmulatorLabelSheet(
      {required this.emulatorName, required this.currentLabel, required this.tr});

  final String emulatorName;
  final String currentLabel;
  final String Function(String) tr;

  @override
  State<_EmulatorLabelSheet> createState() => _EmulatorLabelSheetState();
}

class _EmulatorLabelSheetState extends State<_EmulatorLabelSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentLabel);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, normalizeEmulatorLabel(_controller.text));

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
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
            Text(tr('Label for {${widget.emulatorName}}'),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr('Label')),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.currentLabel.isNotEmpty)
                  TextButton(
                      onPressed: () => Navigator.pop(context, ''),
                      child: Text(tr('Clear label'))),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr('Cancel'))),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: Text(tr('Save'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
