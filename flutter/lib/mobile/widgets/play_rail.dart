import 'dart:async';

import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/emulator_model.dart';
import 'emulator_tile.dart' show emulatorStateTone;
import 'mirpg_remote_theme.dart';

/// Thickness of the in-game navigation bar: 48 dp tall at the bottom of a
/// portrait game, 48 dp wide on the right edge of a landscape game.
const double kPlayNavBarThickness = 48.0;

/// One emulator as a chip in the menu.
class PlayAccount {
  const PlayAccount(
      {required this.id, required this.label, required this.word});

  final String id;

  /// The phone-side label when set, otherwise the emulator name.
  final String label;
  final EmulatorUiWord word;
}

/// The menu's chips: every Live or Starting emulator, plus the one open
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

/// The in-game controls: a slim bar styled like Android's 3-button
/// navigation bar. Back, Home and Recents are the guest's Android keys (the
/// same actions as before); the fourth icon opens the menu with everything
/// else. Opaque, so a touch anywhere on the bar never reaches the game.
///
/// [axis] horizontal is the bottom bar of a portrait game; vertical is the
/// strip on the right edge of a landscape game, where Android stacks the keys
/// Recents, Home, Back from the top.
class PlayNavBar extends StatelessWidget {
  const PlayNavBar({
    super.key,
    required this.axis,
    required this.onNavigate,
    required this.onMenu,
    this.tr = translate,
  });

  final Axis axis;

  /// `'back' | 'home' | 'recents'`; null while the keys are unavailable.
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onMenu;
  final String Function(String) tr;

  static const _palette = MirpgStudioPalette.dark;

  /// Near black like the system bar the game sits above.
  static const background = Color(0xFF000000);

  @override
  Widget build(BuildContext context) {
    final navigate = onNavigate;
    Widget key(_NavGlyphShape shape, String tooltip, String action) => _NavKey(
          shape: shape,
          tooltip: tr(tooltip),
          onPressed: navigate == null ? null : () => navigate(action),
        );
    final back = key(_NavGlyphShape.back, 'Back', 'back');
    final home = key(_NavGlyphShape.home, 'Home', 'home');
    final recents = key(_NavGlyphShape.recents, 'Recents', 'recents');
    final menu = SizedBox.square(
      dimension: kPlayNavBarThickness,
      child: IconButton(
        style: _fixedKey,
        tooltip: tr('More'),
        color: _palette.textPrimary,
        disabledColor: _palette.textSecondary.withOpacity(0.38),
        onPressed: onMenu,
        icon: const Icon(Icons.more_vert),
      ),
    );
    final horizontal = axis == Axis.horizontal;
    final keys = horizontal ? [back, home, recents] : [recents, home, back];
    return Material(
      color: background,
      child: SizedBox(
        width: horizontal ? null : kPlayNavBarThickness,
        height: horizontal ? kPlayNavBarThickness : null,
        child: Flex(
          direction: axis,
          children: [
            // The keys share the space the menu icon leaves.
            if (!horizontal) menu,
            Expanded(
              child: Flex(
                direction: axis,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: keys,
              ),
            ),
            if (horizontal) menu,
          ],
        ),
      ),
    );
  }
}

/// Exactly 48 dp square, so the visible button is the whole touch target.
final ButtonStyle _fixedKey = IconButton.styleFrom(
  fixedSize: const Size.square(kPlayNavBarThickness),
  padding: EdgeInsets.zero,
);

enum _NavGlyphShape { back, home, recents }

class _NavKey extends StatelessWidget {
  const _NavKey(
      {required this.shape, required this.tooltip, required this.onPressed});

  final _NavGlyphShape shape;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null
        ? PlayNavBar._palette.textSecondary.withOpacity(0.38)
        : PlayNavBar._palette.textPrimary;
    return SizedBox.square(
      dimension: kPlayNavBarThickness,
      child: IconButton(
        style: _fixedKey,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: CustomPaint(
          size: const Size.square(20),
          painter: _NavGlyphPainter(shape, color),
        ),
      ),
    );
  }
}

