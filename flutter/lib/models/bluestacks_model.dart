import 'dart:convert';

import 'package:flutter/foundation.dart';

typedef BlueStacksInventoryReader = Future<String> Function();
typedef BlueStacksActionSender = Future<void> Function(String payload);

enum BlueStacksCleanupProfile {
  standard,
  cleanGaming,
  custom,
}

extension BlueStacksCleanupProfileWire on BlueStacksCleanupProfile {
  String get wireValue {
    switch (this) {
      case BlueStacksCleanupProfile.standard:
        return 'standard';
      case BlueStacksCleanupProfile.cleanGaming:
        return 'clean_gaming';
      case BlueStacksCleanupProfile.custom:
        return 'custom';
    }
  }

  String get label {
    switch (this) {
      case BlueStacksCleanupProfile.standard:
        return 'Standard';
      case BlueStacksCleanupProfile.cleanGaming:
        return 'Clean Gaming';
      case BlueStacksCleanupProfile.custom:
        return 'Custom';
    }
  }
}

class BlueStacksCleanupSelection {
  const BlueStacksCleanupSelection({
    this.disableGameplayAds = false,
    this.disableSmartDownloads = false,
    this.disableStoreOnStart = false,
    this.disableDesktopNotifications = false,
    this.disableAppShortcuts = false,
    this.disableOptionalStartup = false,
    this.hideDesktopShortcuts = false,
    this.removeOptionalComponents = false,
    this.disableOptionalAndroidApps = false,
  });

  final bool disableGameplayAds;
  final bool disableSmartDownloads;
  final bool disableStoreOnStart;
  final bool disableDesktopNotifications;
  final bool disableAppShortcuts;
  final bool disableOptionalStartup;
  final bool hideDesktopShortcuts;
  final bool removeOptionalComponents;
  final bool disableOptionalAndroidApps;

  factory BlueStacksCleanupSelection.forProfile(
      BlueStacksCleanupProfile profile) {
    switch (profile) {
      case BlueStacksCleanupProfile.standard:
        return const BlueStacksCleanupSelection(
          disableGameplayAds: true,
          disableSmartDownloads: true,
          disableStoreOnStart: true,
        );
      case BlueStacksCleanupProfile.cleanGaming:
        return const BlueStacksCleanupSelection(
          disableGameplayAds: true,
          disableSmartDownloads: true,
          disableStoreOnStart: true,
          disableDesktopNotifications: true,
          disableAppShortcuts: true,
          disableOptionalStartup: true,
          hideDesktopShortcuts: true,
        );
      case BlueStacksCleanupProfile.custom:
        return const BlueStacksCleanupSelection();
    }
  }

  factory BlueStacksCleanupSelection.fromJson(Map<String, dynamic> json) =>
      BlueStacksCleanupSelection(
        disableGameplayAds: _asBool(json['disable_gameplay_ads']),
        disableSmartDownloads: _asBool(json['disable_smart_downloads']),
        disableStoreOnStart: _asBool(json['disable_store_on_start']),
        disableDesktopNotifications:
            _asBool(json['disable_desktop_notifications']),
        disableAppShortcuts: _asBool(json['disable_app_shortcuts']),
        disableOptionalStartup: _asBool(json['disable_optional_startup']),
        hideDesktopShortcuts: _asBool(json['hide_desktop_shortcuts']),
        removeOptionalComponents: _asBool(json['remove_optional_components']),
        disableOptionalAndroidApps:
            _asBool(json['disable_optional_android_apps']),
      );

  Map<String, dynamic> toJson() => {
        'disable_gameplay_ads': disableGameplayAds,
        'disable_smart_downloads': disableSmartDownloads,
        'disable_store_on_start': disableStoreOnStart,
        'disable_desktop_notifications': disableDesktopNotifications,
        'disable_app_shortcuts': disableAppShortcuts,
        'disable_optional_startup': disableOptionalStartup,
        'hide_desktop_shortcuts': hideDesktopShortcuts,
        'remove_optional_components': removeOptionalComponents,
        'disable_optional_android_apps': disableOptionalAndroidApps,
      };

