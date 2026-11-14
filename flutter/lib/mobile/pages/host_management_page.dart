import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/emulator_model.dart';
import '../../models/host_management_model.dart';
import '../../models/remote_operation_state.dart';
import '../widgets/mirpg_remote_theme.dart';
import '../widgets/gateway_management_panel.dart';
import '../widgets/phone_workspace_sheet.dart';

class HostManagementPage extends StatefulWidget {
  const HostManagementPage({
    super.key,
    required this.model,
    required this.active,
    required this.canControl,
  });

  final EmulatorModel model;
  final bool active;
  final bool canControl;

  @override
  State<HostManagementPage> createState() => _HostManagementPageState();
}

class _HostManagementPageState extends State<HostManagementPage> {
  final _search = TextEditingController();
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _syncRefresh();
  }

  @override
  void didUpdateWidget(covariant HostManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncRefresh();
  }

  void _syncRefresh() {
    _refreshTimer?.cancel();
    if (!widget.active) return;
    if (!widget.model.hostLoading) unawaited(widget.model.refreshHost());
    if (widget.model.phoneWorkspaceCapability == CapabilityStatus.supported &&
        !widget.model.phoneWorkspaceLoading) {
      unawaited(widget.model.refreshPhoneWorkspace());
    }
    if (widget.model.gatewayStatusCapability == CapabilityStatus.supported &&
        !widget.model.gatewayStatusLoading) {
      unawaited(widget.model.refreshGatewayStatus());
    }
    _refreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) setState(() {});
      if (widget.active && !widget.model.hostLoading) {
        unawaited(widget.model.refreshHost());
      }
      if (widget.active &&
          widget.model.phoneWorkspaceCapability == CapabilityStatus.supported &&
          !widget.model.phoneWorkspaceLoading) {
        unawaited(widget.model.refreshPhoneWorkspace());
      }
      if (widget.active &&
          widget.model.gatewayStatusCapability == CapabilityStatus.supported &&
          !widget.model.gatewayStatusLoading &&
          !widget.model.gatewayStatusFresh) {
        unawaited(widget.model.refreshGatewayStatus());
      }
    });
  }

  Future<void> _refreshAll() async {
    final requests = <Future<void>>[widget.model.refreshHost()];
    if (widget.model.gatewayStatusCapability == CapabilityStatus.supported) {
      requests.add(widget.model.refreshGatewayStatus());
    }
    if (widget.model.phoneWorkspaceCapability == CapabilityStatus.supported) {
      requests.add(widget.model.refreshPhoneWorkspace());
    }
    await Future.wait(requests);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.model,
        builder: (context, _) {
          final snapshot = widget.model.hostSnapshot;
          return RefreshIndicator(
            onRefresh: _refreshAll,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (widget.model.hostLoading) const LinearProgressIndicator(),
                if (widget.model.hostError.isNotEmpty)
                  _Notice(
                      text: widget.model.hostError,
                      icon: Icons.error_outline,
                      error: true),
                if (widget.model.hostMessage.isNotEmpty)
                  _Notice(
                      text: widget.model.hostMessage, icon: Icons.info_outline),
                _phoneWorkspaceCard(),
                if (widget.model.gatewayStatusCapability ==
                    CapabilityStatus.supported) ...[
                  const SizedBox(height: 16),
                  const MirpgSectionHeader(
                    title: 'Services',
                    subtitle: 'Services running on this Windows PC',
                  ),
                  const SizedBox(height: 10),
                  _gatewayCard(),
                ],
                const SizedBox(height: 16),
                if (snapshot != null && !widget.model.hostSnapshotFresh)
                  const _Notice(
                    text:
                        'System data is stale. Refresh before using process controls.',
                    icon: Icons.schedule_outlined,
                  ),
                if (snapshot == null && !widget.model.hostLoading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: FilledButton.icon(
                        onPressed: widget.model.refreshHost,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Load system status'),
                      ),
                    ),
                  ),
                if (snapshot != null) ...[
                  _systemSummary(snapshot),
                  const SizedBox(height: 16),
                  _watchdog(snapshot.watchdog, widget.model.hostSnapshotFresh),
                  const SizedBox(height: 16),
                  _processes(snapshot.processes),
                ],
              ],
            ),
          );
        },
      );

  Widget _gatewayCard() {
    final status = widget.model.gatewayStatus;
    final loading = widget.model.gatewayStatusLoading;
    final fresh = widget.model.gatewayStatusFresh;
    final title = status == null
        ? 'Marquee Gateway'
        : !status.installed
            ? 'Gateway not found'
            : status.running &&
                    status.reachable &&
                    fresh &&
                    status.healthMeasured &&
                    status.healthReady
                ? 'Gateway healthy'
                : status.running
                    ? 'Gateway running'
                    : 'Gateway needs attention';
    final subtitle = widget.model.gatewayError.isNotEmpty
        ? widget.model.gatewayError
        : status == null
            ? loading
                ? 'Checking Gateway…'
                : 'Gateway status has not been measured yet'
            : '${status.version.isEmpty ? 'Version unknown' : status.version} • '
                '${fresh ? 'Live' : 'Stale'} • '
                '${status.reachability == 'reachable' ? 'Reachable' : status.reachability == 'unreachable' ? 'Unreachable' : 'Reachability unknown'}';
    final good = status != null &&
        status.installed &&
        status.running &&
        status.reachable &&
        status.healthMeasured &&
        status.healthReady &&
        fresh;
    return Card(
      child: ListTile(
        minVerticalPadding: 14,
        leading: Icon(
          Icons.hub_outlined,
          color:
              good ? MirpgRemoteTheme.accent : MirpgRemoteTheme.textSecondary,
        ),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis),
        trailing: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right),
        onTap: () => showGatewayManagementPanel(
          context,
          model: widget.model,
          canControl: widget.canControl,
        ),
      ),
    );
  }

  Widget _phoneWorkspaceCard() {
    final capability = widget.model.phoneWorkspaceCapability;
    final support = widget.model.phoneWorkspaceSupport;
    final active = support?.activeSession;
    final loading = widget.model.phoneWorkspaceLoading;
    final title = active != null
        ? 'Phone Workspace active'
        : support?.supported == true
            ? 'Phone Workspace ready'
            : capability == CapabilityStatus.unsupported
                ? 'Phone Workspace unavailable'
                : 'Phone Workspace';
    final subtitle = active != null
        ? active.profile.label
        : support?.reason.isNotEmpty == true
            ? support!.reason
            : loading
                ? 'Checking virtual display support…'
                : 'Phone-shaped remote desktop without changing physical monitors';
    return Card(
      child: ListTile(
        minVerticalPadding: 14,
        leading: Icon(
          active != null ? Icons.phone_android : Icons.add_to_queue_outlined,
          color: active != null || support?.supported == true
              ? MirpgRemoteTheme.accent
              : MirpgRemoteTheme.textSecondary,
        ),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis),
        trailing: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right),
        onTap: capability == CapabilityStatus.unsupported
            ? null
            : () => showPhoneWorkspaceSheet(
                  context,
                  model: widget.model,
                  canControl: widget.canControl,
                ),
      ),
    );
  }

  Widget _systemSummary(HostSystemSnapshot snapshot) {
    final memoryUsed = snapshot.memoryUsedBytes;
    final memoryTotal = snapshot.memoryTotalBytes;
    final memory = memoryUsed != null && memoryTotal != null && memoryTotal > 0
        ? memoryUsed / memoryTotal * 100
        : null;
    final now = hostMonotonicNowMs();
    final age = snapshot.ageAt(now);
    final fresh =
        snapshot.isFreshAt(now, connected: widget.model.hostConnectionCurrent);
    final source = snapshot.source == 'windows_sysinfo'
        ? 'Windows sampler'
        : snapshot.source;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      MirpgSectionHeader(
        title: 'System',
        subtitle:
            '${fresh ? 'Live' : 'Stale'} • Last updated ${_age(age)}${source.isEmpty || source == 'unknown' ? '' : ' • $source'}',
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        _MetricCard(
            icon: Icons.memory,
            label: 'CPU',
            value: snapshot.cpuPercent == null
                ? 'Unavailable'
                : '${snapshot.cpuPercent!.toStringAsFixed(0)}%',
            detail: snapshot.logicalCpus == null
                ? 'Whole PC'
                : 'Whole PC • ${snapshot.logicalCpus} logical cores${snapshot.cpuName.isEmpty ? '' : ' • ${snapshot.cpuName}'}'),
        _MetricCard(
            icon: Icons.storage_outlined,
            label: 'Memory',
            value: memory == null
                ? 'Unavailable'
                : '${memory.toStringAsFixed(0)}%',
            detail: memory == null
                ? 'Measurement unavailable'
                : '${_bytes(memoryUsed)} / ${_bytes(memoryTotal)}'),
        _MetricCard(
            icon: Icons.schedule,
            label: 'Uptime',
            value: snapshot.uptimeSecs == null
                ? 'Unavailable'
                : _uptime(snapshot.uptimeSecs!),
            detail: 'Windows uptime'),
        _MetricCard(
            icon: snapshot.watchdog.running
                ? Icons.health_and_safety_outlined
                : Icons.warning_amber_rounded,
            label: 'Watchdog',
            value: fresh
                ? (snapshot.watchdog.running ? 'Active' : 'Stopped')
                : 'Stale',
            detail: fresh
                ? '20 second health checks'
                : 'Refresh to verify watchdog state'),
      ]),
    ]);
  }

  Widget _watchdog(HostWatchdogInfo watchdog, bool fresh) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.health_and_safety_outlined),
              const SizedBox(width: 10),
              Expanded(
                  child: Text('Recovery watchdog',
                      style: Theme.of(context).textTheme.titleMedium)),
              Text(fresh ? (watchdog.running ? 'Active' : 'Stopped') : 'Stale'),
            ]),
            const SizedBox(height: 8),
            for (final component in watchdog.components)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(_healthIcon(component.state),
                    color: _healthColor(context, component.state)),
                title: Text(component.label),
                subtitle: Text(component.detail),
                trailing: component.recoverable &&
                        fresh &&
                        widget.canControl &&
                        widget.model.hostRecoveryCapability ==
                            CapabilityStatus.supported
                    ? IconButton(
                        tooltip: 'Recover ${component.label}',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: widget.model.hostLoading
                            ? null
                            : () => unawaited(
                                widget.model.recoverComponent(component.id)),
                      )
                    : null,
              ),
          ]),
        ),
      );

  Widget _processes(List<HostProcessInfo> processes) {
    final snapshot = widget.model.hostSnapshot;
    final fresh = widget.model.hostSnapshotFresh;
    final query = _search.text.trim().toLowerCase();
    final visible = processes
        .where((process) =>
            query.isEmpty ||
            process.name.toLowerCase().contains(query) ||
            process.pid.toString().contains(query) ||
            process.executable.toLowerCase().contains(query))
        .take(60)
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Processes', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search process, PID, or path',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          for (final process in visible)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                  process.name.isEmpty ? 'PID ${process.pid}' : process.name),
              subtitle: Text(
                  'PID ${process.pid} • ${_processCpu(process, snapshot)} • ${_bytes(process.memoryBytes)}'),
              trailing: process.canEnd &&
                      process.startTimeSecs > 0 &&
                      process.creationTime100ns > 0 &&
                      snapshot?.schema != null &&
                      snapshot!.schema >= 3 &&
                      fresh &&
                      widget.canControl &&
                      widget.model.hostProcessEndCapability ==
                          CapabilityStatus.supported &&
                      widget.model.hostProcessIdentityCapability ==
                          CapabilityStatus.supported
                  ? IconButton(
                      tooltip: 'End task',
                      icon: const Icon(Icons.stop_circle_outlined),
                      onPressed: widget.model.hostLoading
                          ? null
                          : () => _confirmEnd(process),
                    )
                  : null,
            ),
          if (visible.isEmpty)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No matching processes'))),
        ]),
      ),
    );
  }

  Future<void> _confirmEnd(HostProcessInfo process) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('End task?'),
            content: Text(
                'End ${process.name} (PID ${process.pid}) on the remote PC? Unsaved work in that app may be lost.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('End task')),
            ],
          ),
        ) ??
        false;
    if (confirmed &&
        mounted &&
        widget.canControl &&
        widget.model.hostSnapshotFresh) {
      await widget.model.endProcess(process.pid,
          startTimeSecs: process.startTimeSecs,
          creationTime100ns: process.creationTime100ns);
    }
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.icon, this.error = false});
  final String text;
  final IconData icon;
  final bool error;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(icon,
              color: error ? Theme.of(context).colorScheme.error : null),
          title: Text(text),
        ),
      );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(
      {required this.icon,
      required this.label,
      required this.value,
      required this.detail});
  final IconData icon;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 190,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(label)
              ]),
              const SizedBox(height: 10),
              Text(value, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );
}

IconData _healthIcon(String state) => switch (state) {
      'healthy' => Icons.check_circle_outline,
      'idle' => Icons.pause_circle_outline,
      'unavailable' => Icons.remove_circle_outline,
      _ => Icons.error_outline,
    };

Color? _healthColor(BuildContext context, String state) => switch (state) {
      'healthy' => MirpgRemoteTheme.accent,
      'unhealthy' => Theme.of(context).colorScheme.error,
      _ => null,
    };

String _bytes(int? bytes) {
  if (bytes == null) return 'Unavailable';
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit < 2 ? 0 : 1)} ${units[unit]}';
}

String _age(Duration? age) {
  if (age == null) return 'unknown';
  if (age.inSeconds < 2) return 'just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s ago';
  return '${age.inMinutes}m ago';
}

String _processCpu(HostProcessInfo process, HostSystemSnapshot? snapshot) {
  final value = process.cpuPercent;
  if (value == null) return 'CPU unavailable';
  if ((snapshot?.schema ?? 1) >= 2) {
    return '${value.toStringAsFixed(1)}% of whole PC';
  }
  return '${value.toStringAsFixed(1)}% CPU (legacy scale)';
}

String _uptime(int seconds) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}
