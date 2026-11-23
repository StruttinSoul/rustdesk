import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/emulator_model.dart';
import '../../models/host_management_model.dart';
import '../../models/remote_operation_state.dart';
import 'mirpg_remote_theme.dart';

Future<void> showGatewayManagementPanel(
  BuildContext context, {
  required EmulatorModel model,
  required bool canControl,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: MirpgRemoteTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(MirpgRemoteTheme.sheetRadius),
      ),
    ),
    builder: (_) => _GatewayManagementPanel(
      model: model,
      canControl: canControl,
    ),
  );
}

class _GatewayManagementPanel extends StatefulWidget {
  const _GatewayManagementPanel({
    required this.model,
    required this.canControl,
  });

  final EmulatorModel model;
  final bool canControl;

  @override
  State<_GatewayManagementPanel> createState() =>
      _GatewayManagementPanelState();
}

class _GatewayManagementPanelState extends State<_GatewayManagementPanel> {
  Timer? _freshnessTimer;

  @override
  void initState() {
    super.initState();
    _freshnessTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.model.gatewayStatusCapability != CapabilityStatus.supported ||
          widget.model.gatewayStatusLoading ||
          widget.model.gatewayStatusFresh) {
        return;
      }
      unawaited(widget.model.refreshGatewayStatus());
    });
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.model,
        builder: (context, _) {
          final status = widget.model.gatewayStatus;
          final capability = widget.model.gatewayStatusCapability;
          final fresh = widget.model.gatewayStatusFresh;
          final age = status?.ageAt(hostMonotonicNowMs());

          return Padding(
            padding: EdgeInsets.fromLTRB(
              MirpgRemoteTheme.pageMargin,
              12,
              MirpgRemoteTheme.pageMargin,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: MirpgRemoteTheme.outline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Icon(Icons.hub_outlined,
                          color: MirpgRemoteTheme.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Marquee Gateway',
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                      if (status != null)
                        MirpgStatusChip(
                          label: fresh ? 'Live' : 'Stale',
                          icon: fresh
                              ? Icons.check_circle_outline
                              : Icons.schedule_outlined,
                          tone: fresh
                              ? MirpgStatusTone.good
                              : MirpgStatusTone.warning,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Status and management for the Gateway running on this PC.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: MirpgRemoteTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 18),
                  if (widget.model.gatewayStatusLoading)
                    const LinearProgressIndicator(),
                  if (widget.model.gatewayError.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _GatewayNotice(
                      text: widget.model.gatewayError,
                      icon: Icons.error_outline,
                      error: true,
                    ),
                  ],
                  if (widget.model.gatewayMessage.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _GatewayNotice(
                      text: widget.model.gatewayMessage,
                      icon: Icons.check_circle_outline,
                    ),
                  ],
                  if (capability == CapabilityStatus.unknown)
                    const _GatewayNotice(
                      text:
                          'Reconnect to negotiate Gateway support with this PC.',
                      icon: Icons.sync_problem_outlined,
                    )
                  else if (capability == CapabilityStatus.unsupported)
                    const _GatewayNotice(
                      text:
                          'This PC build does not advertise Gateway management support.',
                      icon: Icons.desktop_access_disabled_outlined,
                    )
                  else if (status == null && !widget.model.gatewayStatusLoading)
                    _GatewayNotice(
                      text: 'Gateway status has not been measured yet.',
                      icon: Icons.info_outline,
                      action: TextButton(
                        onPressed: widget.model.refreshGatewayStatus,
                        child: const Text('Check now'),
                      ),
                    )
                  else if (status != null) ...[
                    _statusCard(status, fresh, age),
                    const SizedBox(height: 20),
                    const MirpgSectionHeader(
                      title: 'Management',
                      subtitle:
                          'Actions appear only when the Windows Gateway supervisor exposes a verified secure control path.',
                    ),
                    const SizedBox(height: 10),
                    _setupCard(status, fresh),
                    const SizedBox(height: 10),
                    _providerCard(status, fresh),
                    const SizedBox(height: 10),
                    _restartCard(status, fresh),
                    if (!widget.canControl) ...[
                      const SizedBox(height: 8),
                      Text(
                        'This remote session is view-only. Gateway changes will require control permission when management actions become available.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: capability == CapabilityStatus.supported &&
                              !widget.model.gatewayStatusLoading
                          ? widget.model.refreshGatewayStatus
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Recheck Gateway'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );

  Widget _statusCard(GatewayStatus status, bool fresh, Duration? age) {
    final processLabel = switch (status.processState) {
      'running' => 'Running',
      'supervisor_running' => 'Starting / child unavailable',
      'orphaned_child' => 'Child running without verified supervisor',
      'stale_record' => 'Stopped or stale process record',
      _ => 'Unknown',
    };
    final reachabilityLabel = switch (status.reachability) {
      'reachable' => 'Reachable',
      'unreachable' => 'Unreachable',
      _ => 'Unknown',
    };
    final healthy = status.running &&
        status.reachable &&
        fresh &&
        status.healthMeasured &&
        status.healthReady;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  healthy ? Icons.check_circle_outline : Icons.info_outline,
                  color: healthy
                      ? MirpgRemoteTheme.accent
                      : MirpgRemoteTheme.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status.installed ? processLabel : 'Not installed',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(fresh ? _gatewayAge(age) : 'Stale'),
              ],
            ),
            const SizedBox(height: 14),
            _fact('Connection', reachabilityLabel),
            _fact(
                'Version', status.version.isEmpty ? 'Unknown' : status.version),
            _fact('API',
                status.apiVersion.isEmpty ? 'Unknown' : status.apiVersion),
            _fact(
              'Local trust',
              status.trustedPinMatched == true
                  ? 'Verified'
                  : status.protectedHealthAvailable
                      ? 'Not verified'
                      : 'Unknown',
            ),
            if (status.gatewayHealth.isNotEmpty)
              _fact('Health', status.gatewayHealth),
            if (status.gatewayHealth.isEmpty) _fact('Health', 'Not measured'),
            _fact(
              'Identity',
              status.identityReady == true
                  ? 'Ready'
                  : status.identityReady == false
                      ? 'Not ready'
                      : 'Unknown',
            ),
            _fact('Silo',
                status.siloState.isEmpty ? 'Unknown' : status.siloState),
            _fact(
              'Sessions',
              status.activeSessions == null
                  ? 'Unknown'
                  : status.maxSessions == null
                      ? '${status.activeSessions} active'
                      : '${status.activeSessions} / ${status.maxSessions}',
            ),
            if (status.detail.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                status.detail,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: MirpgRemoteTheme.textSecondary,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fact(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: MirpgRemoteTheme.textSecondary,
                      )),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  bool _canUse(
    CapabilityStatus capability,
    bool hostAllows,
    bool fresh,
  ) =>
      widget.canControl &&
      fresh &&
      !widget.model.gatewayMutationLoading &&
      !widget.model.gatewayNeedsReconcile &&
      capability == CapabilityStatus.supported &&
      hostAllows;

  Widget _setupCard(GatewayStatus status, bool fresh) {
    final enabled = _canUse(
      widget.model.gatewaySetupCapability,
      status.setupControlAvailable,
      fresh,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.open_in_browser_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Setup',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Open the existing Gateway setup page on this Windows PC. Setup stays in the PC browser.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: enabled ? widget.model.openGatewaySetup : null,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open setup on Windows'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _providerCard(GatewayStatus status, bool fresh) {
    final providerEnabled = status.imdbEnabled == true;
    final controlsAvailable = _canUse(
      widget.model.gatewayImdbCapability,
      status.providerControlAvailable,
      fresh,
    );
    final refreshEnabled =
        controlsAvailable && providerEnabled && status.imdbRefreshing != true;
    final state = status.imdbState.isEmpty ? 'Unknown' : status.imdbState;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dataset_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('IMDb metadata',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                MirpgStatusChip(
                  label: status.imdbEnabled == null
                      ? 'Unknown'
                      : providerEnabled
                          ? 'Enabled'
                          : 'Disabled',
                  icon: providerEnabled
                      ? Icons.check_circle_outline
                      : Icons.pause_circle_outline,
                  tone: providerEnabled
                      ? MirpgStatusTone.good
                      : MirpgStatusTone.neutral,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _fact(
                'State', status.imdbRefreshing == true ? 'Refreshing' : state),
            _fact(
              'Updated',
              status.imdbUpdatedAt.isEmpty ? 'Unknown' : status.imdbUpdatedAt,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: controlsAvailable && status.imdbEnabled != null
                        ? () =>
                            widget.model.setGatewayImdbEnabled(!providerEnabled)
                        : null,
                    child:
                        Text(providerEnabled ? 'Disable IMDb' : 'Enable IMDb'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed:
                        refreshEnabled ? widget.model.refreshGatewayImdb : null,
                    icon: status.imdbRefreshing == true
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: const Text('Refresh IMDb'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _restartCard(GatewayStatus status, bool fresh) {
    final enabled = _canUse(
      widget.model.gatewayRestartCapability,
      status.restartControlAvailable && status.processIdentity.isNotEmpty,
      fresh,
    );
    final impact = status.activeSessions == null
        ? 'Active session impact is unknown.'
        : status.activeSessions == 0
            ? 'No active Gateway sessions were measured.'
            : '${status.activeSessions} active Gateway session${status.activeSessions == 1 ? '' : 's'} may be interrupted.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.restart_alt),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Restart Gateway',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(impact, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: enabled ? () => _confirmRestart(status) : null,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Restart Gateway'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRestart(GatewayStatus captured) async {
    final impact = captured.activeSessions == null
        ? 'The active-session count is unavailable. Restarting may interrupt active Gateway sessions.'
        : captured.activeSessions == 0
            ? 'No active Gateway sessions were measured.'
            : '${captured.activeSessions} active Gateway session${captured.activeSessions == 1 ? '' : 's'} may be interrupted.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart Marquee Gateway?'),
        content: Text(
          '$impact\n\nThis restarts only the verified owned Gateway process. Status will be rechecked after the supervisor accepts the request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
                captured.activeSessions == null ? 'Restart anyway' : 'Restart'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.model.restartGateway(confirmedStatus: captured);
    }
  }
}

class _GatewayNotice extends StatelessWidget {
  const _GatewayNotice({
    required this.text,
    required this.icon,
    this.error = false,
    this.action,
  });

  final String text;
  final IconData icon;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(icon,
              color: error ? Theme.of(context).colorScheme.error : null),
          title: Text(text),
          trailing: action,
        ),
      );
}

String _gatewayAge(Duration? age) {
  if (age == null) return 'Unknown age';
  if (age.inSeconds < 2) return 'Just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s ago';
  return '${age.inMinutes}m ago';
}
