import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/emulator_model.dart';
import 'emulator_tile.dart';
import 'mirpg_remote_theme.dart';

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
    this.onReboot,
    this.windowVisible = false,
    this.onToggleWindow,
    required this.onLabel,
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

  /// Restarts Android inside the running emulator; the emulator stays on.
  final VoidCallback? onReboot;

  /// The emulator's window is shown on the PC.
  final bool windowVisible;

  /// Shows or hides the emulator's window on the PC; null when not offered.
  final VoidCallback? onToggleWindow;
  final VoidCallback onLabel;
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
    }) {
      final enabled = action != null;
      return ListTile(
        minTileHeight: 56,
        enabled: enabled,
        leading: Icon(icon),
        title: Text(label),
        subtitle: subtitle == null ? null : Text(subtitle),
        onTap: !enabled
            ? null
            : () {
                Navigator.of(rowContext).pop();
                action();
              },
      );
    }

    // While the emulator shuts down only the phone-side label stays editable.
    VoidCallback? unlessShuttingDown(VoidCallback? action) =>
        shuttingDown ? null : action;

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
                  action: unlessShuttingDown(onOpen),
                  subtitle: onOpen == null ? openBlocker : null),
              if (onLaunchGame != null)
                row(rowContext,
                    icon: Icons.sports_esports_outlined,
                    label: tr('Open and launch game'),
                    action: unlessShuttingDown(onLaunchGame)),
              if (!stopped && onToggleWindow != null)
                row(rowContext,
                    icon: windowVisible
                        ? Icons.desktop_access_disabled_outlined
                        : Icons.desktop_windows_outlined,
                    label: tr(windowVisible ? 'Hide on PC' : 'Show on PC'),
                    action: unlessShuttingDown(onToggleWindow)),
              if (!stopped && onStop != null)
                row(rowContext,
                    icon: Icons.stop_circle_outlined,
                    label: tr('Stop'),
                    action: unlessShuttingDown(onStop)),
              if (!stopped && onReboot != null)
                row(rowContext,
                    icon: Icons.restart_alt,
                    label: tr('Reboot'),
                    action: unlessShuttingDown(onReboot)),
              const Divider(height: 1),
              row(rowContext,
                  icon: Icons.label_outline, label: tr('Label'), action: onLabel),
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
