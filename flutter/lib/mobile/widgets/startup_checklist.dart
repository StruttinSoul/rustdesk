import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import 'mirpg_remote_theme.dart';

/// The four fixed startup steps, as translate keys.
const _startupSteps = [
  'Start requested',
  'Starting Android',
  'Starting the screen',
  'Live',
];

/// Maps the PC's start phase to a checklist step. An emulator that was
/// already running when it was opened skips straight to the screen.
int startupStepIndex(String phase, {required bool alreadyRunning}) =>
    switch (phase) {
      'starting_android' => 1,
      'waiting_screen' => 2,
      'stream_ready' => 3,
      _ => alreadyRunning ? 2 : 0,
    };

/// The startup screen's back button, as a translate key. On the dashboard it
/// returns to the emulator grid; on the fallback picker page (PCs without the
/// dashboard) it returns to the Windows desktop, like that page's app bar.
String startupBackLabel({required bool dashboardMode}) =>
    dashboardMode ? 'Back to emulators' : 'Return to Windows desktop';

/// `m:ss`, e.g. `0:41`, `1:05`, `12:00`.
String formatElapsed(Duration d) {
  final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// What a person sees while an emulator starts, and where a start or a live
/// screen failed: the four steps, how long it has taken, and the way back.
class StartupChecklist extends StatelessWidget {
  const StartupChecklist({
    super.key,
    required this.name,
    required this.providerLabel,
    required this.currentStep,
    this.failedStep,
    required this.elapsed,
    this.failureTitle = '',
    this.failureMessage = '',
    this.retryNote = '',
    required this.onBack,
    this.backLabel = 'Back to emulators',
    this.backIcon = Icons.grid_view_rounded,
    this.onTryAgain,
    this.onShowOnPc,
    this.tryAgainLabel = 'Try again',
    this.tr = translate,
  });

  final String name;
  final String providerLabel;
  final int currentStep;

  /// Set when the start or the live screen failed; the step marked failed.
  final int? failedStep;
  final Duration elapsed;

  /// Translate key, may carry one `{value}` placeholder (the name).
  final String failureTitle;

  /// The PC's own message; shown as is, never translated.
  final String failureMessage;

  /// Translate key, shown while the automatic retry is armed.
  final String retryNote;
  final VoidCallback onBack;

  /// Translate key for [onBack]'s button. The fallback picker page, where
  /// back returns to the Windows desktop, passes its own wording.
  final String backLabel;
  final IconData backIcon;

  /// Translate key for [onTryAgain]'s button after a failure.
  final String tryAgainLabel;
  final VoidCallback? onTryAgain;
  final VoidCallback? onShowOnPc;
  final String Function(String) tr;

  bool get _failed => failedStep != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MirpgStudioPalette.of(context);
    // At least one screen tall, so the actions sit at the bottom; scrolls
    // when the steps, the failure and the actions do not fit (landscape).
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(MirpgRemoteTheme.pageMargin),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  (constraints.maxHeight - 2 * MirpgRemoteTheme.pageMargin)
                      .clamp(0.0, double.infinity)
                      .toDouble(),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 4 * MirpgRemoteTheme.rhythm),
                    Text(
                      name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(color: palette.textPrimary),
                    ),
                    if (providerLabel.isNotEmpty) ...[
                      const SizedBox(height: MirpgRemoteTheme.rhythm / 2),
                      Text(
                        providerLabel,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: palette.textSecondary),
                      ),
                    ],
                    const SizedBox(height: 5 * MirpgRemoteTheme.rhythm),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < _startupSteps.length; i++)
                              _step(context, i),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 3 * MirpgRemoteTheme.rhythm),
                    if (_failed)
                      _failure(context)
                    else
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: formatElapsed(elapsed),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          TextSpan(
                              text:
                                  ' · ${tr(elapsed >= const Duration(seconds: 60) ? 'Taking longer than usual' : 'usually under a minute')}'),
                        ]),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: palette.textSecondary),
                      ),
                  ],
                ),
                Padding(
                  padding:
                      const EdgeInsets.only(top: 3 * MirpgRemoteTheme.rhythm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _actions(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _step(BuildContext context, int index) {
    final theme = Theme.of(context);
    final palette = MirpgStudioPalette.of(context);
    final failed = failedStep;
    final String kind;
    if (failed != null) {
      kind = index < failed
          ? 'done'
          : index == failed
              ? 'failed'
              : 'pending';
    } else {
      kind = index < currentStep
          ? 'done'
          : index == currentStep
              ? 'current'
              : 'pending';
    }
    const markerSize = 28.0;
    final Widget marker = switch (kind) {
      'done' => _filledMarker(palette.good, Icons.check_rounded),
      'failed' => _filledMarker(palette.error, Icons.close_rounded),
      'current' => SizedBox.square(
          dimension: markerSize,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: palette.warning,
              backgroundColor: palette.warning.withOpacity(0.2),
            ),
          ),
        ),
      _ => Container(
          width: markerSize,
          height: markerSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: palette.outline, width: 2),
          ),
        ),
    };
    final last = index == _startupSteps.length - 1;
    final textColor = switch (kind) {
      'failed' => palette.error,
      'pending' => palette.textSecondary,
      _ => palette.textPrimary,
    };
    final emphasised = kind == 'current' || kind == 'failed';
    return Row(
      key: ValueKey('step-$kind-$index'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(children: [
          marker,
          if (!last)
            Container(
              width: 2,
              height: 3 * MirpgRemoteTheme.rhythm,
              color: palette.outline,
            ),
        ]),
        const SizedBox(width: 2 * MirpgRemoteTheme.rhythm),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: markerSize),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr(_startupSteps[index]),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: textColor,
                  fontWeight: emphasised ? FontWeight.w600 : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static Widget _filledMarker(Color color, IconData icon) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withOpacity(0.15),
        ),
        child: Icon(icon, size: 18, color: color),
      );

  Widget _failure(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MirpgStudioPalette.of(context);
    return MirpgSurface(
      color: palette.error.withOpacity(0.08),
      borderColor: palette.error.withOpacity(0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (failureTitle.isNotEmpty)
            Text(
              tr(failureTitle),
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: palette.error, fontWeight: FontWeight.w600),
            ),
          if (failureMessage.isNotEmpty) ...[
            const SizedBox(height: MirpgRemoteTheme.rhythm / 2),
            Text(
              failureMessage,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: palette.textPrimary),
            ),
          ],
          if (retryNote.isNotEmpty) ...[
            const SizedBox(height: MirpgRemoteTheme.rhythm),
            Text(
              tr(retryNote),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: palette.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _actions() {
    final full = ButtonStyle(
      minimumSize: WidgetStateProperty.all(
          const Size.fromHeight(MirpgRemoteTheme.minTouchTarget)),
    );
    Widget label(IconData? icon, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: MirpgRemoteTheme.rhythm),
            ],
            Flexible(child: Text(tr(text), overflow: TextOverflow.ellipsis)),
          ],
        );
    final showOnPc = onShowOnPc == null
        ? null
        : TextButton(
            style: full,
            onPressed: onShowOnPc,
            child: label(Icons.desktop_windows_outlined, 'Show on PC'),
          );
    if (_failed) {
      return [
        FilledButton(
          style: full,
          onPressed: onTryAgain,
          child: label(Icons.refresh_rounded, tryAgainLabel),
        ),
        const SizedBox(height: MirpgRemoteTheme.rhythm),
        TextButton(
          style: full,
          onPressed: onBack,
          child: label(null, backLabel),
        ),
        if (showOnPc != null) showOnPc,
      ];
    }
    return [
      FilledButton(
        style: full,
        onPressed: onBack,
        child: label(backIcon, backLabel),
      ),
      if (showOnPc != null) ...[
        const SizedBox(height: MirpgRemoteTheme.rhythm),
        showOnPc,
      ],
    ];
  }
}

/// Shown while switching to an emulator that is already running: its last
/// preview frame, dimmed, with its name, until the live stream arrives.
class SwitchPlaceholder extends StatelessWidget {
  const SwitchPlaceholder({super.key, this.frame, required this.name});

  final ui.Image? frame;
  final String name;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .titleMedium
        ?.copyWith(color: MirpgStudioPalette.dark.textPrimary);
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (frame != null)
              Opacity(
                opacity: 0.4,
                child: RawImage(
                  image: frame,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.low,
                ),
              ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(MirpgRemoteTheme.pageMargin),
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          ],
        ),
      ),
    );
  }
}
