import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'platform_model.dart';

typedef CodexCommandSender = Future<void> Function(String key, String value);

class CodexThread {
  const CodexThread({
    required this.id,
    required this.title,
    required this.project,
    required this.originator,
    required this.updatedAt,
    required this.state,
  });

  final String id;
  final String title;
  final String project;
  final String originator;
  final int updatedAt;
  final String state;

  factory CodexThread.fromJson(Map<String, dynamic> json) => CodexThread(
        id: _asString(json['id']),
        title: _asString(json['title']),
        project: _asString(json['project']),
        originator: _asString(json['originator']),
        updatedAt: _asInt(json['updated_at']),
        state: _asString(json['state']),
      );

  CodexThread copyWith({String? state}) => CodexThread(
        id: id,
        title: title,
        project: project,
        originator: originator,
        updatedAt: updatedAt,
        state: state ?? this.state,
      );
}

class CodexHistoryItem {
  const CodexHistoryItem({
    required this.id,
    required this.turnId,
    required this.kind,
    required this.text,
    required this.detail,
    required this.status,
  });

  final String id;
  final String turnId;
  final String kind;
  final String text;
  final String detail;
  final String status;

  factory CodexHistoryItem.fromJson(Map<String, dynamic> json) =>
      CodexHistoryItem(
        id: _asString(json['id']),
        turnId: _asString(json['turn_id']),
        kind: _asString(json['kind']),
        text: _asString(json['text']),
        detail: _asString(json['detail']),
        status: _asString(json['status']),
      );

  CodexHistoryItem copyWith({
    String? kind,
    String? text,
    String? detail,
    String? status,
  }) =>
      CodexHistoryItem(
        id: id,
        turnId: turnId,
        kind: kind ?? this.kind,
        text: text ?? this.text,
        detail: detail ?? this.detail,
        status: status ?? this.status,
      );
}

class CodexApproval {
  const CodexApproval({
    required this.id,
    required this.threadId,
    required this.turnId,
    required this.itemId,
    required this.kind,
    required this.title,
    required this.summary,
    required this.reason,
    required this.startedAtMs,
    required this.actionable,
  });

  final String id;
  final String threadId;
  final String turnId;
  final String itemId;
  final String kind;
  final String title;
  final String summary;
  final String reason;
  final int startedAtMs;
  final bool actionable;

  factory CodexApproval.fromJson(Map<String, dynamic> json) => CodexApproval(
        id: _asString(json['approval_id']),
        threadId: _asString(json['thread_id']),
        turnId: _asString(json['turn_id']),
        itemId: _asString(json['item_id']),
        kind: _asString(json['kind']),
        title: _asString(json['title']),
        summary: _asString(json['summary']),
        reason: _asString(json['reason']),
        startedAtMs: _asInt(json['started_at_ms']),
        actionable: _asBool(json['actionable']),
      );
}

class _PendingCodexControl {
  const _PendingCodexControl({
    required this.action,
    required this.threadId,
    this.workspaceThreadId = '',
    this.approvalId = '',
  });

  final String action;
  final String threadId;
  final String workspaceThreadId;
  final String approvalId;
}

class CodexModel with ChangeNotifier {
  CodexModel(this.sessionId, {CodexCommandSender? commandSender})
      : _commandSender = commandSender ??
            ((key, value) => bind.sessionSetCommon(
                  sessionId: sessionId,
                  key: key,
                  value: value,
                ));

  static const int historyPageSize = 50;

  final UuidValue sessionId;
  final CodexCommandSender _commandSender;

  final Map<String, List<CodexHistoryItem>> _history = {};
  final Map<String, String> _nextCursors = {};
  final Map<String, String> _threadErrors = {};
  final Set<String> _loadingHistory = {};
  final Set<String> _pendingThreadListRequests = {};
  final Map<String, bool> _historyResetByRequest = {};
  final Map<String, String> _historyThreadByRequest = {};
  final Map<String, String> _activeTurnIds = {};
  final Map<String, String> _startingTurnIds = {};
  final Map<String, _PendingCodexControl> _pendingControlRequests = {};
  final Map<String, List<CodexApproval>> _approvals = {};

