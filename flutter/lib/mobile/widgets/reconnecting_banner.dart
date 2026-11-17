import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../common/widgets/studio_theme.dart';
import '../../models/session_reconnect.dart';

/// A small "Reconnecting…" chip over the current view while the dashboard
/// session reconnects on its own. It never takes touches and is gone the
/// moment attempts stop (connected, or the error dialog took over).
class ReconnectingBanner extends StatelessWidget {
  const ReconnectingBanner({
    super.key,
    required this.controller,
    this.alignment = Alignment.bottomCenter,
    this.padding = const EdgeInsets.all(16),
    this.tr = translate,
  });

  final SessionReconnectController controller;
  final Alignment alignment;
  final EdgeInsets padding;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.showsReconnecting) return const SizedBox.shrink();
          return Positioned.fill(
            child: IgnorePointer(
              child: SafeArea(
                child: Padding(
                  padding: padding,
                  child: Align(
                    alignment: alignment,
                    child: MirpgStatusChip(
                      label: tr('Reconnecting…'),
                      icon: Icons.hourglass_top_rounded,
                      tone: MirpgStatusTone.warning,
                      onDarkSurface: true,
                      horizontalPadding: 12,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}
