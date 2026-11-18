import 'dart:async';

import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/emulator_model.dart';
import 'mirpg_remote_theme.dart';

/// What the person saved: only the values they changed, and whether a
/// running emulator is to be restarted with them now.
typedef AvdSettingsChoice = ({AvdSettings change, bool restart});

/// Shows a spinner with [label] over the page until [work] completes.
Future<T> waitWithProgress<T>(
  BuildContext context,
  Future<T> work, {
  required String label,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var shown = true;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox.square(
              dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Flexible(child: Text(label)),
        ]),
      ),
    ),
  ).whenComplete(() => shown = false));
  try {
    return await work;
  } finally {
    if (shown && navigator.mounted) navigator.pop();
  }
}

/// Memory, CPU cores and screen of a managed emulator. Returns null when
/// dismissed.
Future<AvdSettingsChoice?> showAvdSettingsSheet(
  BuildContext context, {
  required String name,
  required AvdSettingsInfo info,
  String Function(String) tr = translate,
}) =>
    showModalBottomSheet<AvdSettingsChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => AvdSettingsSheet(name: name, info: info, tr: tr),
    );

class AvdSettingsSheet extends StatefulWidget {
  const AvdSettingsSheet(
      {super.key, required this.name, required this.info, this.tr = translate});

  final String name;
  final AvdSettingsInfo info;
  final String Function(String) tr;

  @override
  State<AvdSettingsSheet> createState() => _AvdSettingsSheetState();
}

class _AvdSettingsSheetState extends State<AvdSettingsSheet> {
  late AvdSettings _chosen = widget.info.next;

  AvdSettings get _change => _chosen.changedFrom(widget.info.next);

  /// Restarting with nothing new still applies what was saved before.
  void _save({required bool restart}) => Navigator.pop<AvdSettingsChoice>(
      context,
      (
        change: _change.isEmpty ? widget.info.pending : _change,
        restart: restart
      ));

  Widget _choices<T>(String label, List<T> values, T? selected,
      String Function(T) text, void Function(T) pick) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values)
                ChoiceChip(
                  label: Text(text(value)),
                  selected: value == selected,
                  onSelected: (_) => setState(() => pick(value)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MirpgStudioPalette.of(context);
    final tr = widget.tr;
    final info = widget.info;
    final changed = !_change.isEmpty;
    final note = !info.pending.isEmpty
        ? tr('Saved changes apply the next time it starts.')
        : info.running
            ? tr('Changes apply the next time it starts.')
            : null;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            MirpgRemoteTheme.pageMargin, 0, MirpgRemoteTheme.pageMargin, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('Settings'), style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(widget.name,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: palette.textSecondary)),
            _choices<int>(
                tr('Memory'),
                AvdSettings.ramChoicesMb,
                _chosen.ramMb,
                (mb) => tr('{${mb ~/ 1024}} GB'),
                (mb) => _chosen = _chosen.merged(AvdSettings(ramMb: mb))),
            _choices<int>(
                tr('CPU cores'),
                AvdSettings.coreChoices,
                _chosen.cores,
                (cores) => '$cores',
                (cores) => _chosen = _chosen.merged(AvdSettings(cores: cores))),
            _choices<(int, int)>(
                tr('Screen'),
                AvdSettings.screenChoices,
                _chosen.screen,
                (screen) => '${screen.$1} × ${screen.$2}',
                (screen) =>
                    _chosen = _chosen.merged(AvdSettings(screen: screen))),
            const SizedBox(height: 8),
            Text(tr('1080 × 2208 fits the phone without black bars.'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: palette.textSecondary)),
            if (note != null) ...[
              const SizedBox(height: 16),
              Text(note, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 16),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr('Cancel'))),
                if (info.running) ...[
                  TextButton(
                      onPressed: changed ? () => _save(restart: false) : null,
                      child: Text(tr('Save'))),
                  FilledButton(
                      onPressed: changed || !info.pending.isEmpty
                          ? () => _save(restart: true)
                          : null,
                      child: Text(tr('Save and restart'))),
                ] else
                  FilledButton(
                      onPressed: changed ? () => _save(restart: false) : null,
                      child: Text(tr('Save'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