  List<CodexThread> threads = const [];
  String serviceState = 'unavailable';
  String codexVersion = '';
  String error = '';
  String lastStartedThreadId = '';
  String? selectedThreadId;
  String? _subscribedThreadId;
  bool loadingThreads = false;
  bool canResumeThread = false;
  bool canStartThread = false;
  bool canStartTurn = false;
  bool canSteerTurn = false;
  bool canInterruptTurn = false;
  bool canRespondToApprovals = false;
  int _requestSerial = 0;

  List<CodexHistoryItem> historyFor(String threadId) =>
      List.unmodifiable(_history[threadId] ?? const []);

  String nextCursorFor(String threadId) => _nextCursors[threadId] ?? '';

  String errorFor(String threadId) => _threadErrors[threadId] ?? '';

  bool isHistoryLoading(String threadId) => _loadingHistory.contains(threadId);

  bool isControlPending(String threadId) => _pendingControlRequests.values.any(
        (pending) =>
            pending.threadId == threadId ||
            pending.workspaceThreadId == threadId,
      );

  List<CodexApproval> approvalsFor(String threadId) =>
      List.unmodifiable(_approvals[threadId] ?? const []);

  bool isApprovalPending(String approvalId) => _pendingControlRequests.values
      .any((pending) => pending.approvalId == approvalId);

  bool get isStartingThread => _pendingControlRequests.values
      .any((pending) => pending.action == 'start_thread');

  String activeTurnIdFor(String threadId) => _activeTurnIds[threadId] ?? '';

  bool isTurnStarting(String threadId) =>
      _startingTurnIds.containsKey(threadId);

  bool needsNativeResume(String threadId) => threads.any(
        (thread) => thread.id == threadId && thread.state == 'resumable',
      );

  bool get isReady => serviceState == 'ready';

  bool get hasInteractiveControl =>
      canResumeThread ||
      canStartThread ||
      canStartTurn ||
      canSteerTurn ||
      canInterruptTurn ||
      canRespondToApprovals;

  Future<void> listThreads() async {
    final requestId = _nextRequestId('threads');
    _pendingThreadListRequests.add(requestId);
    loadingThreads = true;
    error = '';
    if (serviceState == 'unavailable' || serviceState == 'disconnected') {
      serviceState = 'starting';
    }
    notifyListeners();

    try {
      await _commandSender('codex-list-threads', requestId);
    } catch (e) {
      _pendingThreadListRequests.remove(requestId);
      loadingThreads = _pendingThreadListRequests.isNotEmpty;
      error = 'Unable to request Codex threads: $e';
      serviceState = 'disconnected';
      notifyListeners();
    }
  }

  Future<void> loadHistory(String threadId, {bool reset = true}) async {
    if (threadId.isEmpty || _loadingHistory.contains(threadId)) return;
    final cursor = reset ? '' : nextCursorFor(threadId);
    if (!reset && cursor.isEmpty) return;

    if (reset) {
      _history[threadId] = [];
      _nextCursors.remove(threadId);
    }
    _threadErrors.remove(threadId);
    _loadingHistory.add(threadId);
    final requestId = _nextRequestId('history');
    _historyResetByRequest[requestId] = reset;
    _historyThreadByRequest[requestId] = threadId;
    notifyListeners();

    try {
      await _commandSender(
        'codex-thread-history',
        jsonEncode({
          'request_id': requestId,
          'thread_id': threadId,
          'cursor': cursor,
          'limit': historyPageSize,
        }),
      );
    } catch (e) {
      _historyResetByRequest.remove(requestId);
      _historyThreadByRequest.remove(requestId);
      _loadingHistory.remove(threadId);
      _threadErrors[threadId] = 'Unable to request Codex history: $e';
      notifyListeners();
    }
  }

