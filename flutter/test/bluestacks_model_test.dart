import 'dart:convert';

import 'package:flutter_hbb/models/bluestacks_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes BlueStacks inventory and update state', () async {
    final model = BlueStacksModel(
      inventoryReader: () async => jsonEncode({
        'ok': true,
        'inventory': {
          'installed': true,
          'installation': {
            'version': '5.22.280.1026',
            'install_dir': r'C:\Program Files\BlueStacks_nxt',
            'data_dir': r'C:\ProgramData\BlueStacks_nxt',
            'user_defined_dir': r'C:\ProgramData\BlueStacks_nxt',
            'config_path': r'C:\ProgramData\BlueStacks_nxt\bluestacks.conf',
            'player_path': r'C:\Program Files\BlueStacks_nxt\HD-Player.exe',
            'adb_path': r'C:\Program Files\BlueStacks_nxt\HD-Adb.exe',
            'multi_instance_manager_path':
                r'C:\Program Files\BlueStacks_nxt\HD-MultiInstanceManager.exe',
            'multi_instance_manager_available': true,
          },
          'hypervisor': 'hyperv',
          'instances': [
            {
              'id': 'Nougat32',
              'display_name': 'MapleStory',
              'android_flavor': 'Nougat 32-bit',
              'android_version': '7.1.2',
              'running': false,
              'adb_enabled': false,
              'adb_port': 5555,
              'notifications_enabled': true,
              'width': 1920,
              'height': 1080,
              'dpi': 240,
              'default_package': 'com.nexon.maplem.global',
            }
          ],
          'services': [
            {
              'name': 'BlueStacksDrv_nxt',
              'display_name': 'BlueStacks Hypervisor_nxt',
              'image_path': r'C:\Program Files\BlueStacks_nxt\BstkDrv_nxt.sys',
              'classification': 'required',
            }
          ],
          'startup_entries': [],
          'shortcuts': [],
          'components': [
            {
              'id': 'filesystem|BlueStacks X',
              'display_name': 'BlueStacks X',
              'version': '',
              'install_location': r'C:\Program Files (x86)\BlueStacks X',
              'classification': 'promotional_frontend',
              'can_remove': true,
            }
          ],
          'cleanup_support': {
            'disable_gameplay_ads': true,
            'disable_smart_downloads': true,
            'disable_store_on_start': true,
            'disable_desktop_notifications': true,
            'disable_app_shortcuts': true,
            'disable_optional_startup': true,
            'hide_desktop_shortcuts': true,
          },
          'selected_cleanup': null,
          'last_cleanup_version': '5.22.200.0',
          'cleanup_needs_reapply': true,
          'restore_available': true,
        }
      }),
      actionSender: (_) async {},
    );

    await model.refresh();

    expect(model.error, isEmpty);
    expect(model.inventory.installed, isTrue);
    expect(model.inventory.installation.version, '5.22.280.1026');
    expect(model.inventory.hypervisor, 'hyperv');
    expect(model.inventory.instances.single.id, 'Nougat32');
    expect(model.inventory.instances.single.defaultPackage,
        'com.nexon.maplem.global');
    expect(model.inventory.components.single.canRemove, isTrue);
    expect(model.inventory.cleanupNeedsReapply, isTrue);
    expect(model.inventory.restoreAvailable, isTrue);
  });

  test('Clean Gaming is recommended default and Custom preserves toggles', () {
    final model = BlueStacksModel(
      inventoryReader: () async => '{"ok":true,"inventory":{}}',
      actionSender: (_) async {},
    );

    expect(model.profile, BlueStacksCleanupProfile.cleanGaming);
    expect(model.selection.disableGameplayAds, isTrue);
    expect(model.selection.disableOptionalStartup, isTrue);
    expect(model.selection.hideDesktopShortcuts, isTrue);
    expect(model.selection.removeOptionalComponents, isFalse);
    expect(model.selection.disableOptionalAndroidApps, isFalse);

    model.selectProfile(BlueStacksCleanupProfile.custom);
    model.updateCustomSelection(
      model.selection.copyWith(
        disableSmartDownloads: false,
        hideDesktopShortcuts: false,
      ),
    );

    expect(model.profile, BlueStacksCleanupProfile.custom);
    expect(model.selection.disableGameplayAds, isTrue);
    expect(model.selection.disableSmartDownloads, isFalse);
    expect(model.selection.hideDesktopShortcuts, isFalse);
  });

  test('serializes safe profile and explicit destructive actions', () async {
    final sent = <Map<String, dynamic>>[];
    final model = BlueStacksModel(
      inventoryReader: () async => '{"ok":true,"inventory":{}}',
      actionSender: (payload) async {
        sent.add(jsonDecode(payload) as Map<String, dynamic>);
      },
    );

    await model.applyProfile();
    expect(sent.last['action'], 'apply_profile');
    expect(sent.last['profile'], 'clean_gaming');
    expect(sent.last.containsKey('selection'), isFalse);
    await model.handleActionResult({
      'ok': true,
      'action': 'apply_profile',
      'data': <String, dynamic>{},
    });

    await model.removeOptionalComponent('filesystem|BlueStacks X');
    expect(sent.last['action'], 'remove_optional_component');
    expect(sent.last['confirmed'], isTrue);
    await model.handleActionResult({
      'ok': true,
      'action': 'remove_optional_component',
      'data': {
        'message': 'Removal started.',
      },
    });

    await model.disableOptionalAndroidPackage(
      'Nougat32',
      'com.uncube.gamevantage',
    );
    expect(sent.last['action'], 'disable_optional_android_package');
    expect(sent.last['confirmed'], isTrue);
  });

  test('restore summary surfaces skipped conflicts', () async {
    final model = BlueStacksModel(
      inventoryReader: () async => '{"ok":true,"inventory":{}}',
      actionSender: (_) async {},
    );

    await model.restore();
    await model.handleActionResult({
      'ok': true,
      'action': 'restore',
      'data': {
        'report': {
          'skipped_conflicts': ['Nougat32: ADB disabled'],
          'manual_reinstall_components': <String>[],
        },
      },
    });

    expect(model.lastActionMessage, contains('Nougat32: ADB disabled'));
  });

  test('cleanup summary surfaces skipped actions that require admin', () async {
    final model = BlueStacksModel(
      inventoryReader: () async => '{"ok":true,"inventory":{}}',
      actionSender: (_) async {},
    );

    await model.applyProfile();
    await model.handleActionResult({
      'ok': true,
      'action': 'apply_profile',
      'data': {
        'report': {
          'skipped_actions': [
            {
              'action': 'hide_desktop_shortcut',
              'target': r'C:\Users\Public\Desktop\BlueStacks 5.lnk',
              'error': 'Access is denied. (os error 5)',
              'requires_admin': true,
            }
          ],
        },
      },
    });

    expect(model.lastActionMessage, contains('administrator'));
    expect(model.lastActionMessage, contains('BlueStacks 5.lnk'));
  });
}
