class HostProcessInfo {
  const HostProcessInfo({
    required this.pid,
    required this.name,
    required this.cpuPercent,
    required this.memoryBytes,
    required this.executable,
    required this.canEnd,
  });

  final int pid;
  final String name;
  final double cpuPercent;
  final int memoryBytes;
  final String executable;
  final bool canEnd;

  factory HostProcessInfo.fromMap(Map value) => HostProcessInfo(
        pid: (value['pid'] as num?)?.toInt() ?? 0,
        name: value['name']?.toString() ?? '',
        cpuPercent: (value['cpu_percent'] as num?)?.toDouble() ?? 0,
        memoryBytes: (value['memory_bytes'] as num?)?.toInt() ?? 0,
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
  const HostSystemSnapshot({
    required this.cpuPercent,
    required this.cpuName,
    required this.logicalCpus,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.uptimeSecs,
    required this.processes,
    required this.watchdog,
  });

  final double cpuPercent;
  final String cpuName;
  final int logicalCpus;
  final int memoryUsedBytes;
  final int memoryTotalBytes;
  final int uptimeSecs;
  final List<HostProcessInfo> processes;
  final HostWatchdogInfo watchdog;

  factory HostSystemSnapshot.fromMap(Map value) => HostSystemSnapshot(
        cpuPercent: (value['cpu_percent'] as num?)?.toDouble() ?? 0,
        cpuName: value['cpu_name']?.toString() ?? '',
        logicalCpus: (value['logical_cpus'] as num?)?.toInt() ?? 0,
        memoryUsedBytes: (value['memory_used_bytes'] as num?)?.toInt() ?? 0,
        memoryTotalBytes: (value['memory_total_bytes'] as num?)?.toInt() ?? 0,
        uptimeSecs: (value['uptime_secs'] as num?)?.toInt() ?? 0,
        processes: (value['processes'] as List? ?? const [])
            .whereType<Map>()
            .map(HostProcessInfo.fromMap)
            .toList(),
        watchdog: HostWatchdogInfo.fromMap(value['watchdog'] is Map
            ? value['watchdog'] as Map
            : const <String, dynamic>{}),
      );
}