  Future<void> selectThread(String threadId) async {
    if (threadId.isEmpty) return;
    final previous = _subscribedThreadId;
    selectedThreadId = threadId;
    notifyListeners();

    if (previous != null && previous != threadId) {
      await _setSubscription(previous, false);
    }
    if (_subscribedThreadId != threadId) {
      if (await _setSubscription(threadId, true)) {
        _subscribedThreadId = threadId;
      }
    }
    await loadApprovals(threadId);
    await loadHistory(threadId, reset: true);
  }

  Future<void> loadApprovals(String threadId) async {
    if (threadId.isEmpty) return;
    final requestId = _nextRequestId('approvals');
    try {
      await _commandSender(
        'codex-list-approvals',
        jsonEncode({'request_id': requestId, 'thread_id': threadId}),
      );
    } catch (e) {
      _setControlError(
        threadId,
        'Unable to refresh Codex approvals: $e',
      );
    }
  }

  Future<void> resumeThread(String threadId) async {
    if (threadId.isEmpty || isControlPending(threadId)) return;
    if (!canResumeThread) {
      _setControlError(threadId, 'Native Codex resume is unavailable.');
      return;
    }
    await _sendControl(
      'codex-resume-thread',
      _PendingCodexControl(action: 'resume_thread', threadId: threadId),
      {'thread_id': threadId},
    );
  }

  Future<void> startThread({String workspaceThreadId = ''}) async {
    if (isStartingThread) return;
    if (!canStartThread) {
      _setControlError('', 'Starting a Codex task is unavailable.');
      return;
    }
    await _sendControl(
      'codex-start-thread',
      _PendingCodexControl(
        action: 'start_thread',
        threadId: '',
        workspaceThreadId: workspaceThreadId,
      ),
      {'workspace_thread_id': workspaceThreadId},
    );
  }

  Future<void> send(String threadId, String text) async {
    final trimmed = text.trim();
    if (threadId.isEmpty || trimmed.isEmpty || isControlPending(threadId)) {
      return;
    }
    if (needsNativeResume(threadId)) {
      _setControlError(
          threadId, 'Resume this Codex task natively before sending.');
      return;
    }
    if (!canStartTurn) {
      _setControlError(threadId, 'Starting a Codex turn is unavailable.');
      return;
    }
    if (activeTurnIdFor(threadId).isNotEmpty || isTurnStarting(threadId)) {
      _setControlError(threadId, 'This Codex task already has an active turn.');
      return;
    }
    await _sendControl(
      'codex-start-turn',
      _PendingCodexControl(action: 'start_turn', threadId: threadId),
      {'thread_id': threadId, 'text': trimmed},
    );
  }

  Future<void> steer(String threadId, String text) async {
    final trimmed = text.trim();
    final turnId = activeTurnIdFor(threadId);
    if (threadId.isEmpty ||
        turnId.isEmpty ||
        trimmed.isEmpty ||
        isControlPending(threadId)) return;
    if (!canSteerTurn) {
      _setControlError(
          threadId, 'Steering the active Codex turn is unavailable.');
      return;
    }
    await _sendControl(
      'codex-steer-turn',
      _PendingCodexControl(action: 'steer_turn', threadId: threadId),
      {'thread_id': threadId, 'turn_id': turnId, 'text': trimmed},
    );
  }

  Future<void> interrupt(String threadId) async {
    final turnId = activeTurnIdFor(threadId);
    if (threadId.isEmpty || turnId.isEmpty || isControlPending(threadId)) {
      return;
    }
    if (!canInterruptTurn) {
      _setControlError(
          threadId, 'Interrupting the active Codex turn is unavailable.');
      return;
    }
    await _sendControl(
      'codex-interrupt-turn',
      _PendingCodexControl(action: 'interrupt_turn', threadId: threadId),
      {'thread_id': threadId, 'turn_id': turnId},
    );
  }

