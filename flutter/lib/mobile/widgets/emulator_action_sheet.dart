import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/emulator_model.dart';
import 'emulator_tile.dart';
import 'mirpg_remote_theme.dart';

/// Managed Android emulator actions (clone, rename, delete, window, stop).
class AvdCardActions {
  const AvdCardActions({
    this.cloningLabel,
    this.running = false,
    this.windowVisible = false,
    this.blocker,
    this.onToggleWindow,
    this.onStop,
    this.onClone,
    this.onRename,
    this.onDelete,
  });

  /// Set while the emulator is being copied; the card then has no menu.
  final String? cloningLabel;
  final bool running;
  final bool windowVisible;

  /// Why clone, rename and delete are unavailable right now, if they are.
  final String? blocker;
  final VoidCallback? onToggleWindow;
  final VoidCallback? onStop;
  final VoidCallback? onClone;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  bool get hasMenu => cloningLabel == null;

  List<PopupMenuEntry<String>> menuEntries(BuildContext context, bool shuttingDown) {
    PopupMenuItem<String> item(String value, String label, VoidCallback? action,
            {String? subtitle}) =>
        PopupMenuItem<String>(
          value: value,
          enabled: !shuttingDown && action != null && subtitle == null,
          child: subtitle == null
              ? Text(label)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    Text(subtitle,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
        );
    return [
      if (running && onToggleWindow != null)
        item('avd_window', windowVisible ? 'Hide on PC' : 'Show on PC', onToggleWindow),
      if (running) item('avd_stop', 'Stop', onStop),
      item('avd_clone', 'Clone', onClone, subtitle: blocker),
      item('avd_rename', 'Rename', onRename, subtitle: blocker),
      item('avd_delete', 'Delete', onDelete, subtitle: blocker),
    ];
  }

  void select(String value) {
    switch (value) {
      case 'avd_window':
        onToggleWindow?.call();
      case 'avd_stop':
        onStop?.call();
      case 'avd_clone':
        onClone?.call();
      case 'avd_rename':
        onRename?.call();
      case 'avd_delete':
        onDelete?.call();
    }
  }
}

/// Bottom sheet listing everything that can be done with one emulator.
/// Each row closes the sheet first, then runs its action, so dialogs open
/// from the page rather than from the closing sheet.
class EmulatorActionSheet extends StatelessWidget {
  const EmulatorActionSheet({
    super.key,
    required this.title,
    required this.subtitle,
    required this.state,
    required this.stopped,
    this.onOpen,
    this.openBlocker,
    this.onLaunchGame,
    this.onStop,
    required this.onLabel,
    this.avd,
    this.shuttingDown = false,
    this.tr = translate,
  });

  final String title;
  final String subtitle;
  final EmulatorUiState state;
  final bool stopped;
  final VoidCallback? onOpen;
  final String? openBlocker;
  final VoidCallback? onLaunchGame;
  final VoidCallback? onStop;
  final VoidCallback onLabel;
  final AvdCardActions? avd;
  final bool shuttingDown;
  final EmulatorTr tr;

  @override
  Widget build(BuildContext context) {
    final palette = MirpgStudioPalette.of(context);
    final theme = Theme.of(context);

    Widget row(
      BuildContext rowContext, {
      required IconData icon,
      required String label,
      required VoidCallback? action,
      String? subtitle,
      Color? color,
    }) {
      final enabled = action != null;
      return ListTile(
        minTileHeight: 56,
        enabled: enabled,
        leading: Icon(icon, color: color),
        title: Text(label, style: color == null ? null : TextStyle(color: color)),
        subtitle: subtitle == null ? null : Text(subtitle),
        onTap: !enabled
            ? null
            : () {
                Navigator.of(rowContext).pop();
                action();
              },
      );
    }

    final stop = avd?.onStop ?? onStop;
    final managed = avd;
    final copying = managed?.cloningLabel != null;
    final manageBlocker = copying
        ? tr('Copy in progress')
        : (managed?.blocker == null ? null : tr(managed!.blocker!));

    return SafeArea(
      child: SingleChildScrollView(
        child: Builder(
          builder: (rowContext) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(subtitle,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: palette.textSecondary)),
                        EmulatorStateBadge(
                            state: state, onDarkSurface: false, tr: tr),
                      ],
                    ),
                  ],
                ),
              ),
              row(rowContext,
                  icon: stopped ? Icons.play_arrow : Icons.open_in_new,
                  label: tr(stopped ? 'Start' : 'Open'),
                  action: onOpen,
                  subtitle: onOpen == null ? openBlocker : null),
              if (onLaunchGame != null)
                row(rowContext,
                    icon: Icons.sports_esports_outlined,
                    label: tr('Open and launch game'),
                    action: onLaunchGame),
              if (managed != null &&
                  managed.running &&
                  managed.onToggleWindow != null)
                row(rowContext,
                    icon: managed.windowVisible
                        ? Icons.desktop_access_disabled_outlined
                        : Icons.desktop_windows_outlined,
                    label: tr(managed.windowVisible ? 'Hide on PC' : 'Show on PC'),
                    action: managed.onToggleWindow),
              if (!stopped && stop != null)
                row(rowContext,
                    icon: Icons.stop_circle_outlined,
                    label: tr('Stop'),
                    action: shuttingDown ? null : stop),
              const Divider(height: 1),
              row(rowContext,
                  icon: Icons.label_outline, label: tr('Label'), action: onLabel),
              if (managed != null) ...[
                row(rowContext,
                    icon: Icons.copy_outlined,
                    label: tr('Clone'),
                    action: manageBlocker != null ? null : managed.onClone,
                    subtitle: manageBlocker),
                row(rowContext,
                    icon: Icons.drive_file_rename_outline,
                    label: tr('Rename'),
                    action: manageBlocker != null ? null : managed.onRename,
                    subtitle: manageBlocker),
                row(rowContext,
                    icon: Icons.delete_outline,
                    label: tr('Delete'),
                    action: manageBlocker != null ? null : managed.onDelete,
                    subtitle: manageBlocker,
                    color: palette.error),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showEmulatorActionSheet(
        BuildContext context, EmulatorActionSheet sheet) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => sheet,
    );
