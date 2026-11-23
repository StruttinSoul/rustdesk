import 'package:flutter/material.dart';
import 'package:settings_ui/settings_ui.dart';

import '../../common.dart' show translate;
import '../../common/widgets/studio_theme.dart';

/// Groups of the phone Settings page, in display order.
enum SettingsGroup {
  account('Account'),
  appearance('Appearance'),
  displayDefaults('Display defaults'),
  sharing('Sharing this phone'),
  security('Security'),
  network('Network'),
  recording('Recording'),
  about('About Aperture');

  const SettingsGroup(this.title);

  /// Translate key (and English text) of the group title.
  final String title;
}

/// Row ids of each group, in display order. Every row the page builds has
/// exactly one place here; the page decides whether a row is present.
const Map<SettingsGroup, List<String>> kMobileSettingsLayout = {
  SettingsGroup.account: ['account'],
  SettingsGroup.appearance: ['appearance', 'language'],
  SettingsGroup.displayDefaults: [
    'display-settings',
    'hwcodec',
    'keep-awake-outgoing',
    'note-at-conn-end',
    'terminal-extra-keys',
  ],
  SettingsGroup.sharing: [
    'background-service',
    'start-on-boot',
    'floating-window',
    'keep-screen-on',
    'deny-lan-discovery',
    'ip-whitelisting',
    'id-whitelisting',
    'adaptive-bitrate',
    'enable-recording-session',
    'direct-ip-access',
    'auto-disconnect',
  ],
  SettingsGroup.security: [
    '2fa',
    'telegram-bot',
    'trusted-devices',
    'manage-trusted-devices',
  ],
  SettingsGroup.network: [
    'id-relay-server',
    'proxy',
    'deploy',
    'websocket',
    'insecure-tls-fallback',
    'disable-udp',
    'tcp-punch',
    'udp-punch',
    'ipv6-punch',
    'webrtc',
  ],
  SettingsGroup.recording: [
    'auto-record-incoming',
    'auto-record-outgoing',
    'recording-directory',
  ],
  SettingsGroup.about: [
    'version',
    'build-date',
    'fingerprint',
    'my-id',
    'privacy-statement',
    'built-on-rustdesk',
  ],
};

/// Builds the grouped sections from the rows the page decided to show.
///
/// Groups follow [SettingsGroup] order and rows follow [kMobileSettingsLayout];
/// a group without a present row is skipped. The network group opens with an
/// "Advanced" toggle and lists its rows only when [networkExpanded]. A row id
/// the layout does not know is shown in a final "Other" section.
List<AbstractSettingsSection> buildMobileSettingsSections({
  required Map<String, AbstractSettingsTile> rows,
  required bool networkExpanded,
  required VoidCallback onToggleNetwork,
  String Function(String) tr = translate,
}) {
  final sections = <AbstractSettingsSection>[];
  for (final group in SettingsGroup.values) {
    final tiles = [
      for (final id in kMobileSettingsLayout[group] ?? const <String>[])
        if (rows[id] != null) rows[id]!,
    ];
    if (tiles.isEmpty) continue;
    if (group == SettingsGroup.network) {
      sections.add(SettingsSection(title: Text(tr(group.title)), tiles: [
        SettingsTile(
          title: Text(tr('Advanced')),
          description: Text(tr('Server, proxy and connection options')),
          trailing:
              Icon(networkExpanded ? Icons.expand_less : Icons.expand_more),
          onPressed: (_) => onToggleNetwork(),
        ),
        if (networkExpanded) ...tiles,
      ]));
    } else {
      sections.add(SettingsSection(title: Text(tr(group.title)), tiles: tiles));
    }
  }
  final placed = kMobileSettingsLayout.values.expand((ids) => ids).toSet();
  final others = [
    for (final entry in rows.entries)
      if (!placed.contains(entry.key)) entry.value,
  ];
  if (others.isNotEmpty) {
    sections.add(SettingsSection(title: Text(tr('Other')), tiles: others));
  }
  return sections;
}

/// `settings_ui` colours for the Studio [palette].
SettingsThemeData studioSettingsTheme(MirpgStudioPalette palette) =>
    SettingsThemeData(
      settingsListBackground: palette.background,
      settingsSectionBackground: palette.surface,
      titleTextColor: palette.accent,
      settingsTileTextColor: palette.textPrimary,
      tileDescriptionTextColor: palette.textSecondary,
      leadingIconsColor: palette.textSecondary,
      trailingTextColor: palette.textSecondary,
      dividerColor: palette.divider,
      tileHighlightColor: palette.raised,
      inactiveTitleColor: palette.textSecondary,
      inactiveSubtitleColor: palette.textSecondary,
    );

/// A [SettingsList] painted with the Studio palette instead of the package's
/// own greys and blue section titles. Colour only: layout is unchanged.
class MobileSettingsList extends StatelessWidget {
  const MobileSettingsList({super.key, required this.sections});

  final List<AbstractSettingsSection> sections;

  @override
  Widget build(BuildContext context) => SettingsList(
        sections: sections,
        lightTheme: studioSettingsTheme(MirpgStudioPalette.light),
        darkTheme: studioSettingsTheme(MirpgStudioPalette.dark),
      );
}
