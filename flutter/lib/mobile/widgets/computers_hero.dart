import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../common/widgets/studio_theme.dart';

enum ConnectPhase { idle, connecting, failed }

/// One connection attempt as the Computers page sees it.
@immutable
class ConnectAttempt {
  const ConnectAttempt({
    this.phase = ConnectPhase.idle,
    this.peerId = '',
    this.reason = '',
  });

  final ConnectPhase phase;
  final String peerId;
  final String reason;
}

/// Follows the connect flow without owning it. `RemotePage` keeps the session
/// and every connect dialog; it only reports when an attempt starts, reaches
/// the PC, and ends, so the card on the Computers page can say what happened.
class ConnectAttemptTracker extends ValueNotifier<ConnectAttempt> {
  ConnectAttemptTracker() : super(const ConnectAttempt());

  static final ConnectAttemptTracker shared = ConnectAttemptTracker();

  void started(String peerId) {
    value = ConnectAttempt(phase: ConnectPhase.connecting, peerId: peerId);
  }

  /// The PC accepted the connection: any earlier failure is over.
  void authenticated(String peerId) {
    if (peerId != value.peerId) return;
    value = const ConnectAttempt();
  }

  /// The page for [peerId] closed. Cancelling the "Connecting..." dialog or the
  /// password dialog leaves no [reason], so it is not a failure; only a
  /// connection error is.
  void ended(String peerId,
      {required bool authenticated, required String reason}) {
    if (peerId != value.peerId) return;
    if (authenticated || reason.isEmpty) {
      value = const ConnectAttempt();
    } else {
      value = ConnectAttempt(
          phase: ConnectPhase.failed, peerId: peerId, reason: reason);
    }
  }
}

@immutable
class ComputerHeroData {
  const ComputerHeroData({
    required this.id,
    required this.name,
    this.online,
    this.trusted = false,
  });

  final String id;
  final String name;

  /// null while it is not known.
  final bool? online;
  final bool trusted;
}

/// The last-used PC as one card with one button.
class ComputerHeroCard extends StatelessWidget {
  const ComputerHeroCard({
    super.key,
    required this.data,
    required this.attempt,
    required this.onConnect,
    this.tr = translate,
  });

  final ComputerHeroData data;
  final ConnectAttempt attempt;
  final VoidCallback onConnect;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MirpgStudioPalette.of(context);
    final mine = attempt.peerId == data.id;
    final connecting = mine && attempt.phase == ConnectPhase.connecting;
    final failed = mine && attempt.phase == ConnectPhase.failed;
    final name = data.name;
    return MirpgSurface(
      padding: const EdgeInsets.all(MirpgRemoteTheme.pageMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.desktop_windows_outlined,
                    size: 28, color: palette.textSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium),
              ),
              if (data.online != null) ...[
                const SizedBox(width: 8),
                MirpgStatusChip(
                  label: tr(data.online! ? 'Online' : 'Offline'),
                  tone: data.online!
                      ? MirpgStatusTone.good
                      : MirpgStatusTone.neutral,
                ),
              ],
            ],
          ),
          if (data.trusted) ...[
            const SizedBox(height: 8),
            Text(tr('Trusted · connects without password'),
                style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          if (failed) ...[
            Semantics(
              liveRegion: true,
              child: Text(tr('Couldn\'t connect to {$name}'),
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: palette.error)),
            ),
            if (attempt.reason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(tr(attempt.reason),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            FilledButton(onPressed: onConnect, child: Text(tr('Try again'))),
          ] else if (connecting)
            FilledButton(
              onPressed: null,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Flexible(child: Text(tr('Connecting…'))),
                ],
              ),
            )
          else
            FilledButton(onPressed: onConnect, child: Text(tr('Connect'))),
        ],
      ),
    );
  }
}

/// "Add another computer" folded away under the hero, or "Add a computer" with
/// the ID field open when there is no last-used PC. Saved computers and the
/// address book are one level down.
class AddComputerSection extends StatelessWidget {
  const AddComputerSection({
    super.key,
    required this.hasHero,
    required this.expanded,
    required this.onExpandedChanged,
    required this.idField,
    required this.onSavedComputers,
    this.tr = translate,
  });

  final bool hasHero;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  final Widget idField;
  final VoidCallback onSavedComputers;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = MirpgStudioPalette.of(context);
    final open = !hasHero || expanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasHero)
          InkWell(
            borderRadius: BorderRadius.circular(MirpgRemoteTheme.controlRadius),
            onTap: () => onExpandedChanged(!expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  Expanded(
                    child: Text(tr('Add another computer'),
                        style: theme.textTheme.titleSmall),
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: palette.textSecondary),
                ],
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child:
                Text(tr('Add a computer'), style: theme.textTheme.titleMedium),
          ),
        if (open) ...[
          idField,
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(MirpgRemoteTheme.controlRadius),
            onTap: onSavedComputers,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  Icon(Icons.bookmarks_outlined, color: palette.textSecondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(tr('Saved computers'),
                        style: theme.textTheme.titleSmall),
                  ),
                  Icon(Icons.chevron_right, color: palette.textSecondary),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
