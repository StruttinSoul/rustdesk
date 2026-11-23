final Stopwatch _hostMonotonicClock = Stopwatch()..start();

int hostMonotonicNowMs() => _hostMonotonicClock.elapsedMilliseconds;

class GatewayStatus {
  static const freshFor = Duration(seconds: 30);

  const GatewayStatus({
    required this.schema,
    required this.sampledAtMs,
    required this.receivedMonotonicMs,
    required this.requestStartedMonotonicMs,
    required this.installed,
    required this.processState,
    required this.gatewayPid,
    required this.processIdentity,
    required this.version,
    required this.reachability,
    required this.gatewayHealth,
    required this.apiVersion,
    required this.trustedPinMatched,
    required this.protectedHealthAvailable,
    required this.identityReady,
    required this.siloState,
    required this.siloProfileSelected,
    required this.siloProfileVerified,
    required this.activeSessions,
    required this.maxSessions,
    required this.imdbEnabled,
    required this.imdbState,
    required this.imdbRefreshing,
    required this.imdbUpdatedAt,
    required this.setupControlAvailable,
    required this.providerControlAvailable,
    required this.restartControlAvailable,
    required this.detail,
  });

  final int schema;
  final int sampledAtMs;
  final int receivedMonotonicMs;
  final int requestStartedMonotonicMs;
  final bool installed;
  final String processState;
  final int? gatewayPid;
  final String processIdentity;
  final String version;
  final String reachability;
  final String gatewayHealth;
  final String apiVersion;
  final bool? trustedPinMatched;
  final bool protectedHealthAvailable;
  final bool? identityReady;
  final String siloState;
  final bool? siloProfileSelected;
  final bool? siloProfileVerified;
  final int? activeSessions;
  final int? maxSessions;
  final bool? imdbEnabled;
  final String imdbState;
  final bool? imdbRefreshing;
  final String imdbUpdatedAt;
  final bool setupControlAvailable;
  final bool providerControlAvailable;
  final bool restartControlAvailable;
  final String detail;

  Duration? ageAt(int nowMonotonicMs) {
    final origin = requestStartedMonotonicMs >= 0
        ? requestStartedMonotonicMs
        : receivedMonotonicMs;
    if (origin < 0 || nowMonotonicMs < origin) return null;
    return Duration(milliseconds: nowMonotonicMs - origin);
  }

  bool isFreshAt(int nowMonotonicMs, {required bool connected}) {
    final age = ageAt(nowMonotonicMs);
    return connected && age != null && age <= freshFor;
  }

  bool get running => processState == 'running';
  bool get reachable => reachability == 'reachable';
  bool get healthMeasured => gatewayHealth.trim().isNotEmpty;
  bool get healthReady => switch (gatewayHealth.trim().toLowerCase()) {
        'ok' || 'ready' || 'healthy' => true,
        _ => false,
      };

  factory GatewayStatus.fromMap(
    Map value, {
    int? receivedMonotonicMs,
    int? requestStartedMonotonicMs,
  }) {
    final parsed = tryFromMap(
      value,
      receivedMonotonicMs: receivedMonotonicMs,
      requestStartedMonotonicMs: requestStartedMonotonicMs,
    );
    if (parsed == null) {
      throw const FormatException('Invalid Gateway status payload');
    }
    return parsed;
  }

