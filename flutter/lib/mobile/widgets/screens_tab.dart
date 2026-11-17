import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import 'mirpg_remote_theme.dart';

const double _margin = MirpgRemoteTheme.pageMargin;
const double _spacing = 12;

/// Height of a Screens card below its preview: the name, the size and the
/// 48 dp actions. It grows with the text scale.
double _footerExtent(TextScaler textScaler) =>
    math.max(64.0, textScaler.scale(64));

/// Which PC monitors get a preview stream on Screens: the one nearest the top
/// of the viewport and those below it first, then the ones above it, nearest
/// first. At most four (the PC's preview limit).
List<int> screensPreviewDisplays({
  required int monitorCount,
  required int firstVisibleIndex,
}) {
  if (monitorCount <= 0) return const [];
  final first = firstVisibleIndex.clamp(0, monitorCount);
  return [
    for (var i = first; i < monitorCount; i++) i,
    for (var i = first - 1; i >= 0; i--) i,
  ].take(4).toList(growable: false);
}

/// Distance between the tops of two Screens cards for a card [width].
double screensTabCardExtent(
        double width, double aspectRatio, TextScaler textScaler) =>
    width / aspectRatio + _footerExtent(textScaler) + _spacing;

/// Index of the card nearest the top of the viewport, given each card's
/// [extents] (card plus spacing, from [screensTabCardExtent]).
int screensTabFirstVisibleIndex(List<double> extents, double scrollOffset) {
  // The "PC screens" header sits above the first card.
  var remaining = math.max(0.0, scrollOffset - 36);
  for (var i = 0; i < extents.length; i++) {
    remaining -= extents[i];
    if (remaining < 0) return i;
  }
  return math.max(0, extents.length - 1);
}

/// One monitor on the Screens tab. [aspectRatio] is the display's width over
/// its height, clamped so a very wide or tall display still fits a card.
class ScreensTabCard {
  const ScreensTabCard({required double aspectRatio, required this.child})
      : aspectRatio = aspectRatio < 1.0
            ? 1.0
            : (aspectRatio > 2.4 ? 2.4 : aspectRatio);

  final double aspectRatio;
  final Widget child;
}

/// The Screens tab: the PC's monitors only, one full-width card per row.
class ScreensTabBody extends StatelessWidget {
  const ScreensTabBody({
    super.key,
    required this.cards,
    required this.hostName,
    this.scrollController,
    this.tr = translate,
  });

  final List<ScreensTabCard> cards;
  final String hostName;
  final ScrollController? scrollController;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final textScaler = MediaQuery.textScalerOf(context);
    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_margin, 8, _margin, 8),
            child: Text(tr('PC screens'), style: text.titleSmall),
          ),
        ),
        if (cards.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _margin),
              child: MirpgSurface(
                child: Text(tr('No screens from {$hostName} yet'),
                    style: text.titleMedium),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_margin, 0, _margin, _margin),
            sliver: SliverLayoutBuilder(builder: (context, constraints) {
              final width = constraints.crossAxisExtent;
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final card = cards[index];
                    return Padding(
                      padding: EdgeInsets.only(
                          bottom: index == cards.length - 1 ? 0 : _spacing),
                      child: SizedBox(
                        height: screensTabCardExtent(
                                width, card.aspectRatio, textScaler) -
                            _spacing,
                        child: card.child,
                      ),
                    );
                  },
                  childCount: cards.length,
                ),
              );
            }),
          ),
      ],
    );
  }
}

/// Columns of the view switcher: two in portrait, four in landscape.
int switcherGridColumns(Size size) => size.width > size.height ? 4 : 2;

/// Distance between the tops of two switcher rows in a grid of [size].
double switcherGridRowExtent(Size size) {
  final columns = switcherGridColumns(size);
  final cellWidth = math.max(
      0.0, (size.width - 2 * _margin - _spacing * (columns - 1)) / columns);
  return cellWidth / TargetSwitcherGrid.cellAspectRatio + _spacing;
}

/// Index of the first card in the row nearest the top of a switcher grid of
/// [size] scrolled by [scrollOffset].
int switcherGridFirstVisibleIndex(Size size, double scrollOffset) {
  final rowExtent = switcherGridRowExtent(size);
  if (rowExtent <= 0) return 0;
  return switcherGridColumns(size) *
      (math.max(0.0, scrollOffset - _spacing) / rowExtent).floor();
}

/// The view switcher: monitors and emulators as a grid of cards.
class TargetSwitcherGrid extends StatelessWidget {
  const TargetSwitcherGrid({super.key, required this.cards, this.controller});

