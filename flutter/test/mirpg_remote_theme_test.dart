import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';

void main() {
  test('MIRPG remote theme uses the fixed graphite and mint palette', () {
    final theme = MirpgRemoteTheme.build(ThemeData.light());

    expect(theme.useMaterial3, isTrue);
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, MirpgRemoteTheme.background);
    expect(theme.colorScheme.surface, MirpgRemoteTheme.surface);
    expect(theme.colorScheme.primary, MirpgRemoteTheme.accent);
    expect(theme.cardTheme.color, MirpgRemoteTheme.raised);
    expect(theme.navigationBarTheme.backgroundColor, MirpgRemoteTheme.surface);
    expect(theme.navigationBarTheme.indicatorColor,
        MirpgRemoteTheme.accent.withOpacity(0.18));
    expect(theme.textTheme.bodyLarge?.color, MirpgRemoteTheme.textPrimary);
    expect(theme.textTheme.bodyMedium?.color, MirpgRemoteTheme.textPrimary);
    expect(theme.textTheme.bodySmall?.color, MirpgRemoteTheme.textSecondary);
  });
}
