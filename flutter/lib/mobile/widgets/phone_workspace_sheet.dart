import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/emulator_model.dart';
import '../../models/host_management_model.dart';
import '../../models/remote_operation_state.dart';
import 'mirpg_remote_theme.dart';

Future<void> showPhoneWorkspaceSheet(
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
    builder: (_) => _PhoneWorkspaceSheet(
      model: model,
      canControl: canControl,
    ),
  );
}

class _PhoneWorkspaceSheet extends StatefulWidget {
  const _PhoneWorkspaceSheet({
    required this.model,
    required this.canControl,
  });

  final EmulatorModel model;
  final bool canControl;

  @override
  State<_PhoneWorkspaceSheet> createState() => _PhoneWorkspaceSheetState();
}

class _PhoneWorkspaceSheetState extends State<_PhoneWorkspaceSheet> {
  PhoneWorkspaceProfile? _selected;

  @override
  void initState() {
    super.initState();
    final support = widget.model.phoneWorkspaceSupport;
    _selected = support?.activeSession?.profile ??
        (support?.profiles.isNotEmpty == true ? support!.profiles.first : null);
    if (widget.model.phoneWorkspaceCapability == CapabilityStatus.supported &&
        !widget.model.phoneWorkspaceLoading) {
      unawaited(widget.model.refreshPhoneWorkspace());
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.model,
        builder: (context, _) {
          final support = widget.model.phoneWorkspaceSupport;
          if (_selected == null && support?.profiles.isNotEmpty == true) {
            _selected =
                support!.activeSession?.profile ?? support.profiles.first;
          }
          final active = support?.activeSession;
          final capability = widget.model.phoneWorkspaceCapability;
          final loading = widget.model.phoneWorkspaceLoading;
          final canChange = widget.canControl &&
              capability == CapabilityStatus.supported &&
              support?.supported == true &&
              !loading;

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
                  Text('Phone Workspace',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    'Create one phone-shaped virtual monitor for the remote session. Physical monitor resolution, rotation and layout stay unchanged.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: MirpgRemoteTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 20),
                  if (loading) const LinearProgressIndicator(),
                  if (widget.model.phoneWorkspaceError.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _Notice(
                      icon: Icons.error_outline,
                      text: widget.model.phoneWorkspaceError,
                      error: true,
                    ),
                  ],
                  if (widget.model.phoneWorkspaceMessage.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _Notice(
                      icon: Icons.info_outline,
                      text: widget.model.phoneWorkspaceMessage,
                    ),
                  ],
                  if (capability == CapabilityStatus.unsupported)
                    const _Notice(
                      icon: Icons.desktop_access_disabled_outlined,
                      text:
                          'This PC build does not advertise Phone Workspace support.',
                    )
                  else if (capability == CapabilityStatus.unknown)
                    const _Notice(
                      icon: Icons.sync_problem_outlined,
                      text:
                          'Reconnect to negotiate Phone Workspace support with the PC.',
                    )
                  else if (support == null && !loading)
                    _Recheck(model: widget.model)
                  else if (support != null) ...[
                    _StatusCard(support: support),
                    if (active != null) ...[
                      const SizedBox(height: 16),
                      Text('Active display',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.phone_android),
                          title: Text(active.profile.label),
                          subtitle: Text(
                            'Owned by this app • ${support.reconciliation.replaceAll('_', ' ')}',
                          ),
                        ),
                      ),
                    ] else if (support.supported) ...[
                      const SizedBox(height: 20),
                      Text('Display profile',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      ...support.profiles.map(
                        (profile) => RadioListTile<PhoneWorkspaceProfile>(
                          value: profile,
                          groupValue: _selected,
                          onChanged: loading
                              ? null
                              : (value) => setState(() => _selected = value),
                          title: Text(profile.label),
                          subtitle: Text(
                            profile.dpi == 0
                                ? '60 Hz • Windows-managed scaling'
                                : '60 Hz • ${profile.dpi} DPI',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const _Notice(
                        icon: Icons.info_outline,
                        text:
                            'Activation adds one virtual display. It does not resize or rotate your existing monitors.',
                      ),
                    ],
                    if (!support.supported && support.reason.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _Notice(
                        icon: support.requiresDriverInstall
                            ? Icons.download_for_offline_outlined
                            : Icons.warning_amber_rounded,
                        text: support.reason,
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: loading
                                ? null
                                : widget.model.refreshPhoneWorkspace,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Recheck'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: active != null
                              ? FilledButton.icon(
                                  onPressed: canChange
                                      ? widget.model.endPhoneWorkspace
                                      : null,
                                  icon: const Icon(Icons.stop_circle_outlined),
                                  label: const Text('End workspace'),
                                )
                              : FilledButton.icon(
                                  onPressed: canChange && _selected != null
                                      ? () => widget.model
                                          .beginPhoneWorkspace(_selected!)
                                      : null,
                                  icon: const Icon(Icons.add_to_queue_outlined),
                                  label: const Text('Activate'),
                                ),
                        ),
                      ],
                    ),
                    if (!widget.canControl && support.supported) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Control permission is required to add or remove the virtual display.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          );
        },
      );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.support});

  final PhoneWorkspaceSupport support;

  @override
  Widget build(BuildContext context) {
    final available = support.supported;
    return Card(
      child: ListTile(
        leading: Icon(
          available ? Icons.phone_android : Icons.phone_android_outlined,
          color: available
              ? MirpgRemoteTheme.accent
              : MirpgRemoteTheme.textSecondary,
        ),
        title: Text(available ? 'Ready' : 'Unavailable'),
        subtitle: Text(
          '${support.driver.isEmpty ? 'Virtual display driver' : support.driver} • '
          '${support.driverInstalled ? 'Installed' : 'Not installed'}',
        ),
      ),
    );
  }
}

class _Recheck extends StatelessWidget {
  const _Recheck({required this.model});

  final EmulatorModel model;

  @override
  Widget build(BuildContext context) => Center(
        child: FilledButton.icon(
          onPressed: model.refreshPhoneWorkspace,
          icon: const Icon(Icons.refresh),
          label: const Text('Check support'),
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.error = false,
  });

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: error
              ? MirpgRemoteTheme.error.withOpacity(0.08)
              : MirpgRemoteTheme.surface,
          borderRadius: BorderRadius.circular(MirpgRemoteTheme.controlRadius),
          border: Border.all(
            color: error ? MirpgRemoteTheme.error : MirpgRemoteTheme.outline,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 20,
              color: error
                  ? MirpgRemoteTheme.error
                  : MirpgRemoteTheme.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
