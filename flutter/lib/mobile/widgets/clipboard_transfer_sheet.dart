import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/clipboard_transfer_model.dart';
import 'mirpg_remote_theme.dart';

class ClipboardTransferSheet extends StatefulWidget {
  const ClipboardTransferSheet({
    super.key,
    required this.model,
    required this.targetLabel,
    this.initialDirection = ClipboardTransferDirection.phoneToHost,
  });

  final ClipboardTransferModel model;
  final String targetLabel;
  final ClipboardTransferDirection initialDirection;

  @override
  State<ClipboardTransferSheet> createState() => _ClipboardTransferSheetState();
}

class _ClipboardTransferSheetState extends State<ClipboardTransferSheet> {
  late ClipboardTransferDirection _direction;
  String _localError = '';

  @override
  void initState() {
    super.initState();
    _direction = widget.initialDirection;
  }

  @override
  void dispose() {
    widget.model.clearEphemeralState(notify: false);
    super.dispose();
  }

  Future<void> _readPhoneClipboard() async {
    final scope = widget.model.context;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text == null) {
      setState(
          () => _localError = 'The phone clipboard does not contain text.');
      return;
    }
    setState(() => _localError = '');
    final staged = widget.model.stagePhoneToHost(
      data!.text!,
      expectedContext: scope,
    );
    if (!staged && widget.model.error.isEmpty && mounted) {
      setState(() => _localError =
          'The clipboard target changed. Read the phone clipboard again.');
    }
  }

  Future<void> _copyToPhone() async {
    final preview = widget.model.preview;
    if (preview == null ||
        preview.direction != ClipboardTransferDirection.hostToPhone ||
        !widget.model.canCopyPreviewToPhone(preview)) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: preview.text));
      if (!mounted) return;
      if (widget.model.markCopiedToPhone(preview)) {
        setState(() => _localError = '');
      } else {
        setState(() => _localError =
            'The target or clipboard permission changed while copying.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _localError = 'Could not write the phone clipboard.');
      }
    }
  }

  void _changeDirection(Set<ClipboardTransferDirection> values) {
    final next = values.single;
    if (next == _direction) return;
    widget.model.clearEphemeralState();
    setState(() {
      _direction = next;
      _localError = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final preview = widget.model.preview;
        final previewForDirection =
            preview?.direction == _direction ? preview : null;
        final error = _localError.isNotEmpty ? _localError : widget.model.error;
        final canAct = widget.model.capabilitySupported &&
            widget.model.permissionGranted &&
            !widget.model.pending;
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              MirpgRemoteTheme.pageMargin,
              16,
              MirpgRemoteTheme.pageMargin,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Clipboard',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close clipboard',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  'Target: ${widget.targetLabel}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SegmentedButton<ClipboardTransferDirection>(
                  segments: const [
                    ButtonSegment(
                      value: ClipboardTransferDirection.phoneToHost,
                      label: Text('Phone → PC'),
                      icon: Icon(Icons.phone_android),
                    ),
                    ButtonSegment(
                      value: ClipboardTransferDirection.hostToPhone,
                      label: Text('PC → Phone'),
                      icon: Icon(Icons.computer),
                    ),
                  ],
                  selected: {_direction},
                  onSelectionChanged:
                      widget.model.pending ? null : _changeDirection,
                ),
                const SizedBox(height: 12),
                const _ClipboardNotice(
                  text: 'Copy only. No keyboard or command input is sent.',
                ),
                if (!widget.model.capabilitySupported) ...[
                  const SizedBox(height: 8),
                  const _ClipboardNotice(
                    text:
                        'This PC does not support deliberate clipboard transfer.',
                    warning: true,
                  ),
                ] else if (!widget.model.permissionGranted) ...[
                  const SizedBox(height: 8),
                  const _ClipboardNotice(
                    text: 'Clipboard permission is disabled for this session.',
                    warning: true,
                  ),
                ],
                const SizedBox(height: 16),
                if (_direction == ClipboardTransferDirection.phoneToHost)
                  OutlinedButton.icon(
                    onPressed: canAct ? _readPhoneClipboard : null,
                    icon: const Icon(Icons.content_paste_search_outlined),
                    label: const Text('Read phone clipboard'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed:
                        canAct ? () => widget.model.requestHostToPhone() : null,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Read PC clipboard'),
                  ),
                if (previewForDirection != null) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Exact text',
                          style: theme.textTheme.labelLarge,
                        ),
                      ),
                      Text(
                        '${previewForDirection.text.length} characters',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    key: const ValueKey('clipboard-exact-text'),
                    constraints: const BoxConstraints(maxHeight: 240),
                    decoration: BoxDecoration(
                      color: MirpgRemoteTheme.raised,
                      border: Border.all(color: MirpgRemoteTheme.outline),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectionArea(
                        child: Text(
                          previewForDirection.text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_direction == ClipboardTransferDirection.phoneToHost)
                    FilledButton.icon(
                      onPressed: canAct
                          ? () => widget.model.copyPreviewToHost()
                          : null,
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy to PC'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: canAct ? _copyToPhone : null,
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy to phone'),
                    ),
                ],
                if (widget.model.pending) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (widget.model.message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(widget.model.message),
                ],
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ClipboardNotice extends StatelessWidget {
  const _ClipboardNotice({required this.text, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: MirpgRemoteTheme.raised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MirpgRemoteTheme.outline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                warning ? Icons.warning_amber_rounded : Icons.info_outline,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      );
}
