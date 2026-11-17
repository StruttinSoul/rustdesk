import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/emulator_model.dart';
import 'mirpg_remote_theme.dart';

typedef EmulatorTr = String Function(String key);

/// One fixed tone per state word, so the same state never changes colour
/// between the grid, the list and the dashboard.
MirpgStatusTone emulatorStateTone(EmulatorUiWord word) => switch (word) {
      EmulatorUiWord.live => MirpgStatusTone.good,
      EmulatorUiWord.starting => MirpgStatusTone.warning,
      EmulatorUiWord.problem => MirpgStatusTone.error,
      EmulatorUiWord.stopped ||
      EmulatorUiWord.stopping ||
      EmulatorUiWord.copying =>
        MirpgStatusTone.neutral,
    };

class EmulatorStateBadge extends StatelessWidget {
  const EmulatorStateBadge({
    super.key,
    required this.state,
    this.onDarkSurface = true,
    this.tr = translate,
  });

  final EmulatorUiState state;
  final bool onDarkSurface;
  final EmulatorTr tr;

  @override
  Widget build(BuildContext context) => MirpgStatusChip(
        label: tr(state.label),
        tone: emulatorStateTone(state.word),
        icon: state.word == EmulatorUiWord.live ? Icons.circle : null,
        onDarkSurface: onDarkSurface,
      );
}

class EmulatorTileData {
  const EmulatorTileData({
    required this.id,
    required this.title,
    this.secondary = '',
    required this.state,
    this.image,
    this.windowVisible = false,
    this.placeholder = false,
  });

  final String id;

  /// The label when one is set, otherwise the emulator name.
  final String title;

  /// The emulator name when a label is set, otherwise empty.
  final String secondary;
  final EmulatorUiState state;
  final ui.Image? image;
  final bool windowVisible;
  final bool placeholder;
}

String _causeText(EmulatorUiState state, EmulatorTr tr) {
  if (state.pcMessage.isNotEmpty) return state.pcMessage;
  if (state.causeKey.isNotEmpty) return tr(state.causeKey);
  return '';
}

Color _toneColor(BuildContext context, MirpgStatusTone tone) {
  final p = MirpgStudioPalette.of(context);
  return switch (tone) {
    MirpgStatusTone.good => p.good,
    MirpgStatusTone.warning => p.warning,
    MirpgStatusTone.error => p.error,
    MirpgStatusTone.neutral => p.textSecondary,
  };
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(12)));
    for (final metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

class _PcFlag extends StatelessWidget {
  const _PcFlag({required this.tr});
  final EmulatorTr tr;

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFB8C4D0);
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xE6101923),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withOpacity(0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.desktop_windows_outlined, size: 16, color: fg),
        const SizedBox(width: 4),
        Text(tr('PC'),
            maxLines: 1,
            softWrap: false,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: fg, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// The ⋮ button, or the same 48 dp of empty space where a surface offers no
/// actions (the rail's "+" sheet), so names wrap the same either way.
class _MoreButton extends StatelessWidget {
  const _MoreButton(
      {required this.title, required this.onMore, required this.tr});
  final String title;
  final VoidCallback? onMore;
  final EmulatorTr tr;

  @override
  Widget build(BuildContext context) => onMore == null
      ? const SizedBox.square(dimension: kMinInteractiveDimension)
      : IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: tr('More {$title} actions'),
          onPressed: onMore,
        );
}

/// Below this preview height the state badge would sit on top of the action
/// in the middle of the preview, so the action wins.
const double _kTightPreview = 120;

/// Centred content of a tile's preview. It keeps its natural size and only
/// shrinks, never overflows, when the preview is squeezed (large text, short
/// cells); the bottom gap that clears the state badge goes first.
class _PreviewContent extends StatelessWidget {
  const _PreviewContent({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: LayoutBuilder(builder: (context, constraints) {
          final bottom = constraints.maxHeight >= _kTightPreview ? 40.0 : 8.0;
          return Padding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, bottom),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: (constraints.maxWidth - 16)
                        .clamp(0.0, double.infinity)
                        .toDouble()),
                child: child,
              ),
            ),
          );
        }),
      );
}

class EmulatorTile extends StatelessWidget {
  const EmulatorTile({
    super.key,
    required this.data,
    this.onOpen,
    this.onMore,
    this.tr = translate,
  });

  final EmulatorTileData data;
  final VoidCallback? onOpen;
  final VoidCallback? onMore;
  final EmulatorTr tr;

