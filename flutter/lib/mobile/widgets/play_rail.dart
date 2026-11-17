import 'dart:async';

import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/emulator_model.dart';
import 'emulator_tile.dart' show emulatorStateTone;
import 'mirpg_remote_theme.dart';

/// Where the in-game play rail goes: docked in the letterbox under the game
/// (portrait games) or beside it (landscape games), or collapsed to the
/// round button when the game leaves no room.
enum PlayRailPlacement { bottom, side, collapsed }

const kPlayRailAccountsHeight = 40.0,
    kPlayRailKeysHeight = 48.0,
    kPlayRailBottomHeight = 88.0,
    kPlayRailSideWidth = 72.0,
    kPlayRailHysteresis = 16.0;

/// Docks the rail where the contained game leaves enough black space, so the
/// rail never covers or shrinks the game. The hysteresis is on the docking
/// side: a rail docks only when the spare space is [kPlayRailHysteresis]
/// more than it needs, stays docked while the space still holds it, and
/// collapses as soon as it would shrink the game. So system bars, insets and
/// other small viewport changes do not make the rail flicker.
PlayRailPlacement playRailPlacement({
  required Size viewport,
  required int guestWidth,
  required int guestHeight,
  PlayRailPlacement? previous,
}) {
  final frame = containedGuestFrame(
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
      guestWidth: guestWidth,
      guestHeight: guestHeight);
  if (frame == null) return PlayRailPlacement.collapsed;
  final spareH = viewport.height - frame.height,
      spareW = viewport.width - frame.width;
  double need(PlayRailPlacement p, double base) =>
      p == previous ? base : base + kPlayRailHysteresis;
  if (spareH >= need(PlayRailPlacement.bottom, kPlayRailBottomHeight)) {
    return PlayRailPlacement.bottom;
  }
  if (spareW >= need(PlayRailPlacement.side, kPlayRailSideWidth)) {
    return PlayRailPlacement.side;
  }
  return PlayRailPlacement.collapsed;
}

/// One emulator as a chip on the rail.
class PlayAccount {
  const PlayAccount(
      {required this.id, required this.label, required this.word});

  final String id;

  /// The phone-side label when set, otherwise the emulator name.
  final String label;
  final EmulatorUiWord word;
}

/// The rail's chips: every Live or Starting emulator, plus the one open
/// (whatever its state), in the order given (the grid order).
List<PlayAccount> playRailAccounts(Iterable<PlayAccount> all,
        {String? currentId}) =>
    [
      for (final account in all)
        if (account.word == EmulatorUiWord.live ||
            account.word == EmulatorUiWord.starting ||
            account.id == currentId)
          account,
    ];

/// Whether a chip tap may switch to [id]: never to the emulator already
/// open, and never while a switch is connecting or about to ([pending]).
bool playRailCanSwitch({
  required String id,
  required String? currentId,
  required bool connecting,
  required bool pending,
}) =>
    id.isNotEmpty && id != currentId && !connecting && !pending;

/// Account chips over the Android keys (mockups 1e, 1f′), or the same items
/// stacked in a 72 dp column beside a landscape game. Opaque, so a touch
/// anywhere on the rail never reaches the game under it.
class PlayRail extends StatelessWidget {
  const PlayRail({
    super.key,
    required this.accounts,
    required this.currentId,
    required this.axis,
    required this.onSelect,
    this.onShowAll,
    required this.onGrid,
    this.onGridLongPress,
    this.onType,
    this.onNavigate,
    this.switching = false,
    this.tr = translate,
  });

  final List<PlayAccount> accounts;
  final String currentId;
  final Axis axis;
  final ValueChanged<String> onSelect;
  final VoidCallback? onShowAll;
  final VoidCallback onGrid;
  final VoidCallback? onGridLongPress;
  final VoidCallback? onType;

  /// `'back' | 'home' | 'recents'`; null while the keys are unavailable.
  final ValueChanged<String>? onNavigate;

  /// A switch is connecting: every chip is disabled.
  final bool switching;
  final String Function(String) tr;

  static const _palette = MirpgStudioPalette.dark;

  bool get _horizontal => axis == Axis.horizontal;