  BlueStacksCleanupSelection copyWith({
    bool? disableGameplayAds,
    bool? disableSmartDownloads,
    bool? disableStoreOnStart,
    bool? disableDesktopNotifications,
    bool? disableAppShortcuts,
    bool? disableOptionalStartup,
    bool? hideDesktopShortcuts,
    bool? removeOptionalComponents,
    bool? disableOptionalAndroidApps,
  }) =>
      BlueStacksCleanupSelection(
        disableGameplayAds: disableGameplayAds ?? this.disableGameplayAds,
        disableSmartDownloads:
            disableSmartDownloads ?? this.disableSmartDownloads,
        disableStoreOnStart: disableStoreOnStart ?? this.disableStoreOnStart,
        disableDesktopNotifications:
            disableDesktopNotifications ?? this.disableDesktopNotifications,
        disableAppShortcuts: disableAppShortcuts ?? this.disableAppShortcuts,
        disableOptionalStartup:
            disableOptionalStartup ?? this.disableOptionalStartup,
        hideDesktopShortcuts: hideDesktopShortcuts ?? this.hideDesktopShortcuts,
        removeOptionalComponents:
            removeOptionalComponents ?? this.removeOptionalComponents,
        disableOptionalAndroidApps:
            disableOptionalAndroidApps ?? this.disableOptionalAndroidApps,
      );

  bool equivalentTo(BlueStacksCleanupSelection other) =>
      disableGameplayAds == other.disableGameplayAds &&
      disableSmartDownloads == other.disableSmartDownloads &&
      disableStoreOnStart == other.disableStoreOnStart &&
      disableDesktopNotifications == other.disableDesktopNotifications &&
      disableAppShortcuts == other.disableAppShortcuts &&
      disableOptionalStartup == other.disableOptionalStartup &&
      hideDesktopShortcuts == other.hideDesktopShortcuts &&
      removeOptionalComponents == other.removeOptionalComponents &&
      disableOptionalAndroidApps == other.disableOptionalAndroidApps;
}

class BlueStacksCleanupSupport {
  const BlueStacksCleanupSupport({
    this.disableGameplayAds = false,
    this.disableSmartDownloads = false,
    this.disableStoreOnStart = false,
    this.disableDesktopNotifications = false,
    this.disableAppShortcuts = false,
    this.disableOptionalStartup = false,
    this.hideDesktopShortcuts = false,
  });

  final bool disableGameplayAds;
  final bool disableSmartDownloads;
  final bool disableStoreOnStart;
  final bool disableDesktopNotifications;
  final bool disableAppShortcuts;
  final bool disableOptionalStartup;
  final bool hideDesktopShortcuts;

  factory BlueStacksCleanupSupport.fromJson(Map<String, dynamic> json) =>
      BlueStacksCleanupSupport(
        disableGameplayAds: _asBool(json['disable_gameplay_ads']),
        disableSmartDownloads: _asBool(json['disable_smart_downloads']),
        disableStoreOnStart: _asBool(json['disable_store_on_start']),
        disableDesktopNotifications:
            _asBool(json['disable_desktop_notifications']),
        disableAppShortcuts: _asBool(json['disable_app_shortcuts']),
        disableOptionalStartup: _asBool(json['disable_optional_startup']),
        hideDesktopShortcuts: _asBool(json['hide_desktop_shortcuts']),
      );
}

class BlueStacksInstallationInfo {
  const BlueStacksInstallationInfo({
    this.version = '',
    this.installDir = '',
    this.dataDir = '',
    this.userDefinedDir = '',
    this.configPath = '',
    this.playerPath = '',
    this.adbPath = '',
    this.multiInstanceManagerPath = '',
    this.multiInstanceManagerAvailable = false,
  });

  final String version;
  final String installDir;
  final String dataDir;
  final String userDefinedDir;
  final String configPath;
  final String playerPath;
  final String adbPath;
  final String multiInstanceManagerPath;
  final bool multiInstanceManagerAvailable;