  Future<void> respondToApproval(CodexApproval approval, bool approve) async {
    if (approval.id.isEmpty || isApprovalPending(approval.id)) {
      return;
    }
    final current = approvalsFor(approval.threadId)
        .where((candidate) => candidate.id == approval.id)
        .toList(growable: false);
    if (current.isEmpty) {
      _setControlError(
          approval.threadId, 'This Codex approval is no longer active.');
      return;
    }
    final authoritative = current.single;
    if (authoritative.turnId != approval.turnId ||
        authoritative.itemId != approval.itemId) {
      _setControlError(approval.threadId,
          'This Codex approval has changed; refresh it first.');
      return;
    }
    if (!authoritative.actionable) {
      _setControlError(
          approval.threadId, 'This Codex approval is no longer actionable.');
      return;
    }
    if (!canRespondToApprovals) {
      _setControlError(
          approval.threadId, 'Remote Codex approvals are unavailable.');
      return;
    }
    await _sendControl(
      'codex-respond-approval',
      _PendingCodexControl(
        action: 'respond_approval',
        threadId: authoritative.threadId,
        approvalId: authoritative.id,
      ),
      {
        'approval_id': authoritative.id,
        'thread_id': authoritative.threadId,
        'turn_id': authoritative.turnId,
        'decision': approve ? 'approve' : 'deny',
      },
    );
  }

  void leaveThread(String threadId) {
    if (selectedThreadId == threadId) {
      selectedThreadId = null;
    }
    if (_subscribedThreadId == threadId) {
      _subscribedThreadId = null;
      unawaited(_setSubscription(threadId, false));
    }
    notifyListeners();
  }

  void handleResponse(Map<String, dynamic> event) {
    switch (_asString(event['type'])) {
      case 'thread_list':
        _applyThreadList(event);
        break;
      case 'thread_history':
        _applyThreadHistory(event);
        break;
      case 'event':
        _applyEvent(event);
        break;
      case 'approval':
        _applyApproval(event['approval']);
        break;
      case 'approval_list':
        _applyApprovalList(event);
        break;
      case 'approval_resolved':
        _removeApproval(
            _asString(event['thread_id']), _asString(event['approval_id']));
        notifyListeners();
        break;
      case 'error':
        _applyError(event);
        break;
    }
  }

  void handleControlResponse(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    final pending = _pendingControlRequests.remove(requestId);
    final type = _asString(event['type']);
    final responseThreadId = _asString(event['thread_id']);
    final threadId = responseThreadId.isNotEmpty
        ? responseThreadId
        : (pending?.threadId ?? '');

    if (type == 'error') {
      final message = _asString(event['message']);
      _setControlError(
          threadId, message.isEmpty ? 'Codex control failed.' : message,
          notify: false);
      if (pending?.action == 'respond_approval' && threadId.isNotEmpty) {
        unawaited(loadApprovals(threadId));
      }
      notifyListeners();
      return;
    }
    if (type != 'result') {
      notifyListeners();
      return;
    }

    final action = _asString(event['action']);
    final turnId = _asString(event['turn_id']);
    final state = _asString(event['state']);
    if (threadId.isNotEmpty) {
      _threadErrors.remove(threadId);
      if (state.isNotEmpty) _updateThreadState(threadId, state);
    } else {
      error = '';
    }

    switch (action) {
      case 'thread_started':
        if (threadId.isNotEmpty) {
          lastStartedThreadId = threadId;
          if (!threads.any((thread) => thread.id == threadId)) {
            final workspaceThreadId = pending?.workspaceThreadId ?? '';
            final workspace = threads.where(
              (thread) => thread.id == workspaceThreadId,
            );
            final source = workspace.isEmpty ? null : workspace.first;
            threads = [
              CodexThread(
                id: threadId,
                title: 'New Codex task',
                project: source?.project ?? '',
                originator: '',
                updatedAt: DateTime.now().millisecondsSinceEpoch,
                state: state.isEmpty ? 'idle' : state,
              ),
              ...threads,
            ];
          }
        }
        break;
      case 'turn_started':
        if (threadId.isNotEmpty && turnId.isNotEmpty) {
          if (_activeTurnIds[threadId] != turnId) {
            _startingTurnIds[threadId] = turnId;
          }
        }
        break;
      case 'turn_steered':
        if (threadId.isNotEmpty && turnId.isNotEmpty) {
          _activeTurnIds[threadId] = turnId;
        }
        break;
      case 'turn_interrupted':
        break;
      case 'thread_resumed':
        if (threadId.isNotEmpty) {
          _startingTurnIds.remove(threadId);
          if (turnId.isNotEmpty) {
            _activeTurnIds[threadId] = turnId;
          } else {
            _activeTurnIds.remove(threadId);
          }
        }
        break;
      case 'approval_approved':
      case 'approval_denied':
        if (pending?.approvalId.isNotEmpty ?? false) {
          _removeApproval(threadId, pending!.approvalId);
        }
        break;
      case 'unknown':
        break;
    }
    notifyListeners();
  }