  @override
  Widget build(BuildContext context) {
    final border = BorderSide(color: _palette.outline);
    // An opaque Material absorbs every touch on it, so gaps between chips
    // and keys are still rail, and it gives the ink splashes a surface.
    return Material(
      color: _palette.background,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: _horizontal ? Border(top: border) : Border(left: border),
        ),
        child: _horizontal ? _horizontalRail(context) : _verticalRail(context),
      ),
    );
  }

  Widget _horizontalRail(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: kPlayRailAccountsHeight,
            child: Row(children: [
              Flexible(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  children: [
                    for (final account in accounts)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _chip(context, account),
                      ),
                  ],
                ),
              ),
              _showAllKey(),
            ]),
          ),
          SizedBox(
            height: kPlayRailKeysHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                _gridKey(),
                _typeKey(),
                const Spacer(),
                ..._navigationKeys(),
              ]),
            ),
          ),
        ],
      );

  Widget _verticalRail(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final keys = [
            _gridKey(),
            _typeKey(),
            ..._navigationKeys(),
          ];
          final chips = [
            for (final account in accounts)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _chip(context, account),
              ),
            Center(child: _showAllKey()),
          ];
          const keysHeight = 5 * kPlayRailKeysHeight;
          // Chips scroll above fixed keys; on a very short viewport the
          // whole column scrolls instead of overflowing.
          if (constraints.maxHeight < keysHeight + kPlayRailAccountsHeight) {
            return SingleChildScrollView(
              child: Column(children: [...chips, ...keys]),
            );
          }
          return Column(children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: chips,
              ),
            ),
            ...keys,
          ]);
        },
      );

  Color _toneColor(EmulatorUiWord word) => switch (emulatorStateTone(word)) {
        MirpgStatusTone.good => _palette.good,
        MirpgStatusTone.warning => _palette.warning,
        MirpgStatusTone.error => _palette.error,
        MirpgStatusTone.neutral => _palette.textSecondary,
      };

  Widget _chip(BuildContext context, PlayAccount account) {
    final current = account.id == currentId;
    final enabled = !switching;
    final text = Theme.of(context).textTheme;
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _toneColor(account.word),
      ),
    );
    final decoration = BoxDecoration(
      color: current ? _palette.accent.withOpacity(0.24) : _palette.raised,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: current ? _palette.accent : _palette.outline),
    );
    // Beside a landscape game the chip is 64 dp wide: the dot sits over a
    // centred label of up to two lines, so names stay readable.
    final chip = _horizontal
        ? Container(
            height: 32,
            padding: const EdgeInsets.only(left: 10, right: 12),
            decoration: decoration,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              dot,
              const SizedBox(width: 6),
              Text(
                account.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: text.labelMedium?.copyWith(
                  color: _palette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ]),
          )
        : Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: decoration,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              dot,
              const SizedBox(height: 2),
              Text(
                account.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: text.labelSmall?.copyWith(
                  color: _palette.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ]),
          );
    return MergeSemantics(
      child: Semantics(
        selected: current,
        button: true,
        enabled: enabled,
        child: Opacity(
          opacity: enabled || current ? 1 : 0.5,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            // The current chip is the answer to "which account is this";
            // tapping it does nothing.
            onTap: enabled && !current ? () => onSelect(account.id) : null,
            child: _horizontal
                ? SizedBox(
                    height: kPlayRailAccountsHeight,
                    child: Center(child: chip),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: chip,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _iconKey({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) =>
      SizedBox.square(
        dimension: kPlayRailKeysHeight,
        child: IconButton(
          tooltip: tr(tooltip),
          color: color ?? _palette.textPrimary,
          disabledColor: _palette.textSecondary.withOpacity(0.38),
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      );

  Widget _showAllKey() => SizedBox.square(
        dimension: kPlayRailAccountsHeight,
        child: IconButton(
          tooltip: tr('Show all emulators'),
          padding: EdgeInsets.zero,
          color: _palette.accent,
          disabledColor: _palette.textSecondary.withOpacity(0.38),
          onPressed: onShowAll,
          icon: const Icon(Icons.add_rounded),
        ),
      );

  /// ▦ returns to the grid; a long press opens this emulator's actions. The
  /// tooltip only shows on hover so it does not compete with the long press.
  Widget _gridKey() => Tooltip(
        message: tr('Emulators'),
        triggerMode: TooltipTriggerMode.manual,
        child: Semantics(
          button: true,
          child: SizedBox.square(
            dimension: kPlayRailKeysHeight,
            child: InkResponse(
              radius: kPlayRailKeysHeight / 2,
              onTap: onGrid,
              onLongPress: onGridLongPress,
              child: Icon(Icons.grid_view_rounded, color: _palette.accent),
            ),
          ),
        ),
      );

  Widget _typeKey() => _iconKey(
        icon: Icons.keyboard_outlined,
        tooltip: 'Type text',
        onPressed: onType,
      );

  List<Widget> _navigationKeys() {
    final navigate = onNavigate;
    Widget key(IconData icon, String tooltip, String action) => _iconKey(
          icon: icon,
          tooltip: tooltip,
          onPressed: navigate == null ? null : () => navigate(action),
        );
    return [
      key(Icons.arrow_back, 'Back', 'back'),
      key(Icons.home_outlined, 'Home', 'home'),
      key(Icons.crop_square, 'Recents', 'recents'),
    ];
  }
}

/// "Alt-1 · Live" for two seconds after each open and switch.
class NameBannerController extends ChangeNotifier {
  NameBannerController({this.hold = const Duration(seconds: 2)});

  final Duration hold;
  String _text = '';
  bool _visible = false;
  Timer? _timer;

  String get text => _text;
  bool get visible => _visible;

  void show(String text) {
    _timer?.cancel();
    _text = text;
    _visible = true;
    notifyListeners();
    _timer = Timer(hold, () {
      _timer = null;
      _visible = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// The name banner at the top centre of the game; never takes a touch.
class GuestNameBanner extends StatelessWidget {
  const GuestNameBanner({super.key, required this.controller});

  final NameBannerController controller;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Align(
            alignment: Alignment.topCenter,
            child: AnimatedOpacity(
              opacity: controller.visible ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: controller.text.isEmpty
                  ? const SizedBox.shrink()
                  : MirpgStatusChip(
                      label: controller.text,
                      icon: Icons.circle,
                      tone: MirpgStatusTone.good,
                      onDarkSurface: true,
                    ),
            ),
          ),
        ),
      );
}