  factory BlueStacksInstallationInfo.fromJson(Map<String, dynamic> json) =>
      BlueStacksInstallationInfo(
        version: _asString(json['version']),
        installDir: _asString(json['install_dir']),
        dataDir: _asString(json['data_dir']),
        userDefinedDir: _asString(json['user_defined_dir']),
        configPath: _asString(json['config_path']),
        playerPath: _asString(json['player_path']),
        adbPath: _asString(json['adb_path']),
        multiInstanceManagerPath:
            _asString(json['multi_instance_manager_path']),
        multiInstanceManagerAvailable:
            _asBool(json['multi_instance_manager_available']),
      );
}

class BlueStacksInstanceInfo {
  const BlueStacksInstanceInfo({
    required this.id,
    required this.displayName,
    required this.androidFlavor,
    required this.androidVersion,
    required this.running,
    required this.adbEnabled,
    required this.adbPort,
    required this.notificationsEnabled,
    required this.width,
    required this.height,
    required this.dpi,
    required this.defaultPackage,
  });

  final String id;
  final String displayName;
  final String androidFlavor;
  final String androidVersion;
  final bool running;
  final bool adbEnabled;
  final int? adbPort;
  final bool? notificationsEnabled;
  final int? width;
  final int? height;
  final int? dpi;
  final String defaultPackage;

  factory BlueStacksInstanceInfo.fromJson(Map<String, dynamic> json) =>
      BlueStacksInstanceInfo(
        id: _asString(json['id']),
        displayName: _asString(json['display_name']),
        androidFlavor: _asString(json['android_flavor']),
        androidVersion: _asString(json['android_version']),
        running: _asBool(json['running']),
        adbEnabled: _asBool(json['adb_enabled']),
        adbPort: _asNullableInt(json['adb_port']),
        notificationsEnabled: _asNullableBool(json['notifications_enabled']),
        width: _asNullableInt(json['width']),
        height: _asNullableInt(json['height']),
        dpi: _asNullableInt(json['dpi']),
        defaultPackage: _asString(json['default_package']),
      );
}

class BlueStacksServiceInfo {
  const BlueStacksServiceInfo({
    required this.name,
    required this.displayName,
    required this.imagePath,
    required this.classification,
  });

  final String name;
  final String displayName;
  final String imagePath;
  final String classification;

  factory BlueStacksServiceInfo.fromJson(Map<String, dynamic> json) =>
      BlueStacksServiceInfo(
        name: _asString(json['name']),
        displayName: _asString(json['display_name']),
        imagePath: _asString(json['image_path']),
        classification: _asString(json['classification']),
      );
}

class BlueStacksStartupEntryInfo {
  const BlueStacksStartupEntryInfo({
    required this.id,
    required this.valueName,
    required this.command,
    required this.classification,
    required this.safeToDisable,
  });

  final String id;
  final String valueName;
  final String command;
  final String classification;
  final bool safeToDisable;

  factory BlueStacksStartupEntryInfo.fromJson(Map<String, dynamic> json) =>
      BlueStacksStartupEntryInfo(
        id: _asString(json['id']),
        valueName: _asString(json['value_name']),
        command: _asString(json['command']),
        classification: _asString(json['classification']),
        safeToDisable: _asBool(json['safe_to_disable']),
      );
}

class BlueStacksShortcutInfo {
  const BlueStacksShortcutInfo({
    required this.path,
    required this.name,
    required this.location,
    required this.recommendedCleanup,
  });

  final String path;
  final String name;
  final String location;
  final bool recommendedCleanup;

  factory BlueStacksShortcutInfo.fromJson(Map<String, dynamic> json) =>
      BlueStacksShortcutInfo(
        path: _asString(json['path']),
        name: _asString(json['name']),
        location: _asString(json['location']),
        recommendedCleanup: _asBool(json['recommended_cleanup']),
      );
}

class BlueStacksComponentInfo {
  const BlueStacksComponentInfo({
    required this.id,
    required this.displayName,
    required this.version,
    required this.installLocation,
    required this.classification,
    required this.canRemove,
  });

  final String id;
  final String displayName;
  final String version;
  final String installLocation;
  final String classification;
  final bool canRemove;

