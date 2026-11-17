import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/studio_theme.dart' as common;
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart' as mobile;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('common and mobile imports name the same palette', () {
    expect(identical(common.MirpgStudioPalette.dark, mobile.MirpgStudioPalette.dark), isTrue);
    expect(common.MirpgRemoteTheme.destructiveFill, const Color(0xFFB43E43));
  });

  test('building Studio over Studio changes nothing', () {
    for (final base in [ThemeData.light(), ThemeData.dark()]) {
      final once = common.MirpgRemoteTheme.build(base);
      final twice = common.MirpgRemoteTheme.build(once);
      expect(twice.colorScheme, once.colorScheme);
      expect(twice.scaffoldBackgroundColor, once.scaffoldBackgroundColor);
      expect(twice.textTheme.titleMedium?.fontSize, 16);
      expect(twice.dialogTheme.backgroundColor, once.dialogTheme.backgroundColor);
    }
  });

  test('the shared theme file does not depend on mobile code', () {
    expect(File('lib/common/widgets/studio_theme.dart').readAsStringSync(),
        isNot(contains('mobile/')));
  });
}
