import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/emulator_model.dart';
import '../../models/host_management_model.dart';
import '../../models/remote_operation_state.dart';
import 'mirpg_remote_theme.dart';

class WindowPickerSheet extends StatefulWidget {
  const WindowPickerSheet({
    super.key,
    required this.model,
    required this.canControl,
    this.onFocused,
  });

  final EmulatorModel model;
  final bool canControl;
  final FutureOr<void> Function(HostWindowInfo)? onFocused;

  @override
  State<WindowPickerSheet> createState() => _WindowPickerSheetState();
}

class _WindowPickerSheetState extends State<WindowPickerSheet> {
  String _focusingId = '';

  @override
  void initState() {
    super.initState();
    if (widget.model.hostWindowsCapability == CapabilityStatus.supported &&
        widget.model.hostWindowsSnapshot == null) {
      unawaited(widget.model.refreshHostWindows());
    }
  }

  Future<void> _focus(HostWindowInfo window) async {
    if (_focusingId.isNotEmpty || !widget.canControl || !window.canFocus) {
      return;
    }
    setState(() => _focusingId = window.id);
    final observed = await widget.model.focusHostWindow(window);
    if (!mounted) return;
    setState(() => _focusingId = '');
    if (observed == null) return;
    await widget.onFocused?.call(observed);
    if (!mounted) return;
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.model,
        builder: (context, _) {
          final capability = widget.model.hostWindowsCapability;
          final snapshot = widget.model.hostWindowsSnapshot;
          return SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.78,
              ),
              child: Material(
                color: MirpgRemoteTheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(MirpgRemoteTheme.sheetRadius),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.web_asset_outlined),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Windows',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Refresh windows',
                            onPressed: capability ==
                                        CapabilityStatus.supported &&
                                    !widget.model.hostWindowsLoading
                                ? () =>
                                    unawaited(widget.model.refreshHostWindows())
                                : null,
                            icon: const Icon(Icons.refresh),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: Navigator.of(context).canPop()
                                ? () => Navigator.of(context).pop()
                                : null,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Flexible(child: _body(capability, snapshot)),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _body(CapabilityStatus capability, HostWindowSnapshot? snapshot) {
    final windowError = widget.model.hostWindowsError;
    if (capability != CapabilityStatus.supported) {
      return _message(
        Icons.web_asset_off_outlined,
        capability == CapabilityStatus.unknown
            ? 'Waiting for Windows capability information…'
            : 'Window picker isn’t available on this PC.',
        capability == CapabilityStatus.unsupported
            ? 'Reconnect after updating the PC host to use this feature.'
            : 'The connection is still negotiating host features.',
      );
    }
    if (snapshot == null && widget.model.hostWindowsLoading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (snapshot == null && windowError.isNotEmpty) {
      return _message(
        Icons.error_outline,
        'Couldn’t load Windows',
        windowError,
      );
    }
    if (snapshot == null || snapshot.windows.isEmpty) {
      return _message(
        Icons.window_outlined,
        'No app windows found',
        'Open an app on the PC, then refresh this list.',
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      itemCount: snapshot.windows.length + (windowError.isNotEmpty ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (windowError.isNotEmpty && index == 0) {
          return ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Window list may be out of date'),
            subtitle: Text(windowError),
          );
        }
        if (windowError.isNotEmpty) index--;
        final window = snapshot.windows[index];
        final focusing = _focusingId == window.id;
        return ListTile(
          key: ValueKey('host-window-${window.id}'),
          leading: const CircleAvatar(
            backgroundColor: MirpgRemoteTheme.raised,
            child: Icon(Icons.web_asset_outlined, size: 20),
          ),
          title: Text(
            window.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${window.application} · Monitor ${window.monitor + 1}'
            '${window.minimized ? ' · Minimized' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: SizedBox(
            width: 84,
            child: FilledButton.tonal(
              onPressed: widget.canControl &&
                      window.canFocus &&
                      _focusingId.isEmpty &&
                      widget.model.hostWindowFocusCapability ==
                          CapabilityStatus.supported
                  ? () => unawaited(_focus(window))
                  : null,
              child: focusing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Focus'),
            ),
          ),
        );
      },
    );
  }

  Widget _message(IconData icon, String title, String detail) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 38, color: MirpgRemoteTheme.textSecondary),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: MirpgRemoteTheme.textSecondary)),
          ],
        ),
      );
}