/// Back, Home and Recents drawn as outlines (triangle, circle, rounded
/// square), the way the system navigation bar shows them.
class _NavGlyphPainter extends CustomPainter {
  const _NavGlyphPainter(this.shape, this.color);

  final _NavGlyphShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final inner = (Offset.zero & size).deflate(1.5);
    switch (shape) {
      case _NavGlyphShape.back:
        canvas.drawPath(
            Path()
              ..moveTo(inner.right, inner.top)
              ..lineTo(inner.left, inner.center.dy)
              ..lineTo(inner.right, inner.bottom)
              ..close(),
            paint);
      case _NavGlyphShape.home:
        canvas.drawCircle(inner.center, inner.width / 2, paint);
      case _NavGlyphShape.recents:
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                inner.deflate(1.5), const Radius.circular(3)),
            paint);
    }
  }

  @override
  bool shouldRepaint(_NavGlyphPainter old) =>
      old.shape != shape || old.color != color;
}

/// The bar's menu: the emulator switcher, the keyboard, the grid and this
/// emulator's actions. Each action closes the sheet and then runs, so the
/// game is never left under a sheet that has done its job.
Future<void> showPlayMenu(
  BuildContext context, {
  required List<PlayAccount> accounts,
  required String currentId,
  required ValueChanged<String> onSelect,
  required VoidCallback onGrid,
  VoidCallback? onShowAll,
  VoidCallback? onCurrentActions,
  VoidCallback? onType,
  bool switching = false,
  String Function(String) tr = translate,
}) {
  const palette = MirpgStudioPalette.dark;
  final current = accounts.where((account) => account.id == currentId);
  final currentLabel = current.isEmpty ? '' : current.first.label;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: palette.background,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      void run(VoidCallback? action) {
        Navigator.of(sheetContext).pop();
        action?.call();
      }

      Widget row(IconData icon, String label, VoidCallback? action) => ListTile(
            leading: Icon(icon),
            title: Text(label),
            enabled: action != null,
            iconColor: palette.accent,
            textColor: palette.textPrimary,
            onTap: action == null ? null : () => run(action),
          );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final account in accounts)
                      _PlayChip(
                        account: account,
                        current: account.id == currentId,
                        enabled: !switching,
                        onTap: () => run(() => onSelect(account.id)),
                      ),
                    SizedBox.square(
                      dimension: 48,
                      child: IconButton(
                        tooltip: tr('Show all emulators'),
                        color: palette.accent,
                        disabledColor: palette.textSecondary.withOpacity(0.38),
                        onPressed:
                            onShowAll == null ? null : () => run(onShowAll),
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ),
                  ],
                ),
              ),
              row(Icons.keyboard_outlined, tr('Type text'), onType),
              row(Icons.grid_view_rounded, tr('Emulators'), onGrid),
              if (onCurrentActions != null)
                row(
                  Icons.tune_rounded,
                  tr('More {$currentLabel} actions'),
                  onCurrentActions,
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// One emulator as a chip in the menu; 48 dp tall to touch.
class _PlayChip extends StatelessWidget {
  const _PlayChip({
    required this.account,
    required this.current,
    required this.enabled,
    required this.onTap,
  });

  final PlayAccount account;
  final bool current;
  final bool enabled;
  final VoidCallback onTap;

  static const _palette = MirpgStudioPalette.dark;

  Color get _dot => switch (emulatorStateTone(account.word)) {
        MirpgStatusTone.good => _palette.good,
        MirpgStatusTone.warning => _palette.warning,
        MirpgStatusTone.error => _palette.error,
        MirpgStatusTone.neutral => _palette.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Semantics(
        selected: current,
        button: true,
        enabled: enabled,
        child: Opacity(
          opacity: enabled || current ? 1 : 0.5,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            // The current chip answers "which emulator is this"; tapping it
            // does nothing.
            onTap: enabled && !current ? onTap : null,
            child: SizedBox(
              height: 48,
              child: Center(
                widthFactor: 1,
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.only(left: 10, right: 12),
                  decoration: BoxDecoration(
                    color: current
                        ? _palette.accent.withOpacity(0.24)
                        : _palette.raised,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: current ? _palette.accent : _palette.outline),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: _dot),
                    ),
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