  factory BlueStacksComponentInfo.fromJson(Map<String, dynamic> json) =>
      BlueStacksComponentInfo(
        id: _asString(json['id']),
        displayName: _asString(json['display_name']),
        version: _asString(json['version']),
        installLocation: _asString(json['install_location']),
        classification: _asString(json['classification']),
        canRemove: _asBool(json['can_remove']),
      );
}

class BlueStacksAndroidPackageInfo {
  const BlueStacksAndroidPackageInfo({
    required this.package,
    required this.classification,
    required this.userInstalled,
    required this.disabled,
  });

  final String package;
  final String classification;
  final bool userInstalled;
  final bool disabled;

  bool get canDisable => classification == 'optional_promotional' && !disabled;

  factory BlueStacksAndroidPackageInfo.fromJson(Map<String, dynamic> json) =>
      BlueStacksAndroidPackageInfo(
        package: _asString(json['package']),
        classification: _asString(json['classification']),
        userInstalled: _asBool(json['user_installed']),
        disabled: _asBool(json['disabled']),
      );
}

class BlueStacksAndroidPackageInventory {
  const BlueStacksAndroidPackageInventory({
    required this.instanceId,
    required this.available,
    required this.message,
    required this.packages,
  });

  final String instanceId;
  final bool available;
  final String message;
  final List<BlueStacksAndroidPackageInfo> packages;

  factory BlueStacksAndroidPackageInventory.fromJson(
          Map<String, dynamic> json) =>
      BlueStacksAndroidPackageInventory(
        instanceId: _asString(json['instance_id']),
        available: _asBool(json['available']),
        message: _asString(json['message']),
        packages: _asList(json['packages'])
            .map((item) => BlueStacksAndroidPackageInfo.fromJson(_asMap(item)))
            .toList(growable: false),
      );
}

class BlueStacksInventory {
  const BlueStacksInventory({
    this.installed = false,
    this.installation = const BlueStacksInstallationInfo(),
    this.hypervisor = '',
    this.instances = const [],
    this.services = const [],
    this.startupEntries = const [],
    this.shortcuts = const [],
    this.components = const [],
    this.cleanupSupport = const BlueStacksCleanupSupport(),
    this.selectedCleanup,
    this.lastCleanupVersion = '',
    this.cleanupNeedsReapply = false,
    this.restoreAvailable = false,
  });

  final bool installed;
  final BlueStacksInstallationInfo installation;
  final String hypervisor;
  final List<BlueStacksInstanceInfo> instances;
  final List<BlueStacksServiceInfo> services;
  final List<BlueStacksStartupEntryInfo> startupEntries;
  final List<BlueStacksShortcutInfo> shortcuts;
  final List<BlueStacksComponentInfo> components;
  final BlueStacksCleanupSupport cleanupSupport;
  final BlueStacksCleanupSelection? selectedCleanup;
  final String lastCleanupVersion;
  final bool cleanupNeedsReapply;
  final bool restoreAvailable;

  factory BlueStacksInventory.fromJson(Map<String, dynamic> json) =>
      BlueStacksInventory(
        installed: _asBool(json['installed']),
        installation:
            BlueStacksInstallationInfo.fromJson(_asMap(json['installation'])),
        hypervisor: _asString(json['hypervisor']),
        instances: _asList(json['instances'])
            .map((item) => BlueStacksInstanceInfo.fromJson(_asMap(item)))
            .toList(growable: false),
        services: _asList(json['services'])
            .map((item) => BlueStacksServiceInfo.fromJson(_asMap(item)))
            .toList(growable: false),
        startupEntries: _asList(json['startup_entries'])
            .map((item) => BlueStacksStartupEntryInfo.fromJson(_asMap(item)))
            .toList(growable: false),
        shortcuts: _asList(json['shortcuts'])
            .map((item) => BlueStacksShortcutInfo.fromJson(_asMap(item)))
            .toList(growable: false),
        components: _asList(json['components'])
            .map((item) => BlueStacksComponentInfo.fromJson(_asMap(item)))
            .toList(growable: false),
        cleanupSupport:
            BlueStacksCleanupSupport.fromJson(_asMap(json['cleanup_support'])),
        selectedCleanup: json['selected_cleanup'] == null
            ? null
            : BlueStacksCleanupSelection.fromJson(
                _asMap(json['selected_cleanup'])),
        lastCleanupVersion: _asString(json['last_cleanup_version']),
        cleanupNeedsReapply: _asBool(json['cleanup_needs_reapply']),
        restoreAvailable: _asBool(json['restore_available']),
      );
}

