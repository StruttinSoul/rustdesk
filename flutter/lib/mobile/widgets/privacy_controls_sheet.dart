import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/shared_state.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'mirpg_remote_theme.dart';

Future<void> showPrivacyControlsSheet(
  BuildContext context, {
  required FFI ffi,
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
    builder: (_) => _PrivacyControlsSheet(ffi: ffi),
  );
}

class _PrivacyControlsSheet extends StatefulWidget {
  const _PrivacyControlsSheet({required this.ffi});

  final FFI ffi;

  @override
  State<_PrivacyControlsSheet> createState() => _PrivacyControlsSheetState();
}

class _PrivacyControlsSheetState extends State<_PrivacyControlsSheet> {
  Timer? _inputTimer;
  Timer? _privacyTimer;
  Worker? _privacyWorker;
  bool? _pendingInput;
  bool? _pendingPrivacy;
  bool _inputOutcomeUnknown = false;
  bool _privacyOutcomeUnknown = false;
  bool _sessionLockRequested = false;
  late bool _lockOnDisconnectRequested;

  FfiModel get _ffiModel => widget.ffi.ffiModel;

  @override
  void initState() {
    super.initState();
    _lockOnDisconnectRequested = bind.sessionGetToggleOptionSync(
      sessionId: widget.ffi.sessionId,
      arg: 'lock-after-session-end',
    );
    _ffiModel.addListener(_onFfiChanged);
    _privacyWorker = ever<String>(
      PrivacyModeState.find(widget.ffi.id),
      (_) => _onPrivacyChanged(),
    );
  }

  @override
  void dispose() {
    _inputTimer?.cancel();
    _privacyTimer?.cancel();
    _privacyWorker?.dispose();
    _ffiModel.removeListener(_onFfiChanged);
    super.dispose();
  }

  void _onFfiChanged() {
    final desired = _pendingInput;
    if (desired != null && _ffiModel.inputBlocked == desired) {
      _inputTimer?.cancel();
      _pendingInput = null;
      _inputOutcomeUnknown = false;
    }
    if (mounted) setState(() {});
  }

  void _onPrivacyChanged() {
    final desired = _pendingPrivacy;
    final active = PrivacyModeState.find(widget.ffi.id).value.isNotEmpty;
    if (desired != null && active == desired) {
      _privacyTimer?.cancel();
      _pendingPrivacy = null;
      _privacyOutcomeUnknown = false;
    }
    if (mounted) setState(() {});
  }

  bool get _canControl => _ffiModel.keyboard && !_ffiModel.viewOnly;

  bool get _privacySupported {
    final implementations = _ffiModel
        .pi.platformAdditions[kPlatformAdditionsSupportedPrivacyModeImpl];
    return implementations == null ||
        (implementations is List && implementations.isNotEmpty);
  }

  String _preferredPrivacyImpl() {
    final current = PrivacyModeState.find(widget.ffi.id).value;
    if (current.isNotEmpty) return current;
    final implementations = _ffiModel
        .pi.platformAdditions[kPlatformAdditionsSupportedPrivacyModeImpl];
    if (implementations is List && implementations.isNotEmpty) {
      final first = implementations.first;
      if (first is List && first.isNotEmpty && first.first is String) {
        return first.first as String;
      }
    }
    return kPrivacyModeImplMag;
  }