  Widget _centre(BuildContext context) {
    final state = data.state;
    final text = Theme.of(context).textTheme;
    final palette = MirpgStudioPalette.of(context);
    const onVideo = Color(0xFFE6EDF3);
    if (data.placeholder) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(tr('Setting up…'),
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: onVideo)),
        ),
      );
    }
    final cause = _causeText(state, tr);
    switch (state.word) {
      case EmulatorUiWord.stopped:
        return _PreviewContent(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.play_arrow),
                label: Text(tr('Start')),
              ),
              if (state.pcMessage.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(state.pcMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(color: onVideo)),
              ],
            ]));
      case EmulatorUiWord.problem:
        return _PreviewContent(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (cause.isNotEmpty) ...[
                Text(cause,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(color: onVideo)),
                const SizedBox(height: 6),
              ],
              FilledButton(
                  onPressed: onOpen, child: Text(tr('Reconnect'))),
            ]));
      case EmulatorUiWord.copying:
        final match = RegExp(r'\{(\d+)\}').firstMatch(state.label);
        final percent = int.tryParse(match?.group(1) ?? '');
        return Center(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            child: LinearProgressIndicator(
              value: percent == null ? null : percent.clamp(0, 100) / 100,
              color: palette.accent,
            ),
          ),
        );
      case EmulatorUiWord.starting:
        return const Center(
          child: Padding(
            padding: EdgeInsets.only(bottom: 32),
            child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
        );
      case EmulatorUiWord.live:
      case EmulatorUiWord.stopping:
        return const SizedBox.shrink();
    }
  }

  Widget _preview(BuildContext context) {
    final palette = MirpgStudioPalette.of(context);
    final image = data.image;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: LayoutBuilder(builder: (context, constraints) {
        // A stopped or failed tile's action is also its status, so it keeps
        // the room when the preview is squeezed.
        final overlays = !data.placeholder &&
            !(constraints.maxHeight < _kTightPreview &&
                (data.state.word == EmulatorUiWord.stopped ||
                    data.state.word == EmulatorUiWord.problem));
        return Stack(fit: StackFit.expand, children: [
          const ColoredBox(color: Colors.black),
          if (image != null && !data.placeholder)
            RawImage(image: image, fit: BoxFit.contain),
          if (data.placeholder)
            Positioned.fill(
                child: CustomPaint(
                    painter: _DashedBorderPainter(palette.outline))),
          _centre(context),
          if (overlays)
            Positioned(
              left: 8,
              bottom: 8,
              child: EmulatorStateBadge(state: data.state, tr: tr),
            ),
          if (overlays && data.windowVisible)
            Positioned(right: 8, bottom: 8, child: _PcFlag(tr: tr)),
        ]);
      }),
    );
  }

  Widget _nameBar(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = MirpgStudioPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(data.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium),
                if (data.secondary.isNotEmpty)
                  Text(data.secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall
                          ?.copyWith(color: palette.textSecondary)),
              ],
            ),
          ),
        ),
        if (!data.placeholder)
          _MoreButton(title: data.title, onMore: onMore, tr: tr),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: data.placeholder ? null : onOpen,
      onLongPress: data.placeholder ? null : onMore,
      child: LayoutBuilder(builder: (context, constraints) {
        final preview = _preview(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (constraints.hasBoundedHeight)
              Expanded(child: preview)
            else
              AspectRatio(aspectRatio: 3 / 4, child: preview),
            _nameBar(context),
          ],
        );
      }),
    );
  }
}

class EmulatorRow extends StatelessWidget {
  const EmulatorRow({
    super.key,
    required this.data,
    this.onOpen,
    this.onMore,
    this.tr = translate,
  });

  final EmulatorTileData data;
  final VoidCallback? onOpen;
  final VoidCallback? onMore;
  final EmulatorTr tr;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = MirpgStudioPalette.of(context);
    final state = data.state;
    final cause = _causeText(state, tr);
    final statusLine = state.word == EmulatorUiWord.problem && cause.isNotEmpty
        ? '${tr(state.label)} · $cause'
        : tr(state.label);
    final (IconData, String)? action = data.placeholder
        ? null
        : switch (state.word) {
            EmulatorUiWord.stopped => (Icons.play_arrow, 'Start'),
            EmulatorUiWord.problem => (Icons.refresh, 'Reconnect'),
            EmulatorUiWord.live ||
            EmulatorUiWord.starting =>
              (Icons.open_in_new, 'Open'),
            _ => null,
          };
    final image = data.image;
    return InkWell(
      onTap: data.placeholder ? null : onOpen,
      onLongPress: data.placeholder ? null : onMore,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 76,
              height: 62,
              child: Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Colors.black),
                if (image != null && !data.placeholder)
                  RawImage(image: image, fit: BoxFit.contain),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(data.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium),
                if (data.secondary.isNotEmpty)
                  Text(data.secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall
                          ?.copyWith(color: palette.textSecondary)),
                Text(data.placeholder ? tr('Setting up…') : statusLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                        color: _toneColor(
                            context, emulatorStateTone(state.word)))),
              ],
            ),
          ),
          if (!data.placeholder)
            _MoreButton(title: data.title, onMore: onMore, tr: tr),
          if (action != null)
            IconButton(
              icon: Icon(action.$1),
              tooltip: tr(action.$2),
              onPressed: onOpen,
            ),
        ]),
      ),
    );
  }
}