  static GatewayStatus? tryFromMap(
    Map value, {
    int? receivedMonotonicMs,
    int? requestStartedMonotonicMs,
  }) {
    const requiredStrings = [
      'process_state',
      'process_identity',
      'version',
      'reachability',
      'gateway_health',
      'api_version',
      'silo_state',
      'imdb_state',
      'imdb_updated_at',
      'detail',
    ];
    const requiredBools = [
      'installed',
      'protected_health_available',
      'setup_control_available',
      'provider_control_available',
      'restart_control_available',
    ];
    const nullableBools = [
      'trusted_pin_matched',
      'identity_ready',
      'silo_profile_selected',
      'silo_profile_verified',
      'imdb_enabled',
      'imdb_refreshing',
    ];
    const nullableInts = [
      'gateway_pid',
      'active_sessions',
      'max_sessions',
    ];
    if (value['schema'] is! int ||
        value['sampled_at_ms'] is! int ||
        (value['sampled_at_ms'] as int) < 0 ||
        requiredStrings.any((key) => value[key] is! String) ||
        requiredBools.any((key) => value[key] is! bool) ||
        nullableBools.any((key) =>
            !value.containsKey(key) ||
            (value[key] != null && value[key] is! bool)) ||
        nullableInts.any((key) =>
            !value.containsKey(key) ||
            (value[key] != null && value[key] is! int)) ||
        nullableInts
            .any((key) => value[key] is int && (value[key] as int) < 0)) {
      return null;
    }
    return GatewayStatus(
        schema: value['schema'] as int,
        sampledAtMs: value['sampled_at_ms'] as int,
        receivedMonotonicMs: receivedMonotonicMs ?? hostMonotonicNowMs(),
        requestStartedMonotonicMs: requestStartedMonotonicMs ?? -1,
        installed: value['installed'] as bool,
        processState: value['process_state'] as String,
        gatewayPid: value['gateway_pid'] as int?,
        processIdentity: value['process_identity'] as String,
        version: value['version'] as String,
        reachability: value['reachability'] as String,
        gatewayHealth: value['gateway_health'] as String,
        apiVersion: value['api_version'] as String,
        trustedPinMatched: value['trusted_pin_matched'] as bool?,
        protectedHealthAvailable: value['protected_health_available'] as bool,
        identityReady: value['identity_ready'] as bool?,
        siloState: value['silo_state'] as String,
        siloProfileSelected: value['silo_profile_selected'] as bool?,
        siloProfileVerified: value['silo_profile_verified'] as bool?,
        activeSessions: value['active_sessions'] as int?,
        maxSessions: value['max_sessions'] as int?,
        imdbEnabled: value['imdb_enabled'] as bool?,
        imdbState: value['imdb_state'] as String,
        imdbRefreshing: value['imdb_refreshing'] as bool?,
        imdbUpdatedAt: value['imdb_updated_at'] as String,
        setupControlAvailable: value['setup_control_available'] as bool,
        providerControlAvailable: value['provider_control_available'] as bool,
        restartControlAvailable: value['restart_control_available'] as bool,
        detail: value['detail'] as String);
  }
}

class PhoneWorkspaceProfile {
  const PhoneWorkspaceProfile({
    required this.width,
    required this.height,
    required this.orientation,
    this.dpi = 0,
  });

  final int width;
  final int height;
  final String orientation;
  final int dpi;

  String get label =>
      '$width×$height · ${orientation == 'portrait' ? 'Portrait' : 'Landscape'}';