  static const double cellAspectRatio = 0.75;

  final List<Widget> cards;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => GridView.count(
          controller: controller,
          crossAxisCount: switcherGridColumns(constraints.biggest),
          mainAxisSpacing: _spacing,
          crossAxisSpacing: _spacing,
          childAspectRatio: cellAspectRatio,
          padding:
              const EdgeInsets.fromLTRB(_margin, _spacing, _margin, _margin),
          children: cards,
        ),
      );
}

/// Below this preview height the state badge would sit on top of the Reconnect
/// action, so the action wins.
const double _kTightPreview = 120;

/// A PC monitor as a preview card: on the Screens tab and in the view
/// switcher. Emulators use `EmulatorTile` instead.
class TargetPreviewCard extends StatelessWidget {
  const TargetPreviewCard({
    super.key,
    required this.name,
    this.detail = '',
    required this.live,
    this.image,
    this.error = '',
    this.onOpen,
    this.onRetry,
    this.onWindows,
    this.tr = translate,
  });

  final String name;

  /// The display size, such as `2560 × 1440`.
  final String detail;
  final bool live;
  final ui.Image? image;
  final String error;
  final VoidCallback? onOpen;

  /// Offered as Reconnect while the preview is not live.
  final VoidCallback? onRetry;
  final VoidCallback? onWindows;
  final String Function(String) tr;

  bool get _failed => !live && error.isNotEmpty;

  Widget _badge() => MirpgStatusChip(
        label: tr(live
            ? 'Live'
            : _failed
                ? 'Problem'
                : 'Waiting for preview'),
        tone: live
            ? MirpgStatusTone.good
            : _failed
                ? MirpgStatusTone.error
                : MirpgStatusTone.warning,
        icon: live ? Icons.circle : null,
        onDarkSurface: true,
      );

  Widget _centre(BuildContext context, double height) {
    final onVideo = MirpgStudioPalette.dark.textPrimary;
    final text = Theme.of(context).textTheme;
    final tight = height < _kTightPreview;
    final children = <Widget>[
      if (_failed) ...[
        Text(error,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: onVideo)),
        const SizedBox(height: 6),
      ],
      if (onRetry != null)
        FilledButton(onPressed: onRetry, child: Text(tr('Reconnect'))),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    // Keeps its natural size and only shrinks, never overflows, when the
    // preview is squeezed (large text, short cells).
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) => Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, tight ? 8 : 40),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: math.max(0.0, constraints.maxWidth - 16)),
              child: Column(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(MirpgRemoteTheme.controlRadius),
        child: LayoutBuilder(builder: (context, constraints) {
          final tight = constraints.maxHeight < _kTightPreview;
          final overlays = live || !tight;
          return Stack(fit: StackFit.expand, children: [
            const ColoredBox(color: Colors.black),
            if (image != null)
              RawImage(
                  image: image,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.low)
            else if (!live)
              Center(
                child: Icon(Icons.desktop_windows_outlined,
                    size: 38, color: MirpgStudioPalette.dark.textSecondary),
              ),
            if (!live && image != null)
              ColoredBox(color: Colors.black.withOpacity(0.5)),
            if (!live) _centre(context, constraints.maxHeight),
            if (overlays) Positioned(left: 8, bottom: 8, child: _badge()),
          ]);
        }),
      );

  Widget _footer(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = MirpgStudioPalette.of(context);
    final titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium),
        if (detail.isNotEmpty)
          Text(detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: palette.textSecondary)),
      ],
    );
    final open =
        FilledButton(onPressed: onOpen, child: Text(tr('Open')));
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8),
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 200) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              titles,
              const SizedBox(height: 8),
              Row(children: [
                if (onWindows != null)
                  IconButton(
                    tooltip: tr('Windows'),
                    onPressed: onWindows,
                    icon: const Icon(Icons.web_asset_outlined),
                  ),
                Expanded(child: open),
              ]),
            ],
          );
        }
        return Row(children: [
          Expanded(child: titles),
          if (onWindows != null) ...[
            OutlinedButton.icon(
              onPressed: onWindows,
              icon: const Icon(Icons.web_asset_outlined),
              label: Text(tr('Windows')),
            ),
            const SizedBox(width: 8),
          ],
          open,
        ]);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(MirpgRemoteTheme.controlRadius),
        onTap: onOpen,
        child: LayoutBuilder(builder: (context, constraints) {
          final preview = _preview(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (constraints.hasBoundedHeight)
                Expanded(child: preview)
              else
                AspectRatio(aspectRatio: 16 / 9, child: preview),
              _footer(context),
            ],
          );
        }),
      );
}