class BlueStacksModel with ChangeNotifier {
  BlueStacksModel({
    required BlueStacksInventoryReader inventoryReader,
    required BlueStacksActionSender actionSender,
  })  : _inventoryReader = inventoryReader,
        _actionSender = actionSender;

  final BlueStacksInventoryReader _inventoryReader;
  final BlueStacksActionSender _actionSender;

  BlueStacksInventory inventory = const BlueStacksInventory();
  BlueStacksCleanupProfile profile = BlueStacksCleanupProfile.cleanGaming;
  BlueStacksCleanupSelection selection = BlueStacksCleanupSelection.forProfile(
      BlueStacksCleanupProfile.cleanGaming);
  final Map<String, BlueStacksAndroidPackageInventory> androidPackages = {};

  bool loading = false;
  bool actionPending = false;
  String error = '';
  String lastActionMessage = '';

  Future<void> refresh() async {
    loading = true;
    error = '';
    notifyListeners();
    try {
      final raw = await _inventoryReader();
      final envelope = _asMap(jsonDecode(raw));
      if (!_asBool(envelope['ok'])) {
        throw FormatException(
          _asString(envelope['error']).isEmpty
              ? 'BlueStacks inventory request failed'
              : _asString(envelope['error']),
        );
      }
      _adoptInventory(
        BlueStacksInventory.fromJson(_asMap(envelope['inventory'])),
      );
    } catch (e) {
      error = 'Unable to load BlueStacks: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void selectProfile(BlueStacksCleanupProfile value) {
    profile = value;
    if (value != BlueStacksCleanupProfile.custom) {
      selection = BlueStacksCleanupSelection.forProfile(value);
    }
    notifyListeners();
  }

  void updateCustomSelection(BlueStacksCleanupSelection value) {
    profile = BlueStacksCleanupProfile.custom;
    selection = value.copyWith(
      removeOptionalComponents: false,
      disableOptionalAndroidApps: false,
    );
    notifyListeners();
  }

  Future<void> applyProfile() async {
    final payload = <String, dynamic>{
      'action': 'apply_profile',
      'profile': profile.wireValue,
    };
    if (profile == BlueStacksCleanupProfile.custom) {
      payload['selection'] = selection
          .copyWith(
            removeOptionalComponents: false,
            disableOptionalAndroidApps: false,
          )
          .toJson();
    }
    await _send(payload);
  }

  Future<void> restore() => _send({'action': 'restore'});

  Future<void> setDefaultApp(String instanceId, String package) => _send({
        'action': 'set_default_app',
        'instance_id': instanceId,
        'package': package,
      });

  Future<void> launchDefaultApp(String instanceId) => _send({
        'action': 'launch_default_app',
        'instance_id': instanceId,
      });

  Future<void> inspectAndroidPackages(String instanceId) => _send({
        'action': 'inspect_android_packages',
        'instance_id': instanceId,
      });

  Future<void> disableOptionalAndroidPackage(
          String instanceId, String package) =>
      _send({
        'action': 'disable_optional_android_package',
        'instance_id': instanceId,
        'package': package,
        'confirmed': true,
      });

  Future<void> removeOptionalComponent(String componentId) => _send({
        'action': 'remove_optional_component',
        'component_id': componentId,
        'confirmed': true,
      });

  Future<void> handleActionResult(dynamic result) async {
    final value = _asMap(result);
    actionPending = false;
    if (!_asBool(value['ok'])) {
      error = _asString(value['error']).isEmpty
          ? 'BlueStacks action failed'
          : _asString(value['error']);
      notifyListeners();
      return;
    }

    error = '';
    final action = _asString(value['action']);
    final data = _asMap(value['data']);
    final inventoryJson = _asMap(data['inventory']);
    if (inventoryJson.isNotEmpty) {
      _adoptInventory(BlueStacksInventory.fromJson(inventoryJson));
    }

    if (action == 'inspect_android_packages' ||
        action == 'disable_optional_android_package') {
      final packageInventory = BlueStacksAndroidPackageInventory.fromJson(data);
      if (packageInventory.instanceId.isNotEmpty) {
        androidPackages[packageInventory.instanceId] = packageInventory;
      }
      lastActionMessage = packageInventory.message;
    } else if (action == 'launch_default_app') {
      lastActionMessage = _asString(data['message']);
    } else if (action == 'remove_optional_component') {
      lastActionMessage = _asString(data['message']);
      await refresh();
      return;
    } else {
      lastActionMessage = _actionSummary(action, data);
    }
    notifyListeners();
  }

  Future<void> _send(Map<String, dynamic> action) async {
    if (actionPending) return;
    actionPending = true;
    error = '';
    lastActionMessage = '';
    notifyListeners();
    try {
      await _actionSender(jsonEncode(action));
    } catch (e) {
      actionPending = false;
      error = 'Unable to send BlueStacks action: $e';
      notifyListeners();
    }
  }

  void _adoptInventory(BlueStacksInventory value) {
    inventory = value;
    final applied = value.selectedCleanup;
    if (applied == null) return;
    selection = applied.copyWith(
      removeOptionalComponents: false,
      disableOptionalAndroidApps: false,
    );
    final standard = BlueStacksCleanupSelection.forProfile(
      BlueStacksCleanupProfile.standard,
    );
    final cleanGaming = BlueStacksCleanupSelection.forProfile(
      BlueStacksCleanupProfile.cleanGaming,
    );
    if (selection.equivalentTo(standard)) {
      profile = BlueStacksCleanupProfile.standard;
    } else if (selection.equivalentTo(cleanGaming)) {
      profile = BlueStacksCleanupProfile.cleanGaming;
    } else {
      profile = BlueStacksCleanupProfile.custom;
    }
  }

  String _actionSummary(String action, Map<String, dynamic> data) {
    switch (action) {
      case 'apply_profile':
        final report = _asMap(data['report']);
        final skipped = _asList(report['skipped_actions'])
            .map(_asMap)
            .where((item) => _asString(item['target']).isNotEmpty)
            .toList(growable: false);
        if (skipped.isNotEmpty) {
          final adminTargets = skipped
              .where((item) => _asBool(item['requires_admin']))
              .map((item) => _asString(item['target']))
              .toList(growable: false);
          final targets = skipped
              .map((item) => _asString(item['target']))
              .take(3)
              .join(', ');
          final more = skipped.length > 3 ? ', …' : '';
          if (adminTargets.isNotEmpty) {
            return 'BlueStacks cleanup settings applied, but some items were left unchanged because administrator access is required: $targets$more';
          }
          return 'BlueStacks cleanup settings applied, but some items were left unchanged: $targets$more';
        }
        return 'BlueStacks cleanup settings applied.';
      case 'restore':
        final report = _asMap(data['report']);
        final manual = _asList(report['manual_reinstall_components']);
        final skipped = _asList(report['skipped_conflicts'])
            .map(_asString)
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
        if (skipped.isNotEmpty) {
          final details = skipped.take(3).join(', ');
          final more = skipped.length > 3 ? ', …' : '';
          final reinstall = manual.isNotEmpty
              ? ' Removed optional components still require manual reinstall.'
              : '';
          return 'BlueStacks restore completed with unresolved items: $details$more.$reinstall';
        }
        if (manual.isNotEmpty) {
          return 'Settings restored. Reinstall removed optional components manually if you want them back.';
        }
        return 'BlueStacks settings restored.';
      case 'set_default_app':
        return 'Default game saved for ${_asString(data['instance_id'])}.';
      default:
        return '';
    }
  }
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

List<dynamic> _asList(dynamic value) => value is List ? value : const [];

String _asString(dynamic value) => value?.toString() ?? '';

bool _asBool(dynamic value) => value == true || value?.toString() == 'true';

bool? _asNullableBool(dynamic value) => value == null ? null : _asBool(value);

int? _asNullableInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse(value.toString());
}
