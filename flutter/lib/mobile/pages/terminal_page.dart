import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/models/input_modifier_utils.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/terminal_copy_shortcut.dart';
import 'package:flutter_hbb/models/terminal_model.dart';
import 'package:flutter_hbb/models/terminal_mouse_handler.dart';
import 'package:flutter_hbb/mobile/terminal_keyboard_utils.dart';
import 'package:flutter_hbb/web/dummy.dart'
    if (dart.library.html) 'package:flutter_hbb/web/terminal_font.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';
import '../../desktop/pages/terminal_connection_manager.dart';
import '../../consts.dart';
import '../widgets/mirpg_remote_theme.dart';
import '../widgets/shell_paste_sheet.dart';

const _terminalBackgroundOpacity = 0.7;

Widget _buildTerminalViewForPlatform({
  required bool reportMouseInput,
  required bool reportTouchInput,
  required Terminal terminal,
  required TerminalController controller,
  required TerminalStyle textStyle,
  required EdgeInsets padding,
  required bool deleteDetection,
  required Map<ShortcutActivator, Intent>? shortcuts,
  required FocusOnKeyEventCallback onKeyEvent,
  required void Function(TapDownDetails, CellOffset) onSecondaryTapDown,
}) {
  if (reportMouseInput || reportTouchInput) {
    return TerminalMouseInteraction(
      terminal,
      controller: controller,
      autofocus: true,
      textStyle: textStyle,
      deleteDetection: deleteDetection,
      reportTouchInput: reportTouchInput,
      shortcuts: shortcuts,
      onKeyEvent: onKeyEvent,
      backgroundOpacity: _terminalBackgroundOpacity,
      padding: padding,
      onSecondaryTapDown: onSecondaryTapDown,
    );
  }
  return TerminalView(
    terminal,
    controller: controller,
    autofocus: true,
    textStyle: textStyle,
    deleteDetection: deleteDetection,
    shortcuts: shortcuts,
    onKeyEvent: onKeyEvent,
    backgroundOpacity: _terminalBackgroundOpacity,
    padding: padding,
    onSecondaryTapDown: onSecondaryTapDown,
  );
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    Key? key,
    required this.id,
    required this.password,
    required this.isSharedPassword,
    this.forceRelay,
    this.connToken,
    this.embedded = false,
  }) : super(key: key);
  final String id;
  final String? password;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final bool embedded;
  final terminalId = 0;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  bool get _canConfigureTerminalClipboardPermission =>
      canConfigureTerminalClipboardPermission(
        settingsDisabled: bind.isDisableSettings(),
        optionFixed: isOptionFixed(kOptionAllowTerminalClipboardWrite),
      );
  bool get _canHandleTerminalClipboardWriteRequest =>
      canHandleTerminalClipboardWriteRequest(
        localOption: bind.mainGetLocalOption(
          key: kOptionAllowTerminalClipboardWrite,
        ),
        canConfigurePermission: _canConfigureTerminalClipboardPermission,
      );

  late FFI _ffi;
  late TerminalModel _terminalModel;
  double? _cellHeight;
  double _sysKeyboardHeight = 0;
  Timer? _keyboardDebounce;
  final GlobalKey _keyboardKey = GlobalKey();
  double _keyboardHeight = 0;
  late bool _showTerminalExtraKeys;
  // Ctrl lock state for virtual keyboard: active key presses are mapped to control codes
  bool _ctrlLocked = false;
  bool _altLocked = false;
  // Row3 expand/collapse state for compact keyboard layout
  bool _row3Expanded = false;
  // For iOS edge swipe gesture
  double _swipeStartX = 0;
  double _swipeCurrentX = 0;
  ScaffoldFeatureController<MaterialBanner, MaterialBannerClosedReason>?
      _terminalClipboardNoticeController;
  final _terminalClipboardNotice = TerminalClipboardNoticeCoordinator<int>();
  final _shellDraftController = TextEditingController();
  final _shellDraftFocus = FocusNode();
  bool _shellDraftVisible = false;
  bool _shellDraftSending = false;
  bool _shellDraftRetryBlocked = false;
  String _shellDraftPeerId = '';
  int _shellDraftPeerInfoGeneration = -1;
  int _shellDraftReconnectGeneration = -1;
  int _shellReviewRequest = 0;
  bool _shellReviewOpen = false;
  late int _observedPeerInfoGeneration;
  late int _observedReconnectGeneration;
  late bool _observedAuthenticated;

  // For web only.
  // 'monospace' does not work on web, use Google Fonts, `??` is only for null safety.
  final String _robotoMonoFontFamily = isWeb
      ? (GoogleFonts.robotoMono().fontFamily ?? 'monospace')
      : 'monospace';

  SessionID get sessionId => _ffi.sessionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (isWeb) {
      loadLocalTerminalFontIfNeeded();
    }

    debugPrint(
        '[TerminalPage] Initializing terminal ${widget.terminalId} for peer ${widget.id}');

    // Use shared FFI instance from connection manager
    _ffi = TerminalConnectionManager.getConnection(
      peerId: widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
      connToken: widget.connToken,
    );

    // Create terminal model with specific terminal ID
    _terminalModel = TerminalModel(_ffi, widget.terminalId);
    if (_canHandleTerminalClipboardWriteRequest) {
      _terminalModel.onClipboardWriteBlocked =
          _handleTerminalClipboardWriteBlocked;
      _terminalModel.onClipboardWriteSucceeded =
          _handleTerminalClipboardWriteSucceeded;
    }
    debugPrint(
        '[TerminalPage] Terminal model created for terminal ${widget.terminalId}');

    _terminalModel.onResizeExternal = (w, h, pw, ph) {
      _cellHeight = ph * 1.0;
    };

    // Register this terminal model with FFI for event routing
    _ffi.registerTerminalModel(widget.terminalId, _terminalModel);

    // Auto-close connection when shell exits
    _terminalModel.onClosed = () {
      if (mounted) {
        if (widget.embedded) {
          unawaited(_ffi.close());
        } else {
          closeConnection(id: widget.id);
        }
      }
    };

    // Web desktop users have full hardware keyboard access, so the on-screen
    // terminal extra keys bar is unnecessary and disabled.
    _showTerminalExtraKeys = !isWebDesktop &&
        mainGetLocalBoolOptionSync(kOptionEnableShowTerminalExtraKeys);
    _terminalModel.isCtrlLocked = () => _ctrlLocked;
    _terminalModel.clearCtrlLock = () {
      if (_ctrlLocked) setState(() => _ctrlLocked = false);
    };
    _terminalModel.isAltLocked = () => _altLocked;
    _terminalModel.clearAltLock = () {
      if (_altLocked) setState(() => _altLocked = false);
    };
    _terminalModel.onUnsafeMobileMultilineInput = (text) {
      unawaited(_reviewShellPasteText(text));
    };
    _observedPeerInfoGeneration = _ffi.ffiModel.peerInfoGeneration;
    _observedReconnectGeneration = _ffi.ffiModel.reconnectGeneration;
    _observedAuthenticated = _ffi.ffiModel.authenticatedPeer;
    _ffi.ffiModel.addListener(_onShellConnectionChanged);
    // Load Row3 expand/collapse state from persistent storage. The raw option
    // read keeps Row3 collapsed when no value has been saved yet.
    _row3Expanded =
        bind.mainGetLocalOption(key: kOptionShowTerminalCtrlKeys) == 'Y';
    // Initialize terminal connection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager.showLoading(translate('Connecting...'),
          onCancel: widget.embedded ? _ffi.close : closeConnection);

      if (_showTerminalExtraKeys) {
        _updateKeyboardHeight();
      }
    });
    if (!widget.embedded) {
      _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
    }
  }

  void _handleTerminalClipboardWriteBlocked(String clipboardText) {
    if (!mounted) return;
    final option = bind.mainGetLocalOption(
      key: kOptionAllowTerminalClipboardWrite,
    );
    final request = _terminalClipboardNotice.recordBlocked(
      source: widget.terminalId,
      text: clipboardText,
      option: option,
      canWrite: (_) => _canWriteTerminalClipboard,
    );
    if (request != null) _showTerminalClipboardNotice(request);
  }

  void _showTerminalClipboardNotice(
    TerminalClipboardNoticeRequest<int> request,
  ) {
    final controller = ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.content_copy_outlined),
        content: Text(translate(kTerminalClipboardNoticeMessageKey)),
        actions: [
          AnimatedBuilder(
            animation: _terminalClipboardNotice,
            builder: (_, __) => TextButton(
              onPressed: _terminalClipboardNotice.canClaimAction
                  ? _handleTerminalClipboardNegativeAction
                  : null,
              child: Text(translate(request.negativeActionKey)),
            ),
          ),
          AnimatedBuilder(
            animation: _terminalClipboardNotice,
            builder: (_, __) => TextButton(
              onPressed: _terminalClipboardNotice.canClaimAction
                  ? _handleTerminalClipboardPositiveAction
                  : null,
              child: Text(translate(request.actionKey)),
            ),
          ),
        ],
      ),
    );
    _terminalClipboardNoticeController = controller;
    unawaited(controller.closed.then<void>((_) {
      if (identical(_terminalClipboardNoticeController, controller)) {
        _terminalClipboardNoticeController = null;
        _terminalClipboardNotice.noticeClosed();
      }
    }));
  }

  void _handleTerminalClipboardNegativeAction() {
    final request = _terminalClipboardNotice.claimCurrentAction();
    if (request == null) return;
    if (request.persistAllowed) {
      unawaited(_declineTerminalClipboardWrite());
    } else {
      _closeTerminalClipboardNotice();
    }
  }

  void _handleTerminalClipboardPositiveAction() {
    final request = _terminalClipboardNotice.claimCurrentAction();
    if (request == null) return;
    unawaited(_completeTerminalClipboardWrite(request));
  }

  bool get _canWriteTerminalClipboard =>
      _canHandleTerminalClipboardWriteRequest &&
      !_ffi.closed &&
      _ffi.ffiModel.permissions['clipboard'] != false;

  void _handleTerminalClipboardWriteSucceeded(String _) {
    _closeTerminalClipboardNotice();
  }

  Future<void> _declineTerminalClipboardWrite() async {
    try {
      await bind.mainSetLocalOption(
        key: kOptionAllowTerminalClipboardWrite,
        value: kTerminalClipboardWriteDenied,
      );
    } catch (error) {
      debugPrint(
          '[TerminalPage] Failed to save terminal clipboard permission: $error');
      return;
    } finally {
      _terminalClipboardNotice.releaseAction();
    }
    _closeTerminalClipboardNotice();
  }

  Future<void> _completeTerminalClipboardWrite(
    TerminalClipboardNoticeRequest<int> request,
  ) async {
    var completed = false;
    try {
      completed = await completeTerminalClipboardWrite(
        clipboardText: request.text,
        canWrite: () => _canWriteTerminalClipboard,
        writeClipboard: writeTerminalClipboard,
        persistAllowed: request.persistAllowed
            ? () => bind.mainSetLocalOption(
                  key: kOptionAllowTerminalClipboardWrite,
                  value: kTerminalClipboardWriteAllowed,
                )
            : null,
      );
    } catch (error) {
      debugPrint(
          '[TerminalPage] Failed to complete terminal clipboard write: $error');
    } finally {
      _terminalClipboardNotice.releaseAction();
    }
    if (!completed) return;
    _closeTerminalClipboardNotice();
  }

  void _closeTerminalClipboardNotice() {
    if (!_terminalClipboardNotice.beginClose()) return;
    final controller = _terminalClipboardNoticeController;
    if (controller == null) {
      debugPrint('[TerminalPage] Clipboard notice controller is missing');
      _terminalClipboardNotice.noticeClosed();
      return;
    }
    controller.close();
  }

  @override
  void dispose() {
    _ffi.ffiModel.removeListener(_onShellConnectionChanged);
    _shellReviewRequest++;
    // Unregister terminal model from FFI
    _ffi.unregisterTerminalModel(widget.terminalId);
    _terminalModel.dispose();
    _keyboardDebounce?.cancel();
    _terminalClipboardNotice.clear();
    _terminalClipboardNoticeController?.close();
    _shellDraftFocus.dispose();
    _shellDraftController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
    TerminalConnectionManager.releaseConnection(widget.id);
  }

  @override
  void didUpdateWidget(covariant TerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _shellReviewRequest++;
      if (_shellDraftVisible) _clearShellDraft();
    }
  }

  bool _shellScopeIsCurrent({
    required String peerId,
    required int peerInfoGeneration,
    required int reconnectGeneration,
  }) =>
      mounted &&
      !_ffi.closed &&
      _ffi.ffiModel.authenticatedPeer &&
      widget.id == peerId &&
      _ffi.ffiModel.peerInfoGeneration == peerInfoGeneration &&
      _ffi.ffiModel.reconnectGeneration == reconnectGeneration;

  void _onShellConnectionChanged() {
    if (!mounted) return;
    final peerInfoGeneration = _ffi.ffiModel.peerInfoGeneration;
    final reconnectGeneration = _ffi.ffiModel.reconnectGeneration;
    final authenticated = _ffi.ffiModel.authenticatedPeer;
    final scopeChanged = peerInfoGeneration != _observedPeerInfoGeneration ||
        reconnectGeneration != _observedReconnectGeneration ||
        authenticated != _observedAuthenticated;
    _observedPeerInfoGeneration = peerInfoGeneration;
    _observedReconnectGeneration = reconnectGeneration;
    _observedAuthenticated = authenticated;
    if (!scopeChanged) return;
    _shellReviewRequest++;
    if (_shellDraftVisible) _clearShellDraft();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();

    _keyboardDebounce?.cancel();
    _keyboardDebounce = Timer(const Duration(milliseconds: 20), () {
      final bottomInset = MediaQuery.of(context).viewInsets.bottom;
      setState(() {
        _sysKeyboardHeight = bottomInset;
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) return;
    _shellReviewRequest++;
    if (_shellDraftVisible) _clearShellDraft();
  }

  void _updateKeyboardHeight() {
    if (_keyboardKey.currentContext != null) {
      final renderBox =
          _keyboardKey.currentContext!.findRenderObject() as RenderBox;
      _keyboardHeight = renderBox.size.height;
    }
  }

  EdgeInsets _calculatePadding(double heightPx) {
    if (_cellHeight == null) {
      return const EdgeInsets.symmetric(horizontal: 5.0, vertical: 2.0);
    }
    final realHeight = heightPx - _sysKeyboardHeight - _keyboardHeight;
    final rows = (realHeight / _cellHeight!).floor();
    final extraSpace = realHeight - rows * _cellHeight!;
    final topBottom = max(0.0, extraSpace / 2.0);
    return EdgeInsets.only(
        left: 5.0,
        right: 5.0,
        top: topBottom,
        bottom: topBottom + _sysKeyboardHeight + _keyboardHeight);
  }

  Future<void> _reviewClipboardForShell() async {
    if (_shellReviewOpen ||
        !_terminalModel.terminalOpened ||
        !_ffi.ffiModel.authenticatedPeer ||
        _ffi.closed) {
      return;
    }
    final request = ++_shellReviewRequest;
    final peerId = widget.id;
    final peerInfoGeneration = _ffi.ffiModel.peerInfoGeneration;
    final reconnectGeneration = _ffi.ffiModel.reconnectGeneration;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (request != _shellReviewRequest ||
        !_shellScopeIsCurrent(
          peerId: peerId,
          peerInfoGeneration: peerInfoGeneration,
          reconnectGeneration: reconnectGeneration,
        )) {
      return;
    }
    final text = data?.text;
    if (text == null) return;
    await _reviewShellPasteText(
      text,
      expectedPeerId: peerId,
      expectedPeerInfoGeneration: peerInfoGeneration,
      expectedReconnectGeneration: reconnectGeneration,
    );
  }

  Future<void> _reviewShellPasteText(
    String text, {
    String? expectedPeerId,
    int? expectedPeerInfoGeneration,
    int? expectedReconnectGeneration,
  }) async {
    if (!mounted || text.isEmpty || _shellReviewOpen) return;
    final peerId = expectedPeerId ?? widget.id;
    final peerInfoGeneration =
        expectedPeerInfoGeneration ?? _ffi.ffiModel.peerInfoGeneration;
    final reconnectGeneration =
        expectedReconnectGeneration ?? _ffi.ffiModel.reconnectGeneration;
    if (!_terminalModel.terminalOpened ||
        !_shellScopeIsCurrent(
          peerId: peerId,
          peerInfoGeneration: peerInfoGeneration,
          reconnectGeneration: reconnectGeneration,
        )) {
      return;
    }
    final request = ++_shellReviewRequest;
    _shellReviewOpen = true;
    bool? insert;
    try {
      insert = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => ShellPasteSheet(targetLabel: peerId, text: text),
      );
    } finally {
      _shellReviewOpen = false;
    }
    if (request != _shellReviewRequest ||
        insert != true ||
        !_shellScopeIsCurrent(
          peerId: peerId,
          peerInfoGeneration: peerInfoGeneration,
          reconnectGeneration: reconnectGeneration,
        )) {
      return;
    }
    setState(() {
      _shellDraftController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _shellDraftVisible = true;
      _shellDraftRetryBlocked = false;
      _shellDraftPeerId = peerId;
      _shellDraftPeerInfoGeneration = peerInfoGeneration;
      _shellDraftReconnectGeneration = reconnectGeneration;
    });
    _terminalModel.terminalController.clearSelection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _shellDraftVisible) _shellDraftFocus.requestFocus();
    });
  }

  void _clearShellDraft() {
    _shellDraftController.clear();
    _shellDraftFocus.unfocus();
    if (mounted) {
      setState(() {
        _shellDraftVisible = false;
        _shellDraftSending = false;
        _shellDraftRetryBlocked = false;
        _shellDraftPeerId = '';
        _shellDraftPeerInfoGeneration = -1;
        _shellDraftReconnectGeneration = -1;
      });
    }
  }

  Future<void> _runShellDraft() async {
    if (_shellDraftSending || _shellDraftRetryBlocked) return;
    final text = _shellDraftController.text;
    if (text.isEmpty) return;
    if (!_shellScopeIsCurrent(
      peerId: _shellDraftPeerId,
      peerInfoGeneration: _shellDraftPeerInfoGeneration,
      reconnectGeneration: _shellDraftReconnectGeneration,
    )) {
      _clearShellDraft();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Shell connection changed. The local draft was discarded.'),
          ),
        );
      }
      return;
    }
    setState(() => _shellDraftSending = true);
    final result = await _terminalModel.runReviewedText(
      text,
      expectedPeerId: _shellDraftPeerId,
      expectedPeerInfoGeneration: _shellDraftPeerInfoGeneration,
      expectedReconnectGeneration: _shellDraftReconnectGeneration,
    );
    if (!mounted) return;
    switch (result) {
      case ReviewedShellSendResult.submitted:
        _clearShellDraft();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sent once to Shell. Check Shell output for the result.',
            ),
          ),
        );
        return;
      case ReviewedShellSendResult.uncertain:
        setState(() {
          _shellDraftSending = false;
          _shellDraftRetryBlocked = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Send result is uncertain. Draft kept; check Shell output before retrying.',
            ),
          ),
        );
        return;
      case ReviewedShellSendResult.notSent:
        setState(() => _shellDraftSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Shell is not ready. Draft kept for review.'),
          ),
        );
        return;
    }
  }

  void _allowShellDraftRetry() {
    if (!_shellDraftRetryBlocked || _shellDraftSending) return;
    if (!_shellScopeIsCurrent(
      peerId: _shellDraftPeerId,
      peerInfoGeneration: _shellDraftPeerInfoGeneration,
      reconnectGeneration: _shellDraftReconnectGeneration,
    )) {
      _clearShellDraft();
      return;
    }
    setState(() => _shellDraftRetryBlocked = false);
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode _, KeyEvent event) {
    final hardwareKeyboard = HardwareKeyboard.instance;
    final shouldPaste = shouldInterceptMobileTerminalPasteShortcut(
      platform: defaultTargetPlatform,
      logicalKey: event.logicalKey,
      isKeyDown: event is KeyDownEvent,
      isKeyRepeat: event is KeyRepeatEvent,
      controlPressed: hardwareKeyboard.isControlPressed,
      metaPressed: hardwareKeyboard.isMetaPressed,
      altPressed: hardwareKeyboard.isAltPressed,
      shiftPressed: hardwareKeyboard.isShiftPressed,
    );
    if (!shouldPaste) return KeyEventResult.ignored;

    unawaited(_reviewClipboardForShell());
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return WillPopScope(
      onWillPop: () async {
        if (widget.embedded) return true;
        clientClose(sessionId, _ffi);
        return false; // Prevent default back behavior
      },
      child: buildBody(),
    );
  }

  Widget buildBody() {
    final scaffold = Scaffold(
      resizeToAvoidBottomInset:
          false, // Disable automatic layout adjustment; manually control UI updates to prevent flickering when the keyboard shows/hides
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              top: !widget.embedded,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final heightPx = constraints.maxHeight;
                  return _buildTerminalViewForPlatform(
                    reportMouseInput: isWebDesktop || isAndroid,
                    reportTouchInput: isIOS,
                    terminal: _terminalModel.terminal,
                    controller: _terminalModel.terminalController,
                    textStyle: _getTerminalStyle(),
                    // The following comment is from xterm.dart source code:
                    // Workaround to detect delete key for platforms and IMEs that do not
                    // emit a hardware delete event. Preferred on mobile platforms. [false] by
                    // default.
                    //
                    // Android works fine without this workaround.
                    deleteDetection: isIOS,
                    shortcuts: platformTerminalShortcuts(allowPaste: false),
                    onKeyEvent: terminalCopyHandler(
                      _terminalModel.terminal,
                      _terminalModel.terminalController,
                      fallback: _handleTerminalKeyEvent,
                    ),
                    padding: _calculatePadding(heightPx),
                    onSecondaryTapDown: (details, offset) async {
                      final selection =
                          _terminalModel.terminalController.selection;
                      if (selection != null) {
                        final text =
                            _terminalModel.terminal.buffer.getText(selection);
                        _terminalModel.terminalController.clearSelection();
                        await Clipboard.setData(ClipboardData(text: text));
                      } else {
                        await _reviewClipboardForShell();
                      }
                    },
                  );
                },
              ),
            ),
          ),
          if (_showTerminalExtraKeys) _buildFloatingKeyboard(),
          Positioned(
            left: 8,
            top: 8,
            child: SafeArea(
              child: IconButton.filledTonal(
                tooltip: 'Review clipboard paste',
                onPressed: _reviewClipboardForShell,
                icon: const Icon(Icons.content_paste_search_outlined),
              ),
            ),
          ),
          if (_shellDraftVisible) _buildShellDraftComposer(),
          // iOS-style circular close button in top-right corner
          if (isIOS && !widget.embedded) _buildCloseButton(),
        ],
      ),
    );

    // Add iOS edge swipe gesture to exit (similar to Android back button)
    if (isIOS && !widget.embedded) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final screenWidth = constraints.maxWidth;
          // Base thresholds on screen width but clamp to reasonable logical pixel ranges
          // Edge detection region: ~10% of width, clamped between 20 and 80 logical pixels
          final edgeThreshold = (screenWidth * 0.1).clamp(20.0, 80.0);
          // Required horizontal movement: ~25% of width, clamped between 80 and 300 logical pixels
          final swipeThreshold = (screenWidth * 0.25).clamp(80.0, 300.0);

          return RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: <Type, GestureRecognizerFactory>{
              HorizontalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      HorizontalDragGestureRecognizer>(
                () => HorizontalDragGestureRecognizer(
                  debugOwner: this,
                  // Only respond to touch input, exclude mouse/trackpad
                  supportedDevices: kTouchBasedDeviceKinds,
                ),
                (HorizontalDragGestureRecognizer instance) {
                  instance
                    // Capture initial touch-down position (before touch slop)
                    ..onDown = (details) {
                      _swipeStartX = details.localPosition.dx;
                      _swipeCurrentX = details.localPosition.dx;
                    }
                    ..onUpdate = (details) {
                      _swipeCurrentX = details.localPosition.dx;
                    }
                    ..onEnd = (details) {
                      // Check if swipe started from left edge and moved right
                      if (_swipeStartX < edgeThreshold &&
                          (_swipeCurrentX - _swipeStartX) > swipeThreshold) {
                        clientClose(sessionId, _ffi);
                      }
                      _swipeStartX = 0;
                      _swipeCurrentX = 0;
                    }
                    ..onCancel = () {
                      _swipeStartX = 0;
                      _swipeCurrentX = 0;
                    };
                },
              ),
            },
            child: scaffold,
          );
        },
      );
    }

    return scaffold;
  }

  Widget _buildShellDraftComposer() {
    final bottom = _sysKeyboardHeight + _keyboardHeight + 8;
    return Positioned(
      left: 8,
      right: 8,
      bottom: bottom,
      child: SafeArea(
        top: false,
        child: Material(
          color: MirpgRemoteTheme.surface,
          elevation: 8,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.terminal, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Shell draft · local until Run / Enter',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Discard Shell draft',
                      onPressed: _shellDraftSending ? null : _clearShellDraft,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: TextField(
                    key: const ValueKey('shell-paste-draft'),
                    controller: _shellDraftController,
                    focusNode: _shellDraftFocus,
                    enabled: !_shellDraftSending,
                    minLines: 1,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: 'Review or edit before running',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_shellDraftRetryBlocked) ...[
                  const Text(
                    'Previous send is uncertain. Check Shell output before allowing another send.',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('shell-paste-allow-retry'),
                    onPressed: _allowShellDraftRetry,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('I checked Shell output — allow retry'),
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton.icon(
                  key: const ValueKey('shell-paste-run'),
                  onPressed: _shellDraftSending || _shellDraftRetryBlocked
                      ? null
                      : () => unawaited(_runShellDraft()),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    _shellDraftSending ? 'Sending…' : 'Run / Enter',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        minimum: const EdgeInsets.only(
          top: 16, // iOS standard margin
          right: 16, // iOS standard margin
        ),
        child: Semantics(
          button: true,
          label: translate('Close'),
          child: Container(
            width: 44, // iOS standard tap target size
            height: 44,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5), // Half transparency
              shape: BoxShape.circle,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  clientClose(sessionId, _ffi);
                },
                child: Tooltip(
                  message: translate('Close'),
                  child: const Icon(
                    Icons.chevron_left, // iOS-style back arrow
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingKeyboard() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      left: 0,
      right: 0,
      bottom: _sysKeyboardHeight,
      child: Container(
        key: _keyboardKey,
        decoration: const BoxDecoration(
          color: MirpgRemoteTheme.surface,
          border: Border(top: BorderSide(color: MirpgRemoteTheme.divider)),
        ),
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Row 1 follows the latest reviewed PR layout.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: _buildKeyboardKeyButtons(terminalKeyboardRow1Keys),
            ),
            // Row 2 ends with the full-width Row3 collapse/expand toggle.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ..._buildKeyboardKeyButtons(terminalKeyboardRow2Keys),
                const SizedBox(width: terminalKeyboardKeySpacing),
                _buildCollapseButton(),
              ],
            ),
            // Row 3 restores paging keys and trailing alignment placeholders.
            if (_row3Expanded)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ..._buildKeyboardKeyButtons(terminalKeyboardRow3Keys),
                  for (var i = 0;
                      i < terminalKeyboardRow3TrailingPlaceholderCount;
                      i++) ...[
                    const SizedBox(width: terminalKeyboardKeySpacing),
                    const SizedBox(width: terminalKeyboardKeyWidth),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  // Ctrl toggle button with highlighted locked state
  Widget _buildCtrlKeyButton() {
    return _buildModifierToggleButton(
      text: 'Ctrl',
      semanticsLabel: 'Ctrl',
      isLocked: _ctrlLocked,
      onPressed: () => setState(() => _ctrlLocked = !_ctrlLocked),
    );
  }

  // Alt toggle button with highlighted locked state
  Widget _buildAltKeyButton() {
    return _buildModifierToggleButton(
      text: 'Alt',
      semanticsLabel: 'Alt',
      isLocked: _altLocked,
      onPressed: () => setState(() => _altLocked = !_altLocked),
    );
  }

  // Collapse/expand toggle button for Row3
  void _toggleRow3Expanded() {
    final willExpand = !_row3Expanded;
    final shouldClearModifiers = shouldClearTerminalModifiersWhenRow3Collapses(
      wasExpanded: _row3Expanded,
      willExpand: willExpand,
      ctrlLocked: _ctrlLocked,
      altLocked: _altLocked,
    );
    setState(() {
      _row3Expanded = willExpand;
      if (shouldClearModifiers) {
        _ctrlLocked = false;
        _altLocked = false;
      }
    });
    mainSetLocalBoolOption(kOptionShowTerminalCtrlKeys, willExpand);

    // The floating keyboard height changes after Row3 is inserted/removed.
    // Re-measure on the next frame so terminal padding uses the new height.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showTerminalExtraKeys) return;
      setState(() {
        _updateKeyboardHeight();
      });
    });
  }

  Widget _buildCollapseButton() {
    return Semantics(
      label: translate('Show terminal extra keys'),
      toggled: _row3Expanded,
      child: ElevatedButton(
        onPressed: _toggleRow3Expanded,
        child: Text(_row3Expanded ? '∧' : '∨'),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(terminalKeyboardKeyWidth, 32),
          padding: EdgeInsets.zero,
          textStyle: const TextStyle(fontSize: 12),
          backgroundColor: MirpgRemoteTheme.raised,
          foregroundColor: MirpgRemoteTheme.textPrimary,
          side: const BorderSide(color: MirpgRemoteTheme.outline),
        ),
      ),
    );
  }

  /// Builds a fixed-width key sequence with the reviewed 2dp spacing.
  List<Widget> _buildKeyboardKeyButtons(List<String> labels) {
    return [
      for (var i = 0; i < labels.length; i++) ...[
        _buildKeyButton(labels[i]),
        if (i < labels.length - 1)
          const SizedBox(width: terminalKeyboardKeySpacing),
      ],
    ];
  }

  /// Build a modifier toggle button (Ctrl/Alt) with one-shot behavior.
  /// When [isLocked] is true, the button highlights in blue and the next
  /// single-character input is mapped to its modified equivalent.
  Widget _buildModifierToggleButton({
    required String text,
    required String semanticsLabel,
    required bool isLocked,
    required VoidCallback onPressed,
  }) {
    return Semantics(
      // Ctrl and Alt are technical key names and intentionally stay unchanged.
      label: semanticsLabel,
      toggled: isLocked,
      child: ElevatedButton(
        onPressed: onPressed,
        child: Text(text),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(terminalKeyboardKeyWidth, 32),
          padding: EdgeInsets.zero,
          textStyle: const TextStyle(fontSize: 12),
          backgroundColor:
              isLocked ? MirpgRemoteTheme.accent : MirpgRemoteTheme.raised,
          foregroundColor: isLocked
              ? MirpgRemoteTheme.background
              : MirpgRemoteTheme.textPrimary,
          side: BorderSide(
            color:
                isLocked ? MirpgRemoteTheme.accent : MirpgRemoteTheme.outline,
          ),
        ),
      ),
    );
  }

  Widget _buildKeyButton(String label) {
    if (label == 'Ctrl') return _buildCtrlKeyButton();
    if (label == 'Alt') return _buildAltKeyButton();

    return ElevatedButton(
      onPressed: () {
        _sendKeyToTerminal(label);
      },
      child: Text(label),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(terminalKeyboardKeyWidth, 32),
        padding: EdgeInsets.zero,
        textStyle: const TextStyle(fontSize: 12),
        backgroundColor: MirpgRemoteTheme.raised,
        foregroundColor: MirpgRemoteTheme.textPrimary,
        side: const BorderSide(color: MirpgRemoteTheme.outline),
      ),
    );
  }

  void _sendKeyToTerminal(String key) {
    String send;

    switch (key) {
      case 'Esc':
        send = '\x1B';
        break;
      case 'Tab':
        send = '\t';
        break;
      case 'Ctrl+C':
        send = '\x03';
        break;

      case '↑':
        send = '\x1B[A';
        break;
      case '↓':
        send = '\x1B[B';
        break;
      case '→':
        send = '\x1B[C';
        break;
      case '←':
        send = '\x1B[D';
        break;

      case 'Home':
        send = '\x1B[H';
        break;
      case 'End':
        send = '\x1B[F';
        break;
      case 'PgUp':
        send = '\x1B[5~';
        break;
      case 'PgDn':
        send = '\x1B[6~';
        break;

      default:
        send = key;
        break;
    }

    _terminalModel.sendVirtualKey(send);
  }

  // https://github.com/TerminalStudio/xterm.dart/issues/42#issuecomment-877495472
  // https://github.com/TerminalStudio/xterm.dart/issues/198#issuecomment-2526548458
  TerminalStyle _getTerminalStyle() {
    return isWeb
        ? TerminalStyle(
            fontFamily: _robotoMonoFontFamily,
            fontSize: 14,
          )
        : const TerminalStyle();
  }

  @override
  bool get wantKeepAlive => true;
}