  void reset() {
    threads = const [];
    serviceState = 'unavailable';
    codexVersion = '';
    error = '';
    lastStartedThreadId = '';
    selectedThreadId = null;
    _subscribedThreadId = null;
    loadingThreads = false;
    _history.clear();
    _nextCursors.clear();
    _threadErrors.clear();
    _loadingHistory.clear();
    _pendingThreadListRequests.clear();
    _historyResetByRequest.clear();
    _historyThreadByRequest.clear();
    _activeTurnIds.clear();
    _startingTurnIds.clear();
    _pendingControlRequests.clear();
    _approvals.clear();
    canResumeThread = false;
    canStartThread = false;
    canStartTurn = false;
    canSteerTurn = false;
    canInterruptTurn = false;
    canRespondToApprovals = false;
    notifyListeners();
  }

  void _applyThreadList(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    _pendingThreadListRequests.remove(requestId);
    loadingThreads = _pendingThreadListRequests.isNotEmpty;
    serviceState = _asString(event['service_state']);
    codexVersion = _asString(event['codex_version']);
    final rawControl = event['control'];
    if (rawControl is Map) {
      canResumeThread = _asBool(rawControl['resume_thread']);
      canStartThread = _asBool(rawControl['start_thread']);
      canStartTurn = _asBool(rawControl['start_turn']);
      canSteerTurn = _asBool(rawControl['steer_turn']);
      canInterruptTurn = _asBool(rawControl['interrupt_turn']);
      canRespondToApprovals = _asBool(rawControl['approvals']);
    } else {
      canResumeThread = false;
      canStartThread = false;
      canStartTurn = false;
      canSteerTurn = false;
      canInterruptTurn = false;
      canRespondToApprovals = false;
    }
    final rawThreads = event['threads'];
    threads = rawThreads is List
        ? rawThreads
            .whereType<Map>()
            .map((thread) => CodexThread.fromJson(
                thread.map((key, value) => MapEntry(key.toString(), value))))
            .where((thread) => thread.id.isNotEmpty)
            .toList(growable: false)
        : const [];
    error = '';
    notifyListeners();
  }