  factory PhoneWorkspaceProfile.fromMap(Map value) => PhoneWorkspaceProfile(
        width: (value['width'] as num?)?.toInt() ?? 0,
        height: (value['height'] as num?)?.toInt() ?? 0,
        orientation: value['orientation']?.toString() ?? '',
        dpi: (value['dpi'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is PhoneWorkspaceProfile &&
      width == other.width &&
      height == other.height &&
      orientation == other.orientation &&
      dpi == other.dpi;

  @override
  int get hashCode => Object.hash(width, height, orientation, dpi);
}

class PhoneWorkspaceSession {
  const PhoneWorkspaceSession({
    required this.id,
    required this.driver,
    required this.deviceName,
    required this.profile,
  });

  final String id;
  final String driver;
  final String deviceName;
  final PhoneWorkspaceProfile profile;

  bool get isValid =>
      id.startsWith('phone-workspace-') &&
      id.length <= 128 &&
      deviceName.isNotEmpty;

  factory PhoneWorkspaceSession.fromMap(Map value) => PhoneWorkspaceSession(
        id: value['id']?.toString() ?? '',
        driver: value['driver']?.toString() ?? '',
        deviceName: value['device_name']?.toString() ?? '',
        profile: PhoneWorkspaceProfile.fromMap(
            value['profile'] is Map ? value['profile'] as Map : const {}),
      );
}

class PhoneWorkspaceSupport {
  const PhoneWorkspaceSupport({
    required this.supported,
    required this.driver,
    required this.driverInstalled,
    required this.requiresDriverInstall,
    required this.customDpiSupported,
    required this.ownedCleanupSupported,
    required this.reason,
    required this.profiles,
    required this.activeSession,
    required this.reconciliation,
  });

  final bool supported;
  final String driver;
  final bool driverInstalled;
  final bool requiresDriverInstall;
  final bool customDpiSupported;
  final bool ownedCleanupSupported;
  final String reason;
  final List<PhoneWorkspaceProfile> profiles;
  final PhoneWorkspaceSession? activeSession;
  final String reconciliation;

  factory PhoneWorkspaceSupport.fromMap(Map value) {
    final active = value['active_session'];
    final parsedActive =
        active is Map ? PhoneWorkspaceSession.fromMap(active) : null;
    return PhoneWorkspaceSupport(
      supported: value['supported'] == true,
      driver: value['driver']?.toString() ?? '',
      driverInstalled: value['driver_installed'] == true,
      requiresDriverInstall: value['requires_driver_install'] == true,
      customDpiSupported: value['custom_dpi_supported'] == true,
      ownedCleanupSupported: value['owned_cleanup_supported'] == true,
      reason: value['reason']?.toString() ?? '',
      profiles: (value['profiles'] as List? ?? const [])
          .whereType<Map>()
          .map(PhoneWorkspaceProfile.fromMap)
          .where((profile) => profile.width > 0 && profile.height > 0)
          .toList(growable: false),
      activeSession: parsedActive?.isValid == true ? parsedActive : null,
      reconciliation: value['reconciliation']?.toString() ?? 'unknown',
    );
  }
}

class HostWindowInfo {
  const HostWindowInfo({
    required this.id,
    required this.title,
    required this.application,
    required this.monitor,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.minimized,
    required this.canFocus,
  });

  final String id;
  final String title;
  final String application;
  final int monitor;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool minimized;
  final bool canFocus;

  bool get isValid =>
      id.startsWith('win-') &&
      id.length <= 96 &&
      title.isNotEmpty &&
      title.length <= 256 &&
      application.isNotEmpty &&
      application.length <= 256 &&
      monitor >= 0 &&
      width > 0 &&
      height > 0;

  factory HostWindowInfo.fromMap(Map value) => HostWindowInfo(
        id: value['id']?.toString() ?? '',
        title: value['title']?.toString() ?? '',
        application: value['application']?.toString() ?? '',
        monitor: (value['monitor'] as num?)?.toInt() ?? -1,
        x: (value['x'] as num?)?.toInt() ?? 0,
        y: (value['y'] as num?)?.toInt() ?? 0,
        width: (value['width'] as num?)?.toInt() ?? 0,
        height: (value['height'] as num?)?.toInt() ?? 0,
        minimized: value['minimized'] == true,
        canFocus: value['can_focus'] == true,
      );
}

class HostWindowSnapshot {
  const HostWindowSnapshot({
    required this.desktopGeneration,
    required this.windows,
  });

  final int desktopGeneration;
  final List<HostWindowInfo> windows;

  bool contains(String id) => windows.any((window) => window.id == id);

  factory HostWindowSnapshot.fromHostMap(Map value) {
    final windows = (value['windows'] as List? ?? const [])
        .whereType<Map>()
        .map(HostWindowInfo.fromMap)
        .where((window) => window.isValid)
        .take(100)
        .toList(growable: false);
    return HostWindowSnapshot(
      desktopGeneration: (value['desktop_generation'] as num?)?.toInt() ?? 0,
      windows: windows,
    );
  }
}

class HostProcessInfo {
  const HostProcessInfo({
    required this.pid,
    this.startTimeSecs = 0,
    this.creationTime100ns = 0,
    required this.name,
    required this.cpuPercent,
    required this.memoryBytes,
    required this.executable,
    required this.canEnd,
  });

  final int pid;
  final int startTimeSecs;
  final int creationTime100ns;
  final String name;
  final double? cpuPercent;
  final int? memoryBytes;
  final String executable;
  final bool canEnd;

  String get identity => creationTime100ns > 0
      ? 'process:$pid:$creationTime100ns'
      : 'process:$pid:$startTimeSecs';

  factory HostProcessInfo.fromMap(Map value) => HostProcessInfo(
        pid: (value['pid'] as num?)?.toInt() ?? 0,
        startTimeSecs: (value['start_time_secs'] as num?)?.toInt() ?? 0,
        creationTime100ns: (value['creation_time_100ns'] as num?)?.toInt() ?? 0,
        name: value['name']?.toString() ?? '',
        cpuPercent: (value['cpu_percent'] as num?)?.toDouble(),
        memoryBytes: (value['memory_bytes'] as num?)?.toInt(),
        executable: value['executable']?.toString() ?? '',
        canEnd: value['can_end'] == true,
      );
}

class HostComponentHealth {
  const HostComponentHealth({
    required this.id,
    required this.label,
    required this.state,
    required this.detail,
    required this.recoverable,
  });

  final String id;
  final String label;
  final String state;
  final String detail;
  final bool recoverable;

  factory HostComponentHealth.fromMap(Map value) => HostComponentHealth(
        id: value['id']?.toString() ?? '',
        label: value['label']?.toString() ?? '',
        state: value['state']?.toString() ?? 'unknown',
        detail: value['detail']?.toString() ?? '',
        recoverable: value['recoverable'] == true,
      );
}

class HostWatchdogInfo {
  const HostWatchdogInfo({
    required this.running,
    required this.lastCheckMs,
    required this.lastRecoveryMs,
    required this.components,
  });

  final bool running;
  final int lastCheckMs;
  final int lastRecoveryMs;
  final List<HostComponentHealth> components;

  factory HostWatchdogInfo.fromMap(Map value) => HostWatchdogInfo(
        running: value['running'] == true,
        lastCheckMs: (value['last_check_ms'] as num?)?.toInt() ?? 0,
        lastRecoveryMs: (value['last_recovery_ms'] as num?)?.toInt() ?? 0,
        components: (value['components'] as List? ?? const [])
            .whereType<Map>()
            .map(HostComponentHealth.fromMap)
            .toList(),
      );
}

class HostSystemSnapshot {
  static const freshFor = Duration(seconds: 15);

  const HostSystemSnapshot({
    this.schema = 1,
    this.sampledAtMs = 0,
    this.source = 'unknown',
    this.receivedMonotonicMs = -1,
    this.requestStartedMonotonicMs = -1,
    required this.cpuPercent,
    required this.cpuName,
    required this.logicalCpus,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.uptimeSecs,
    required this.processes,
    required this.watchdog,
  });

  final int schema;
  final int sampledAtMs;
  final String source;
  final int receivedMonotonicMs;
  final int requestStartedMonotonicMs;
  final double? cpuPercent;
  final String cpuName;
  final int? logicalCpus;
  final int? memoryUsedBytes;
  final int? memoryTotalBytes;
  final int? uptimeSecs;
  final List<HostProcessInfo> processes;
  final HostWatchdogInfo watchdog;

  Duration? ageAt(int nowMonotonicMs) {
    final origin = requestStartedMonotonicMs >= 0
        ? requestStartedMonotonicMs
        : receivedMonotonicMs;
    if (origin < 0 || nowMonotonicMs < origin) {
      return null;
    }
    return Duration(milliseconds: nowMonotonicMs - origin);
  }

  bool isFreshAt(int nowMonotonicMs, {required bool connected}) {
    final age = ageAt(nowMonotonicMs);
    return connected && age != null && age <= freshFor;
  }

  bool containsProcessIdentity(
    int pid,
    int startTimeSecs, {
    int creationTime100ns = 0,
  }) =>
      processes.any(
        (process) =>
            process.pid == pid &&
            process.startTimeSecs == startTimeSecs &&
            (creationTime100ns <= 0 ||
                process.creationTime100ns == creationTime100ns),
      );

  factory HostSystemSnapshot.fromMap(
    Map value, {
    int? receivedMonotonicMs,
    int? requestStartedMonotonicMs,
  }) =>
      HostSystemSnapshot(
        schema: (value['schema'] as num?)?.toInt() ?? 1,
        sampledAtMs: (value['sampled_at_ms'] as num?)?.toInt() ?? 0,
        source: value['source']?.toString() ?? 'unknown',
        receivedMonotonicMs: receivedMonotonicMs ?? hostMonotonicNowMs(),
        requestStartedMonotonicMs: requestStartedMonotonicMs ?? -1,
        cpuPercent: (value['cpu_percent'] as num?)?.toDouble(),
        cpuName: value['cpu_name']?.toString() ?? '',
        logicalCpus: (value['logical_cpus'] as num?)?.toInt(),
        memoryUsedBytes: (value['memory_used_bytes'] as num?)?.toInt(),
        memoryTotalBytes: (value['memory_total_bytes'] as num?)?.toInt(),
        uptimeSecs: (value['uptime_secs'] as num?)?.toInt(),
        processes: (value['processes'] as List? ?? const [])
            .whereType<Map>()
            .map(HostProcessInfo.fromMap)
            .toList(),
        watchdog: HostWatchdogInfo.fromMap(value['watchdog'] is Map
            ? value['watchdog'] as Map
            : const <String, dynamic>{}),
      );
}
