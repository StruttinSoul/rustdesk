import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/emulator_model.dart';
import 'emulator_tile.dart';
import 'mirpg_remote_theme.dart';

const double _gridSpacing = 12;
const double _gridBottomPadding = 8;

/// Height of the "Emulators · n/4 running" header row; it holds the 48 dp
/// New button.
const double _headerExtent = kMinInteractiveDimension;

/// The smallest preview, as a share of the tile width (square). Below it the
/// grid scrolls rather than squash the previews further.
const double _minPreviewAspect = 1.0;

/// How long a phone-side start request keeps a stopped tile on "Starting"
/// (the same 120 s the startup screen waits before giving up).
const Duration kPlayStartRequestHold = Duration(seconds: 120);

/// Height of one Play grid tile for a [tileWidth]: a 3:4 preview plus the
/// name bar, which grows with the text scale.
double playTabTileExtent(double tileWidth, TextScaler textScaler) =>
    tileWidth * 4 / 3 + textScaler.scale(60);

/// Height of one tile so that [rows] rows plus the header fit in
/// [bodyHeight]: the natural 3:4 tile when it fits, else shorter down to a
/// square preview. Never taller than natural, so one or two emulators do not
/// stretch.
double playTabFittedTileExtent({
  required double bodyHeight,
  required double tileWidth,
  required TextScaler textScaler,
  int rows = 2,
}) {
  final natural = playTabTileExtent(tileWidth, textScaler);
  final minimum = tileWidth * _minPreviewAspect + textScaler.scale(60);
  final available = bodyHeight -
      _headerExtent -
      _gridBottomPadding -
      (rows - 1) * _gridSpacing;
  return (available / rows).clamp(minimum, natural).toDouble();
}

/// Distance between the tops of two grid rows for a Play tab [width].
double playTabRowExtent(double width, TextScaler textScaler) {
  final tileWidth = math.max(
      0.0, (width - 2 * MirpgRemoteTheme.pageMargin - _gridSpacing) / 2);
  return playTabTileExtent(tileWidth, textScaler) + _gridSpacing;
}

/// Index of the first tile in the row nearest the top of the viewport.
int playTabFirstVisibleIndex(double scrollOffset, double rowExtent) {
  if (rowExtent <= 0) return 0;
  return 2 * (math.max(0.0, scrollOffset - 32) / rowExtent).floor();
}

/// Which guests get one of the four preview streams on Play.
///
/// Stopped, stopping and shutting-down emulators never take a slot,
/// nor does the one already open. Tiles at or below [firstVisibleIndex] come
/// first, top down; then the ones above it, nearest first.
List<String> playTabPreviewIds(
  List<RemoteEmulator> guests, {
  required int firstVisibleIndex,
  bool Function(String id)? shuttingDown,
  String? activeId,
}) {
  bool candidate(RemoteEmulator guest) =>
      guest.state != 'stopped' &&
      guest.state != 'stopping' &&
      !(shuttingDown?.call(guest.id) ?? false) &&
      guest.id != activeId;
  final first = firstVisibleIndex.clamp(0, guests.length);
  return [
    for (var i = first; i < guests.length; i++)
      if (candidate(guests[i])) guests[i].id,
    for (var i = first - 1; i >= 0; i--)
      if (candidate(guests[i])) guests[i].id,
  ].take(4).toList(growable: false);
}

/// Records that the phone asked a stopped emulator to start.
void noteStartRequest(
    Map<String, DateTime> requests, RemoteEmulator instance, DateTime now) {
  if (instance.state == 'stopped') requests[instance.id] = now;
}

/// Whether [id] still reads "Starting" because of a phone-side request.
bool startRequestPending(
    Map<String, DateTime> requests, String id, DateTime now) {
  final at = requests[id];
  return at != null && now.difference(at) < kPlayStartRequestHold;
}

/// Drops requests the PC's list has caught up with (no longer stopped, or no
/// longer listed) and requests older than [kPlayStartRequestHold].
void pruneStartRequests(Map<String, DateTime> requests,
    Iterable<RemoteEmulator> instances, DateTime now) {
  requests.removeWhere((id, at) =>
      now.difference(at) >= kPlayStartRequestHold ||
      !instances.any((item) => item.id == id && item.state == 'stopped'));
}

/// Records that this phone saw [id] live at [now] (a fresh frame of it).
void noteSeenLive(Map<String, DateTime> seenLive, String id, DateTime now) =>
    seenLive[id] = now;

/// Whether the phone saw [id] live after the PC's cached list was asked for
/// ([listRequestedAt]), so a "stopped" in that list is out of date. A list
/// asked for after the sighting is newer and wins.
bool seenLiveSinceList(
    Map<String, DateTime> seenLive, String id, DateTime? listRequestedAt) {
  final at = seenLive[id];
  return at != null && (listRequestedAt == null || at.isAfter(listRequestedAt));
}