  void _applyApproval(dynamic rawApproval) {
    if (rawApproval is! Map) return;
    final approval = CodexApproval.fromJson(
      rawApproval.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (approval.id.isEmpty || approval.threadId.isEmpty) return;
    final approvals = List<CodexApproval>.from(
      _approvals[approval.threadId] ?? const [],
    );
    final index =
        approvals.indexWhere((candidate) => candidate.id == approval.id);
    if (index >= 0) {
      approvals[index] = approval;
    } else {
      approvals.add(approval);
    }
    approvals.sort((a, b) => a.startedAtMs.compareTo(b.startedAtMs));
    _approvals[approval.threadId] = approvals;
    _updateThreadState(approval.threadId, 'waiting_for_approval');
    notifyListeners();
  }

  void _applyApprovalList(Map<String, dynamic> event) {
    final threadId = _asString(event['thread_id']);
    if (threadId.isEmpty) return;
    final rawApprovals = event['approvals'];
    final approvals = rawApprovals is List
        ? rawApprovals
            .whereType<Map>()
            .map((approval) => CodexApproval.fromJson(
                  approval.map((key, value) => MapEntry(key.toString(), value)),
                ))
            .where((approval) => approval.id.isNotEmpty)
            .toList(growable: false)
        : const <CodexApproval>[];
    _approvals[threadId] = approvals;
    notifyListeners();
  }

  void _removeApproval(String threadId, String approvalId) {
    if (threadId.isEmpty || approvalId.isEmpty) return;
    final current = _approvals[threadId];
    if (current == null) return;
    final next =
        current.where((approval) => approval.id != approvalId).toList();
    if (next.isEmpty) {
      _approvals.remove(threadId);
    } else {
      _approvals[threadId] = next;
    }
  }

  void _applyThreadHistory(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    final threadId = _asString(event['thread_id']);
    final reset = _historyResetByRequest.remove(requestId) ?? false;
    _historyThreadByRequest.remove(requestId);
    _loadingHistory.remove(threadId);
    _threadErrors.remove(threadId);

    final rawItems = event['items'];
    final incoming = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((item) => CodexHistoryItem.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value))))
            .toList(growable: false)
        : const <CodexHistoryItem>[];
    final existing = _history[threadId] ?? const <CodexHistoryItem>[];
    _history[threadId] = _mergeHistory(incoming, existing);
    if (reset && incoming.isEmpty && existing.isEmpty) {
      _history[threadId] = [];
    }
    _nextCursors[threadId] = _asString(event['next_cursor']);
    notifyListeners();
  }

  void _applyEvent(Map<String, dynamic> event) {
    final threadId = _asString(event['thread_id']);
    if (threadId.isEmpty) return;
    final kind = _asString(event['kind']);
    final state = _asString(event['state']);
    final turnId = _asString(event['turn_id']);

    if (kind == 'turn_started' && turnId.isNotEmpty) {
      _startingTurnIds.remove(threadId);
      _activeTurnIds[threadId] = turnId;
    } else if (kind == 'turn_completed') {
      final startingTurnId = _startingTurnIds[threadId];
      if (turnId.isEmpty || startingTurnId == turnId) {
        _startingTurnIds.remove(threadId);
      }
      final activeTurnId = _activeTurnIds[threadId];
      if (turnId.isEmpty || activeTurnId == turnId) {
        _activeTurnIds.remove(threadId);
      }
      final currentApprovals = _approvals[threadId];
      if (currentApprovals != null) {
        final remaining = currentApprovals
            .where((approval) => turnId.isEmpty || approval.turnId != turnId)
            .toList(growable: false);
        if (remaining.isEmpty) {
          _approvals.remove(threadId);
        } else {
          _approvals[threadId] = remaining;
        }
      }
    }

    if (state.isNotEmpty && state != 'unavailable') {
      _updateThreadState(threadId, state);
      if (state == 'disconnected') serviceState = 'disconnected';
    }

    final itemId = _asString(event['item_id']);
    final historyKind = _asString(event['history_kind']);
    if (itemId.isNotEmpty &&
        historyKind.isNotEmpty &&
        historyKind != 'unknown') {
      _applyLiveItem(threadId, kind, historyKind, event);
    }
    notifyListeners();
  }

  void _applyError(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    final threadId = _asString(event['thread_id']);
    final message = _asString(event['message']);

    if (_pendingThreadListRequests.remove(requestId)) {
      loadingThreads = _pendingThreadListRequests.isNotEmpty;
    }
    final pendingThread = _historyThreadByRequest.remove(requestId);
    _historyResetByRequest.remove(requestId);
    if (pendingThread != null) {
      _loadingHistory.remove(pendingThread);
    }

    if (threadId.isNotEmpty) {
      _threadErrors[threadId] = message;
    } else {
      error = message;
    }
    notifyListeners();
  }

  void _applyLiveItem(String threadId, String eventKind, String historyKind,
      Map<String, dynamic> event) {
    final items = _history.putIfAbsent(threadId, () => []);
    final itemId = _asString(event['item_id']);
    final turnId = _asString(event['turn_id']);
    final text = _asString(event['text']);
    final status = _asString(event['status']);
    final index = items.indexWhere((item) => item.id == itemId);

    if (index < 0) {
      items.add(CodexHistoryItem(
        id: itemId,
        turnId: turnId,
        kind: historyKind,
        text: text,
        detail: '',
        status: status,
      ));
      return;
    }

    final current = items[index];
    final nextText = eventKind == 'item_updated'
        ? current.text + text
        : (text.isNotEmpty ? text : current.text);
    items[index] = current.copyWith(
      kind: historyKind,
      text: nextText,
      status: status.isNotEmpty ? status : current.status,
    );
  }

  void _updateThreadState(String threadId, String state) {
    final index = threads.indexWhere((thread) => thread.id == threadId);
    if (index < 0) return;
    final updated = List<CodexThread>.from(threads);
    updated[index] = updated[index].copyWith(state: state);
    threads = updated;
  }

  List<CodexHistoryItem> _mergeHistory(
      List<CodexHistoryItem> incoming, List<CodexHistoryItem> existing) {
    final merged = <CodexHistoryItem>[];
    final positions = <String, int>{};
    for (final item in [...incoming, ...existing]) {
      if (item.id.isEmpty) {
        merged.add(item);
        continue;
      }
      final position = positions[item.id];
      if (position == null) {
        positions[item.id] = merged.length;
        merged.add(item);
      } else {
        merged[position] = item;
      }
    }
    return merged;
  }

  Future<bool> _setSubscription(String threadId, bool subscribe) async {
    final requestId = _nextRequestId(subscribe ? 'subscribe' : 'unsubscribe');
    try {
      await _commandSender(
        'codex-event-subscription',
        jsonEncode({
          'request_id': requestId,
          'thread_id': threadId,
          'subscribe': subscribe,
        }),
      );
      return true;
    } catch (e) {
      error = 'Unable to update Codex live events: $e';
      notifyListeners();
      return false;
    }
  }

  String _nextRequestId(String operation) =>
      'codex-$operation-${++_requestSerial}';

  Future<void> _sendControl(
    String key,
    _PendingCodexControl pending,
    Map<String, dynamic> payload,
  ) async {
    final requestId = _nextRequestId(pending.action);
    _pendingControlRequests[requestId] = pending;
    if (pending.threadId.isNotEmpty) {
      _threadErrors.remove(pending.threadId);
    } else {
      error = '';
    }
    notifyListeners();
    try {
      await _commandSender(
        key,
        jsonEncode({'request_id': requestId, ...payload}),
      );
    } catch (e) {
      _pendingControlRequests.remove(requestId);
      _setControlError(
        pending.threadId,
        'Unable to send Codex control request: $e',
        notify: false,
      );
      if (pending.action == 'respond_approval' && pending.threadId.isNotEmpty) {
        unawaited(loadApprovals(pending.threadId));
      }
      notifyListeners();
    }
  }

  void _setControlError(String threadId, String message, {bool notify = true}) {
    if (threadId.isNotEmpty) {
      _threadErrors[threadId] = message;
    } else {
      error = message;
    }
    if (notify) notifyListeners();
  }
}

String _asString(dynamic value) => value?.toString() ?? '';

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _asBool(dynamic value) {
  if (value is bool) return value;
  return value?.toString().toLowerCase() == 'true';
}
