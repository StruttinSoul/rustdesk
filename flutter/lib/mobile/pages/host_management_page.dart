import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/emulator_model.dart';
import '../../models/host_management_model.dart';

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
    _refreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (widget.active && !widget.model.hostLoading) {
        unawaited(widget.model.refreshHost());
      }
    });
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
            onRefresh: widget.model.refreshHost,
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
                      text: widget.model.hostMessage,
                      icon: Icons.check_circle_outline),
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
                  _watchdog(snapshot.watchdog),
                  const SizedBox(height: 16),
                  _processes(snapshot.processes),
                ],
              ],
            ),
          );
        },
      );

  Widget _systemSummary(HostSystemSnapshot snapshot) {
    final memory = snapshot.memoryTotalBytes <= 0
        ? 0.0
        : snapshot.memoryUsedBytes / snapshot.memoryTotalBytes * 100;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('System', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 10, children: [
        _MetricCard(
            icon: Icons.memory,
            label: 'CPU',
            value: '${snapshot.cpuPercent.toStringAsFixed(0)}%',
            detail:
                '${snapshot.logicalCpus} logical cores${snapshot.cpuName.isEmpty ? '' : ' • ${snapshot.cpuName}'}'),
        _MetricCard(
            icon: Icons.storage_outlined,
            label: 'Memory',
            value: '${memory.toStringAsFixed(0)}%',
            detail:
                '${_bytes(snapshot.memoryUsedBytes)} / ${_bytes(snapshot.memoryTotalBytes)}'),
        _MetricCard(
            icon: Icons.schedule,
            label: 'Uptime',
            value: _uptime(snapshot.uptimeSecs),
            detail: 'Windows uptime'),
        _MetricCard(
            icon: snapshot.watchdog.running
                ? Icons.health_and_safety_outlined
                : Icons.warning_amber_rounded,
            label: 'Watchdog',
            value: snapshot.watchdog.running ? 'Active' : 'Stopped',
            detail: '20 second health checks'),
      ]),
    ]);
  }

  Widget _watchdog(HostWatchdogInfo watchdog) => Card(
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
              Text(watchdog.running ? 'Active' : 'Stopped'),
            ]),
            const SizedBox(height: 8),
            for (final component in watchdog.components)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(_healthIcon(component.state),
                    color: _healthColor(context, component.state)),
                title: Text(component.label),
                subtitle: Text(component.detail),
                trailing: component.recoverable && widget.canControl
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
                  'PID ${process.pid} • ${process.cpuPercent.toStringAsFixed(1)}% CPU • ${_bytes(process.memoryBytes)}'),
              trailing: process.canEnd && widget.canControl
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
    if (confirmed) await widget.model.endProcess(process.pid);
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
      'healthy' => Colors.green,
      'unhealthy' => Theme.of(context).colorScheme.error,
      _ => null,
    };

String _bytes(int bytes) {
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

String _uptime(int seconds) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}