/// Whether [instance] is running as far as this phone knows. The PC's list
/// is not refreshed while a game streams, so a "stopped" in it may be stale:
/// a start request within [kPlayStartRequestHold] or a live sighting since
/// that list was asked for overrides it.
bool emulatorRunningAsKnown(
  RemoteEmulator instance, {
  required Map<String, DateTime> startRequests,
  required Map<String, DateTime> seenLive,
  required DateTime? listRequestedAt,
  required DateTime now,
}) {
  if (instance.state != 'stopped') return true;
  return startRequestPending(startRequests, instance.id, now) ||
      seenLiveSinceList(seenLive, instance.id, listRequestedAt);
}

/// The Play tab: every emulator as a tile in the PC's list order. The PC's
/// monitors live on the Screens tab.
class PlayTabBody extends StatelessWidget {
  const PlayTabBody({
    super.key,
    required this.tiles,
    required this.hostName,
    required this.firstLoad,
    required this.listError,
    required this.onRefresh,
    required this.onRetryList,
    required this.onOpen,
    required this.onMore,
    this.scrollController,
    this.tr = translate,
  });

  final List<EmulatorTileData> tiles;
  final String hostName;
  final bool firstLoad;
  final String listError;
  final Future<void> Function() onRefresh;
  final VoidCallback onRetryList;
  final void Function(String id) onOpen;
  final void Function(String id) onMore;
  final ScrollController? scrollController;
  final String Function(String) tr;

  static const _margin = MirpgRemoteTheme.pageMargin;

  Widget _grid(BuildContext context, int count, double bodyHeight,
      IndexedWidgetBuilder builder) {
    final textScaler = MediaQuery.textScalerOf(context);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: _margin),
      sliver: SliverLayoutBuilder(builder: (context, constraints) {
        final tileWidth =
            math.max(0.0, (constraints.crossAxisExtent - _gridSpacing) / 2);
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: _gridSpacing,
            crossAxisSpacing: _gridSpacing,
            // Up to four tiles (two rows) are sized to fit the screen; more
            // scroll at the natural size.
            mainAxisExtent: count <= 4
                ? playTabFittedTileExtent(
                    bodyHeight: bodyHeight,
                    tileWidth: tileWidth,
                    textScaler: textScaler)
                : playTabTileExtent(tileWidth, textScaler),
          ),
          delegate: SliverChildBuilderDelegate(builder, childCount: count),
        );
      }),
    );
  }

  Widget _skeleton(BuildContext context) {
    final palette = MirpgStudioPalette.of(context);
    return Column(
      key: const ValueKey('play-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.raised,
              borderRadius:
                  BorderRadius.circular(MirpgRemoteTheme.controlRadius),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 14, right: 48),
          child: Container(
            height: 16,
            decoration: BoxDecoration(
              color: palette.raised,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _errorCard(BuildContext context) {
    final palette = MirpgStudioPalette.of(context);
    final text = Theme.of(context).textTheme;
    return MirpgSurface(
      color: palette.error.withOpacity(0.08),
      borderColor: palette.error.withOpacity(0.45),
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: palette.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          tr("Couldn't get the emulator list from {$hostName}"),
                          style: text.titleSmall),
                      const SizedBox(height: 4),
                      Text(listError, style: text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: onRetryList,
              child: Text(tr('Try again')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = MirpgStudioPalette.of(context);
    return MirpgSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('No emulators on {$hostName} yet'), style: text.titleMedium),
          const SizedBox(height: 12),
          Text(
              tr('BlueStacks instances appear here when BlueStacks is installed.'),
              style: text.bodySmall?.copyWith(color: palette.textSecondary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final running = tiles
        .where((tile) =>
            tile.state.word == EmulatorUiWord.live ||
            tile.state.word == EmulatorUiWord.starting)
        .length;
    Widget box(Widget child, {EdgeInsets? padding}) => SliverToBoxAdapter(
          child: Padding(
            padding:
                padding ?? const EdgeInsets.fromLTRB(_margin, 8, _margin, 8),
            child: child,
          ),
        );
    final showCounts = !firstLoad && tiles.isNotEmpty;
    return LayoutBuilder(builder: (context, constraints) {
      final bodyHeight = constraints.maxHeight;
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (showCounts)
              box(
                SizedBox(
                  height: _headerExtent,
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '${tr('Emulators')} · ${tr('{$running/${tiles.length}} running')}',
                        style: text.titleSmall,
                      ),
                    ),
                  ]),
                ),
                padding: const EdgeInsets.symmetric(horizontal: _margin),
              ),
            if (listError.isNotEmpty) box(_errorCard(context)),
            if (firstLoad)
              _grid(context, 4, bodyHeight, (context, _) => _skeleton(context))
            else if (tiles.isEmpty && listError.isEmpty)
              box(_emptyCard(context))
            else
              _grid(context, tiles.length, bodyHeight, (context, index) {
                final data = tiles[index];
                return EmulatorTile(
                  key: ValueKey(data.id),
                  data: data,
                  tr: tr,
                  onOpen: data.state.canOpen ? () => onOpen(data.id) : null,
                  onMore: () => onMore(data.id),
                );
              }),
            const SliverToBoxAdapter(
                child: SizedBox(height: _gridBottomPadding)),
          ],
        ),
      );
    });
  }
}
