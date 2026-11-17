import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../common/widgets/studio_theme.dart';

/// The PC tab of a connected session: what the PC offers, the connection,
/// the app, and End session (always present, always last, so a session can
/// be ended however little the PC exposes).
class PcTabBody extends StatelessWidget {
  const PcTabBody({
    super.key,
    this.onSystem,
    this.onFiles,
    this.onPowerShell,
    required this.onQuality,
    this.onPrivacy,
    this.pairingState = '',
    this.onTrustPhone,
    this.onForgetPairing,
    required this.onSettings,
    required this.onEndSession,
    this.tr = translate,
  });

  final VoidCallback? onSystem;
  final VoidCallback? onFiles;
  final VoidCallback? onPowerShell;
  final VoidCallback onQuality;
  final VoidCallback? onPrivacy;

  /// `'paired' | 'can-pair' | 'unavailable' | ''`.
  final String pairingState;
  final VoidCallback? onTrustPhone;
  final VoidCallback? onForgetPairing;
  final VoidCallback onSettings;
  final VoidCallback onEndSession;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final palette = MirpgStudioPalette.of(context);
    final textTheme = Theme.of(context).textTheme;

    Widget row(IconData icon, String title, String? subtitle, VoidCallback onTap,
            {Widget? trailing}) =>
        ListTile(
          minTileHeight: 56,
          leading: Icon(icon),
          title: Text(tr(title)),
          subtitle: subtitle == null ? null : Text(tr(subtitle)),
          trailing: trailing ?? const Icon(Icons.chevron_right),
          onTap: onTap,
        );

    Widget group(String title, List<Widget> rows) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                tr(title),
                style: textTheme.labelMedium?.copyWith(
                    color: palette.textSecondary,
                    fontWeight: FontWeight.w600),
              ),
            ),
            MirpgSurface(
              padding: EdgeInsets.zero,
              child: Material(
                type: MaterialType.transparency,
                child: Column(children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    rows[i],
                    if (i < rows.length - 1)
                      Divider(height: 1, color: palette.divider),
                  ],
                ]),
              ),
            ),
          ],
        );

    final thisPc = <Widget>[
      if (onSystem != null)
        row(Icons.monitor_heart_outlined, 'System and processes',
            'PC status, processes and host controls', onSystem!),
      if (onFiles != null)
        row(Icons.folder_outlined, 'Files', 'Browse and transfer files',
            onFiles!),
      if (onPowerShell != null)
        row(Icons.terminal_outlined, 'PowerShell',
            'Open the authenticated remote terminal', onPowerShell!),
    ];
    final connection = <Widget>[
      row(Icons.network_check_outlined, 'Quality and connection',
          'Direct or relay route, latency and stream health', onQuality),
      if (onPrivacy != null)
        row(Icons.privacy_tip_outlined, 'Privacy and host controls',
            null, onPrivacy!),
      if (pairingState == 'paired' && onForgetPairing != null)
        ListTile(
          minTileHeight: 56,
          leading: const Icon(Icons.phonelink_lock_outlined),
          title: Text(tr('This phone is trusted')),
          subtitle: Text(tr('Connects without a password')),
          trailing: TextButton(
            onPressed: onForgetPairing,
            child: Text(tr('Forget')),
          ),
        ),
      if (pairingState == 'can-pair' && onTrustPhone != null)
        row(Icons.phonelink_lock_outlined, 'Trust this phone',
            'Connect without a password at home', onTrustPhone!),
    ];

    return ListView(
      padding: const EdgeInsets.all(MirpgRemoteTheme.pageMargin),
      children: [
        if (thisPc.isNotEmpty) ...[
          group('This PC', thisPc),
          const SizedBox(height: MirpgRemoteTheme.pageMargin),
        ],
        group('Connection', connection),
        const SizedBox(height: MirpgRemoteTheme.pageMargin),
        group('App', [
          row(Icons.settings_outlined, 'Appearance and settings',
              'System, light or dark mode and more', onSettings),
        ]),
        const Divider(height: 32),
        MirpgSurface(
          padding: EdgeInsets.zero,
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.logout, color: palette.error),
              title: Text(
                tr('End session'),
                style: textTheme.bodyLarge?.copyWith(color: palette.error),
              ),
              onTap: onEndSession,
            ),
          ),
        ),
      ],
    );
  }
}