  Future<void> _setInputState(bool desired) async {
    if (_pendingInput != null || !_canControl) return;
    setState(() {
      _pendingInput = desired;
      _inputOutcomeUnknown = false;
    });
    _inputTimer?.cancel();
    _inputTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _pendingInput != desired) return;
      setState(() {
        _pendingInput = null;
        _inputOutcomeUnknown = true;
      });
    });
    try {
      await bind.sessionToggleOption(
        sessionId: widget.ffi.sessionId,
        value: desired ? 'block-input' : 'unblock-input',
      );
    } catch (_) {
      _inputTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _pendingInput = null;
        _inputOutcomeUnknown = true;
      });
    }
  }

  Future<void> _toggleInput() => _setInputState(!_ffiModel.inputBlocked);

  Future<void> _recoverInput() => _setInputState(false);

  Future<void> _setPrivacyState(bool desired,
      {bool allowRecoveryWithoutControl = false}) async {
    if (_pendingPrivacy != null || !_privacySupported) return;
    if (!_canControl && !allowRecoveryWithoutControl) return;
    final implKey = _preferredPrivacyImpl();
    setState(() {
      _pendingPrivacy = desired;
      _privacyOutcomeUnknown = false;
    });
    _privacyTimer?.cancel();
    _privacyTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _pendingPrivacy != desired) return;
      setState(() {
        _pendingPrivacy = null;
        _privacyOutcomeUnknown = true;
      });
    });
    try {
      await bind.sessionTogglePrivacyMode(
        sessionId: widget.ffi.sessionId,
        implKey: implKey,
        on: desired,
      );
    } catch (_) {
      _privacyTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _pendingPrivacy = null;
        _privacyOutcomeUnknown = true;
      });
    }
  }

  Future<void> _togglePrivacy() {
    final current = PrivacyModeState.find(widget.ffi.id).value;
    return _setPrivacyState(current.isEmpty);
  }

  Future<void> _restorePrivacy() =>
      _setPrivacyState(false, allowRecoveryWithoutControl: true);

  Future<void> _toggleLockOnDisconnect(bool desired) async {
    if (!_canControl || desired == _lockOnDisconnectRequested) return;
    await bind.sessionToggleOption(
      sessionId: widget.ffi.sessionId,
      value: 'lock-after-session-end',
    );
    if (!mounted) return;
    setState(() => _lockOnDisconnectRequested = desired);
  }

  Future<void> _requestSessionLock() async {
    if (!_canControl) return;
    await bind.sessionLockScreen(sessionId: widget.ffi.sessionId);
    if (!mounted) return;
    setState(() => _sessionLockRequested = true);
  }

  @override
  Widget build(BuildContext context) => Obx(() {
        final privacyImpl = PrivacyModeState.find(widget.ffi.id).value;
        final privacyActive = privacyImpl.isNotEmpty;
        final blockPermission = _ffiModel.permissions['block_input'] != false;
        final privacyPermission =
            _ffiModel.permissions['privacy_mode'] != false;
        final privacyRecovery = privacyActive || _privacyOutcomeUnknown;

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
                Text('Privacy & host controls',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  'Each control reports what the PC actually confirms. One-time Windows lock requests are kept separate from local input blocking and screen privacy.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: MirpgRemoteTheme.textSecondary,
                      ),
                ),
                const SizedBox(height: 18),
                _ControlCard(
                  icon: Icons.visibility_off_outlined,
                  title: 'Screen privacy',
                  status: !_privacySupported
                      ? 'Unsupported by this host'
                      : _pendingPrivacy != null
                          ? 'Waiting for host confirmation…'
                          : _privacyOutcomeUnknown
                              ? 'Outcome unknown · restore the screen before another privacy attempt'
                              : privacyActive
                                  ? 'Host reports privacy mode active · physical screen not yet verified'
                                  : 'Host reports privacy mode off',
                  enabled: _privacySupported &&
                      _pendingPrivacy == null &&
                      (privacyRecovery || (_canControl && privacyPermission)),
                  actionLabel:
                      privacyRecovery ? 'Restore screen' : 'Enable privacy',
                  action: privacyRecovery ? _restorePrivacy : _togglePrivacy,
                ),
                const SizedBox(height: 10),
                _ControlCard(
                  icon: Icons.keyboard_hide_outlined,
                  title: 'Local keyboard & mouse',
                  status: _pendingInput != null
                      ? 'Waiting for host confirmation…'
                      : _inputOutcomeUnknown
                          ? 'Outcome unknown · release input before another lock attempt'
                          : _ffiModel.inputBlocked
                              ? 'Host verified local input is blocked'
                              : 'Host reports local input is available',
                  enabled:
                      _canControl && blockPermission && _pendingInput == null,
                  actionLabel: (_ffiModel.inputBlocked || _inputOutcomeUnknown)
                      ? 'Release input'
                      : 'Lock input',
                  action: _inputOutcomeUnknown ? _recoverInput : _toggleInput,
                ),
                const SizedBox(height: 10),
                _ControlCard(
                  icon: Icons.lock_outline,
                  title: 'Windows session lock',
                  status: _sessionLockRequested
                      ? 'Lock request sent · host verification unavailable'
                      : 'One-time request · observed lock state unavailable',
                  enabled: _canControl,
                  actionLabel: 'Lock Windows',
                  action: _requestSessionLock,
                ),
                const SizedBox(height: 10),
                Card(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.lock_clock_outlined),
                    title: const Text('Lock Windows when this session ends'),
                    subtitle: Text(
                      _lockOnDisconnectRequested
                          ? 'Requested for this connection · host acknowledgment is unavailable'
                          : 'Off · this setting is not replayed on reconnect',
                    ),
                    value: _lockOnDisconnectRequested,
                    onChanged: _canControl ? _toggleLockOnDisconnect : null,
                  ),
                ),
                const SizedBox(height: 12),
                _Notice(
                  icon: Icons.info_outline,
                  text:
                      'Current Windows privacy implementations may also suppress local input while screen privacy is active. That coupling is shown as a host limitation; it is not treated as the separate Local keyboard & mouse state above.',
                ),
                const SizedBox(height: 10),
                const _Notice(
                  icon: Icons.shield_outlined,
                  text:
                      'Screen privacy protects the local display workflow only. It does not claim to hide the session from another remote viewer.',
                ),
                if (!_canControl || !blockPermission || !privacyPermission) ...[
                  const SizedBox(height: 10),
                  _Notice(
                    icon: Icons.admin_panel_settings_outlined,
                    text: !_canControl
                        ? 'Remote-control permission is required to change host privacy or lock state.'
                        : 'One or more host privacy permissions are disabled for this session.',
                  ),
                ],
              ],
            ),
          ),
        );
      });
}

class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.icon,
    required this.title,
    required this.status,
    required this.enabled,
    required this.actionLabel,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String status;
  final bool enabled;
  final String actionLabel;
  final Future<void> Function() action;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, color: MirpgRemoteTheme.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      status,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: MirpgRemoteTheme.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonal(
                onPressed: enabled ? () => unawaited(action()) : null,
                child: Text(actionLabel),
              ),
            ],
          ),
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MirpgRemoteTheme.controlRadius),
          border: Border.all(color: MirpgRemoteTheme.outline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: MirpgRemoteTheme.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
