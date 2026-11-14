import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'platform_model.dart';
import 'remote_operation_state.dart';
import 'task_notification_policy.dart';

typedef CodexCommandSender = Future<void> Function(String key, String value);

String _emptyNotificationRuntimeId() => '';

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

class CodexWorkspace {
  const CodexWorkspace({
    required this.id,
    required this.name,
    required this.path,
    required this.accessible,
    required this.status,
  });

  final String id;
  final String name;
  final String path;
  final bool accessible;
  final String status;

  factory CodexWorkspace.fromJson(Map<String, dynamic> json) => CodexWorkspace(
        id: _asString(json['id']),
        name: _asString(json['name']),
        path: _asString(json['path']),
        accessible: _asBool(json['accessible']),
        status: _asString(json['status']),
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
    required this.workingDirectory,
    required this.scope,
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
  final String workingDirectory;
  final String scope;
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
        workingDirectory: _asString(json['working_directory']),
        scope: _asString(json['scope']),
        startedAtMs: _asInt(json['started_at_ms']),
        actionable: _asBool(json['actionable']),
      );
}

class CodexQueuedInstruction {
  const CodexQueuedInstruction({
    required this.text,
    required this.queuedBehindTurnId,
    required this.operationId,
  });

  final String text;
  final String queuedBehindTurnId;
  final String operationId;
}

class CodexTaskChange {
  const CodexTaskChange({
    required this.id,
    required this.artifactId,
    required this.path,
    required this.kind,
    required this.binary,
    required this.large,
    required this.sizeBytes,
    required this.diffAvailable,
    required this.fallbackReason,
  });

  final String id;
  final String artifactId;
  final String path;
  final String kind;
  final bool binary;
  final bool large;
  final int sizeBytes;
  final bool diffAvailable;
  final String fallbackReason;

  factory CodexTaskChange.fromJson(Map<String, dynamic> json) =>
      CodexTaskChange(
        id: _asString(json['change_id']),
        artifactId: _asString(json['artifact_id']),
        path: _asString(json['path']),
        kind: _asString(json['kind']),
        binary: _asBool(json['binary']),
        large: _asBool(json['large']),
        sizeBytes: _asInt(json['size_bytes']),
        diffAvailable: _asBool(json['diff_available']),
        fallbackReason: _asString(json['fallback_reason']),
      );
}

class CodexArtifact {
  const CodexArtifact({
    required this.id,
    required this.path,
    required this.sizeBytes,
    required this.binary,
    required this.large,
    required this.readable,
    required this.fallbackReason,
  });

  final String id;
  final String path;
  final int sizeBytes;
  final bool binary;
  final bool large;
  final bool readable;
  final String fallbackReason;

  factory CodexArtifact.fromJson(Map<String, dynamic> json) => CodexArtifact(
        id: _asString(json['artifact_id']),
        path: _asString(json['path']),
        sizeBytes: _asInt(json['size_bytes']),
        binary: _asBool(json['binary']),
        large: _asBool(json['large']),
        readable: _asBool(json['readable']),
        fallbackReason: _asString(json['fallback_reason']),
      );
}

class CodexReviewText {
  const CodexReviewText({
    required this.id,
    required this.text,
    required this.nextOffset,
    required this.complete,
    required this.fallbackReason,
  });

  final String id;
  final String text;
  final int nextOffset;
  final bool complete;
  final String fallbackReason;
}

class _PendingCodexReviewRequest {
  const _PendingCodexReviewRequest({
    required this.kind,
    required this.threadId,
    required this.sessionIdentity,
    required this.generation,
    this.itemId = '',
    this.reset = true,
  });

  final String kind;
  final String threadId;
  final String sessionIdentity;
  final int generation;
  final String itemId;
  final bool reset;
}

class _PendingCodexControl {
  const _PendingCodexControl({
    required this.action,
    required this.threadId,
    this.targetIdentity = '',
    this.workspaceId = '',
    this.workspaceThreadId = '',
    this.approvalId = '',
    this.text = '',
    this.operationId = '',
    this.sessionIdentity = '',
    this.generation = 0,
  });

  final String action;
  final String threadId;
  final String targetIdentity;
  final String workspaceId;
  final String workspaceThreadId;
  final String approvalId;
  final String text;
  final String operationId;
  final String sessionIdentity;
  final int generation;
}

class _RetryableCodexSubmission {
  const _RetryableCodexSubmission({
    required this.key,
    required this.pending,
    required this.payload,
  });

  final String key;
  final _PendingCodexControl pending;
  final Map<String, dynamic> payload;
}

class CodexModel with ChangeNotifier {
  CodexModel(
    this.sessionId, {
    CodexCommandSender? commandSender,
    Duration controlTimeout = const Duration(seconds: 20),
    Duration? reviewTimeout,
    bool taskNotificationsEnabled = false,
    bool hideSensitiveNotificationContent = true,
    Iterable<String> seenNotificationEventIds = const <String>[],
    String Function()? notificationRuntimeIdProvider,
    TaskNotificationSender? notificationSender,
    TaskNotificationPermissionRequester? notificationPermissionRequester,
    TaskNotificationSettingsSaver? notificationSettingsSaver,
  })  : _controlTimeout = controlTimeout,
        _reviewTimeout = reviewTimeout ?? controlTimeout,
        _notificationRuntimeIdProvider =
            notificationRuntimeIdProvider ?? _emptyNotificationRuntimeId,
        _notificationSender = notificationSender,
        _notificationPermissionRequester = notificationPermissionRequester,
        _notificationSettingsSaver = notificationSettingsSaver,
        _taskNotificationPolicy = TaskNotificationPolicy(
          enabled: taskNotificationsEnabled,
          hideSensitiveContent: hideSensitiveNotificationContent,
          seenEventIds: seenNotificationEventIds,
        ),
        _commandSender = commandSender ??
            ((key, value) => bind.sessionSetCommon(
                  sessionId: sessionId,
                  key: key,
                  value: value,
                ));

  static const int historyPageSize = 50;
  static const int _maxReviewListPageItems = 100;
  static const int _maxTaskChangesPerThread = 500;
  static const int _maxArtifactsPerThread = 1000;
  static const int _maxReviewTextPageBytes = 32 * 1024;
  static const int _maxTaskDiffBytes = 4 * 1024 * 1024;
  static const int _maxArtifactPreviewBytes = 1024 * 1024;
  static const int _maxCachedTaskDiffs = 4;
  static const int _maxCachedArtifactPreviews = 8;
  static const int _maxStartedQueueOperations = 256;

  final UuidValue sessionId;
  final CodexCommandSender _commandSender;
  final Duration _controlTimeout;
  final Duration _reviewTimeout;
  final String Function() _notificationRuntimeIdProvider;
  final TaskNotificationSender? _notificationSender;
  final TaskNotificationPermissionRequester? _notificationPermissionRequester;
  final TaskNotificationSettingsSaver? _notificationSettingsSaver;
  final TaskNotificationPolicy _taskNotificationPolicy;
  Future<void> _notificationPersistence = Future<void>.value();
  int _notificationPreferenceRevision = 0;

  final Map<String, List<CodexHistoryItem>> _history = {};
  final Map<String, String> _nextCursors = {};
  final Map<String, String> _threadErrors = {};
  final Set<String> _loadingHistory = {};
  final Set<String> _pendingThreadListRequests = {};
  final Set<String> _pendingWorkspaceListRequests = {};
  final Map<String, bool> _workspaceResetByRequest = {};
  final Map<String, bool> _historyResetByRequest = {};
  final Map<String, String> _historyThreadByRequest = {};
  final Map<String, String> _activeTurnIds = {};
  final Map<String, String> _startingTurnIds = {};
  final Map<String, _PendingCodexControl> _pendingControlRequests = {};
  final Map<String, Timer> _controlTimeouts = {};
  final Map<String, RemoteOperationState> _operationStates = {};
  final Map<String, Completer<RemoteOperationState>> _operationCompleters = {};
  final Map<String, Completer<bool>> _windowsAppHandoffCompleters = {};
  final Map<String, List<CodexApproval>> _approvals = {};
  final Map<String, List<CodexQueuedInstruction>> _queuedInstructions = {};
  final Set<String> _startedQueuedOperationIds = {};
  final Map<String, _RetryableCodexSubmission> _retryableSubmissions = {};
  final Map<String, String> _drafts = {};
  final Map<String, List<CodexTaskChange>> _taskChanges = {};
  final Map<String, String> _taskChangeCursors = {};
  final Map<String, List<CodexArtifact>> _artifacts = {};
  final Map<String, String> _artifactCursors = {};
  final Map<String, CodexReviewText> _taskDiffs = {};
  final List<String> _taskDiffCacheOrder = [];
  final Map<String, CodexReviewText> _artifactPreviews = {};
  final List<String> _artifactPreviewCacheOrder = [];
  final Map<String, String> _reviewErrors = {};
  final Map<String, String> _reviewRetryKinds = {};
  final Map<String, String> _reviewRetryItems = {};
  final Map<String, _PendingCodexReviewRequest> _pendingReviewRequests = {};
  final Map<String, Timer> _reviewTimeouts = {};
  final Set<String> _retiredReviewRequestIds = {};
  final Set<String> _loadingTaskChanges = {};
  final Set<String> _loadingArtifacts = {};
  final Set<String> _loadingTaskDiffs = {};
  final Set<String> _loadingArtifactPreviews = {};

  List<CodexThread> threads = const [];
  List<CodexWorkspace> workspaces = const [];
  String serviceState = 'unavailable';
  String codexVersion = '';
  String error = '';
  String lastStartedThreadId = '';
  String? selectedThreadId;
  String? _subscribedThreadId;
  bool loadingThreads = false;
  bool loadingWorkspaces = false;
  bool supportsWorkspaces = false;
  String workspaceError = '';
  String nextWorkspaceCursor = '';
  bool canResumeThread = false;
  bool canStartThread = false;
  bool canStartTurn = false;
  bool canSteerTurn = false;
  bool canQueueTurn = false;
  bool canInterruptTurn = false;
  bool canRespondToApprovals = false;
  bool supportsReview = false;
  RemoteCapabilitySet _mutationCapabilities =
      RemoteCapabilitySet.fromWire(null);
  String _operationSessionIdentity = '';
  int _operationGeneration = 0;
  int _requestSerial = 0;
  bool notificationSettingsPending = false;
  String notificationSettingsError = '';

  bool get taskNotificationsEnabled => _taskNotificationPolicy.enabled;
  bool get hideSensitiveNotificationContent =>
      _taskNotificationPolicy.hideSensitiveContent;
  bool get taskNotificationsSupported =>
      _notificationSender != null && _notificationPermissionRequester != null;

  Future<bool> setTaskNotificationsEnabled(bool enabled) async {
    if (notificationSettingsPending) return taskNotificationsEnabled;
    if (!enabled) {
      _notificationPreferenceRevision++;
      _taskNotificationPolicy.enabled = false;
      notificationSettingsError = '';
      await _persistTaskNotificationSettings();
      notifyListeners();
      return true;
    }
    if (!taskNotificationsSupported) {
      notificationSettingsError = 'Task alerts are unavailable on this device.';
      notifyListeners();
      return false;
    }

    notificationSettingsPending = true;
    final requestRevision = ++_notificationPreferenceRevision;
    notificationSettingsError = '';
    notifyListeners();
    var granted = false;
    try {
      granted = await _notificationPermissionRequester!();
    } catch (_) {
      granted = false;
    }
    if (requestRevision != _notificationPreferenceRevision) {
      notificationSettingsPending = false;
      notifyListeners();
      return taskNotificationsEnabled;
    }
    _taskNotificationPolicy.enabled = granted;
    notificationSettingsPending = false;
    if (!granted) {
      notificationSettingsError =
          'Notification permission was not granted. Codex still works in the app.';
    }
    await _persistTaskNotificationSettings();
    notifyListeners();
    return granted;
  }

  Future<void> setHideSensitiveNotificationContent(bool hide) async {
    if (_taskNotificationPolicy.hideSensitiveContent == hide) return;
    _notificationPreferenceRevision++;
    _taskNotificationPolicy.hideSensitiveContent = hide;
    await _persistTaskNotificationSettings();
    notifyListeners();
  }

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

  bool get canStartInWorkspace => canStartThread && supportsWorkspaces;

  List<CodexApproval> approvalsFor(String threadId) =>
      List.unmodifiable(_approvals[threadId] ?? const []);

  List<CodexQueuedInstruction> queuedInstructionsFor(String threadId) =>
      List.unmodifiable(_queuedInstructions[threadId] ?? const []);

  String draftFor(String threadId) => _drafts[threadId] ?? '';

  List<CodexTaskChange> taskChangesFor(String threadId) =>
      List.unmodifiable(_taskChanges[threadId] ?? const []);

  String nextTaskChangeCursorFor(String threadId) =>
      _taskChangeCursors[threadId] ?? '';

  List<CodexArtifact> artifactsFor(String threadId) =>
      List.unmodifiable(_artifacts[threadId] ?? const []);

  String nextArtifactCursorFor(String threadId) =>
      _artifactCursors[threadId] ?? '';

  CodexReviewText? taskDiffFor(String changeId) => _taskDiffs[changeId];

  CodexReviewText? artifactPreviewFor(String artifactId) =>
      _artifactPreviews[artifactId];

  String reviewErrorFor(String threadId) => _reviewErrors[threadId] ?? '';

  Future<void> retryReviewFailure(String threadId) async {
    final kind = _reviewRetryKinds[threadId];
    final itemId = _reviewRetryItems[threadId] ?? '';
    switch (kind) {
      case 'changes':
        await loadTaskChanges(threadId);
        break;
      case 'artifacts':
        await loadArtifacts(threadId);
        break;
      case 'diff':
        if (itemId.isNotEmpty) await loadTaskDiff(threadId, itemId);
        break;
      case 'artifact':
        if (itemId.isNotEmpty) await loadArtifactPreview(threadId, itemId);
        break;
    }
  }

  bool isTaskChangesLoading(String threadId) =>
      _loadingTaskChanges.contains(threadId);

  bool isArtifactsLoading(String threadId) =>
      _loadingArtifacts.contains(threadId);

  bool isTaskDiffLoading(String changeId) =>
      _loadingTaskDiffs.contains(changeId);

  bool isArtifactPreviewLoading(String artifactId) =>
      _loadingArtifactPreviews.contains(artifactId);

  void updateDraft(String threadId, String text) {
    if (threadId.isEmpty) return;
    if (text.isEmpty) {
      _drafts.remove(threadId);
    } else {
      _drafts[threadId] = text;
    }
  }

  bool isApprovalPending(String approvalId) => _pendingControlRequests.values
      .any((pending) => pending.approvalId == approvalId);

  RemoteOperationState? operationState(String operationId) =>
      _operationStates[operationId];

  Future<RemoteOperationState> waitForOperation(String operationId) {
    final current = _operationStates[operationId];
    if (current != null && current != RemoteOperationState.pending) {
      return Future.value(current);
    }
    return _operationCompleters
        .putIfAbsent(operationId, () => Completer<RemoteOperationState>())
        .future;
  }

  bool isWindowsAppHandoffPending(String threadId) =>
      _pendingControlRequests.values.any((pending) =>
          pending.action == 'open_windows_app' && pending.threadId == threadId);

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
      canStartInWorkspace ||
      canStartTurn ||
      canSteerTurn ||
      canQueueTurn ||
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

  Future<void> listWorkspaces({bool reset = true}) async {
    if (!supportsWorkspaces) {
      if (reset) {
        workspaces = const [];
        nextWorkspaceCursor = '';
      }
      workspaceError = 'Workspace selection is unavailable on this host.';
      notifyListeners();
      return;
    }
    if (loadingWorkspaces) return;
    final cursor = reset ? '' : nextWorkspaceCursor;
    if (!reset && cursor.isEmpty) return;

    final requestId = _nextRequestId('workspaces');
    _pendingWorkspaceListRequests.add(requestId);
    _workspaceResetByRequest[requestId] = reset;
    loadingWorkspaces = true;
    workspaceError = '';
    if (reset) {
      workspaces = const [];
      nextWorkspaceCursor = '';
    }
    notifyListeners();

    try {
      await _commandSender(
        'codex-list-workspaces',
        jsonEncode({
          'request_id': requestId,
          'cursor': cursor,
          'limit': historyPageSize,
        }),
      );
    } catch (e) {
      _pendingWorkspaceListRequests.remove(requestId);
      _workspaceResetByRequest.remove(requestId);
      loadingWorkspaces = _pendingWorkspaceListRequests.isNotEmpty;
      workspaceError = 'Unable to request Codex workspaces: $e';
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

  Future<void> loadTaskChanges(String threadId, {bool reset = true}) async {
    if (threadId.isEmpty || _loadingTaskChanges.contains(threadId)) return;
    if (!supportsReview) {
      _setReviewFailure(
          threadId, 'changes', '', 'Codex review is unavailable on this host.');
      notifyListeners();
      return;
    }
    final cursor = reset ? '' : nextTaskChangeCursorFor(threadId);
    if (!reset && cursor.isEmpty) return;
    final requestId = _nextRequestId('task-changes');
    _pendingReviewRequests[requestId] = _PendingCodexReviewRequest(
      kind: 'changes',
      threadId: threadId,
      sessionIdentity: _operationSessionIdentity,
      generation: _operationGeneration,
      reset: reset,
    );
    _armReviewTimeout(requestId);
    _loadingTaskChanges.add(threadId);
    _clearReviewFailure(threadId, kind: 'changes');
    if (reset) {
      _taskChanges[threadId] = [];
      _taskChangeCursors.remove(threadId);
    }
    notifyListeners();
    try {
      await _commandSender(
        'codex-list-task-changes',
        jsonEncode({
          'request_id': requestId,
          'thread_id': threadId,
          'cursor': cursor,
          'limit': 25,
        }),
      );
    } catch (e) {
      _failPendingReviewRequest(requestId, 'Unable to load Codex changes: $e');
    }
  }

  Future<void> loadArtifacts(String threadId, {bool reset = true}) async {
    if (threadId.isEmpty || _loadingArtifacts.contains(threadId)) return;
    if (!supportsReview) {
      _setReviewFailure(threadId, 'artifacts', '',
          'Codex artifacts are unavailable on this host.');
      notifyListeners();
      return;
    }
    final cursor = reset ? '' : nextArtifactCursorFor(threadId);
    if (!reset && cursor.isEmpty) return;
    final requestId = _nextRequestId('artifacts');
    _pendingReviewRequests[requestId] = _PendingCodexReviewRequest(
      kind: 'artifacts',
      threadId: threadId,
      sessionIdentity: _operationSessionIdentity,
      generation: _operationGeneration,
      reset: reset,
    );
    _armReviewTimeout(requestId);
    _loadingArtifacts.add(threadId);
    _clearReviewFailure(threadId, kind: 'artifacts');
    if (reset) {
      _artifacts[threadId] = [];
      _artifactCursors.remove(threadId);
    }
    notifyListeners();
    try {
      await _commandSender(
        'codex-list-artifacts',
        jsonEncode({
          'request_id': requestId,
          'thread_id': threadId,
          'cursor': cursor,
          'limit': 25,
        }),
      );
    } catch (e) {
      _failPendingReviewRequest(
          requestId, 'Unable to load Codex artifacts: $e');
    }
  }

  Future<void> loadTaskDiff(String threadId, String changeId,
      {bool reset = true}) async {
    if (threadId.isEmpty ||
        changeId.isEmpty ||
        _loadingTaskDiffs.contains(changeId)) return;
    if (!supportsReview) return;
    final knownChange = (_taskChanges[threadId] ?? const <CodexTaskChange>[])
        .any((change) => change.id == changeId);
    if (!knownChange) {
      _setReviewFailure(
        threadId,
        'changes',
        '',
        'Refresh Codex changes before opening this diff.',
      );
      notifyListeners();
      return;
    }
    final current = _taskDiffs[changeId];
    if (!reset && (current == null || current.complete)) return;
    final offset = reset ? 0 : current!.nextOffset;
    final requestId = _nextRequestId('task-diff');
    _pendingReviewRequests[requestId] = _PendingCodexReviewRequest(
      kind: 'diff',
      threadId: threadId,
      itemId: changeId,
      sessionIdentity: _operationSessionIdentity,
      generation: _operationGeneration,
      reset: reset,
    );
    _armReviewTimeout(requestId);
    _loadingTaskDiffs.add(changeId);
    _clearReviewFailure(threadId, kind: 'diff', itemId: changeId);
    if (reset) {
      _taskDiffs.remove(changeId);
      _taskDiffCacheOrder.remove(changeId);
    }
    notifyListeners();
    try {
      await _commandSender(
        'codex-read-task-diff',
        jsonEncode({
          'request_id': requestId,
          'thread_id': threadId,
          'change_id': changeId,
          'offset': offset,
          'limit': 16 * 1024,
        }),
      );
    } catch (e) {
      _failPendingReviewRequest(requestId, 'Unable to read Codex diff: $e');
    }
  }

  Future<void> loadArtifactPreview(String threadId, String artifactId,
      {bool reset = true}) async {
    if (threadId.isEmpty ||
        artifactId.isEmpty ||
        _loadingArtifactPreviews.contains(artifactId)) return;
    if (!supportsReview) return;
    final knownArtifact = (_artifacts[threadId] ?? const <CodexArtifact>[])
        .any((artifact) => artifact.id == artifactId);
    if (!knownArtifact) {
      _setReviewFailure(
        threadId,
        'artifacts',
        '',
        'Refresh Codex artifacts before opening this preview.',
      );
      notifyListeners();
      return;
    }
    final current = _artifactPreviews[artifactId];
    if (!reset && (current == null || current.complete)) return;
    final offset = reset ? 0 : current!.nextOffset;
    final requestId = _nextRequestId('artifact');
    _pendingReviewRequests[requestId] = _PendingCodexReviewRequest(
      kind: 'artifact',
      threadId: threadId,
      itemId: artifactId,
      sessionIdentity: _operationSessionIdentity,
      generation: _operationGeneration,
      reset: reset,
    );
    _armReviewTimeout(requestId);
    _loadingArtifactPreviews.add(artifactId);
    _clearReviewFailure(threadId, kind: 'artifact', itemId: artifactId);
    if (reset) {
      _artifactPreviews.remove(artifactId);
      _artifactPreviewCacheOrder.remove(artifactId);
    }
    notifyListeners();
    try {
      await _commandSender(
        'codex-read-artifact',
        jsonEncode({
          'request_id': requestId,
          'thread_id': threadId,
          'artifact_id': artifactId,
          'offset': offset,
          'limit': 16 * 1024,
        }),
      );
    } catch (e) {
      _failPendingReviewRequest(requestId, 'Unable to read Codex artifact: $e');
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
    await loadHistory(threadId, reset: true);
    if (needsNativeResume(threadId)) return;
    await _attachThread(threadId);
  }

  Future<void> _attachThread(String threadId) async {
    if (selectedThreadId != threadId) return;
    if (_subscribedThreadId != threadId) {
      if (await _setSubscription(threadId, true)) {
        _subscribedThreadId = threadId;
      }
    }
    await loadApprovals(threadId);
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
    final operationId = await _resumeThreadOperation(threadId);
    if (operationId == null) return;
    final outcome = await waitForOperation(operationId);
    if (outcome != RemoteOperationState.applied) return;
    await _attachThread(threadId);
  }

  Future<String?> _resumeThreadOperation(String threadId) async {
    if (threadId.isEmpty || isControlPending(threadId)) return null;
    if (!canResumeThread) {
      _setControlError(threadId, 'Native Codex resume is unavailable.');
      return null;
    }
    return _sendControl(
      'codex-resume-thread',
      _PendingCodexControl(
        action: 'resume_thread',
        threadId: threadId,
        targetIdentity: 'thread:$threadId',
      ),
      {'thread_id': threadId},
    );
  }

  Future<void> startThread({required String workspaceId}) async {
    if (isStartingThread) return;
    if (!canStartInWorkspace) {
      _setControlError('', 'Starting a Codex task is unavailable.');
      return;
    }
    final matches =
        workspaces.where((workspace) => workspace.id == workspaceId);
    if (workspaceId.isEmpty || matches.isEmpty || !matches.first.accessible) {
      workspaceError = 'Choose an available host workspace.';
      notifyListeners();
      return;
    }
    await _sendControl(
      'codex-start-thread',
      _PendingCodexControl(
        action: 'start_thread',
        threadId: '',
        targetIdentity: 'workspace:$workspaceId',
        workspaceId: workspaceId,
      ),
      {'workspace_id': workspaceId},
    );
  }

  Future<String?> send(String threadId, String text) async {
    final trimmed = text.trim();
    if (threadId.isEmpty || trimmed.isEmpty || isControlPending(threadId)) {
      return null;
    }
    if (needsNativeResume(threadId)) {
      _setControlError(
          threadId, 'Resume this Codex task natively before sending.');
      return null;
    }
    if (!canStartTurn) {
      _setControlError(threadId, 'Starting a Codex turn is unavailable.');
      return null;
    }
    final retryable = _retryableSubmissions[threadId];
    if (retryable != null) {
      final originalText = _asString(retryable.payload['text']).trim();
      if (retryable.pending.action != 'start_turn' || originalText != trimmed) {
        _setControlError(
          threadId,
          'The previous Codex submission has an unknown outcome. Retry the exact submitted text or refresh before sending a different instruction.',
        );
        return null;
      }
      if (retryable.pending.sessionIdentity != _operationSessionIdentity ||
          retryable.pending.generation != _operationGeneration) {
        _setControlError(
          threadId,
          'The connection changed while this Codex submission was uncertain. Refresh the task to reconcile it before retrying.',
        );
        return null;
      }
      return _sendControl(
        retryable.key,
        retryable.pending,
        retryable.payload,
        operationId: retryable.pending.operationId,
      );
    }
    if (activeTurnIdFor(threadId).isNotEmpty || isTurnStarting(threadId)) {
      _setControlError(threadId, 'This Codex task already has an active turn.');
      return null;
    }
    return _sendControl(
      'codex-start-turn',
      _PendingCodexControl(
        action: 'start_turn',
        threadId: threadId,
        targetIdentity: 'thread:$threadId/turn:new',
        text: trimmed,
      ),
      {'thread_id': threadId, 'text': trimmed},
    );
  }

  Future<String?> steer(String threadId, String text) async {
    final trimmed = text.trim();
    final turnId = activeTurnIdFor(threadId);
    if (threadId.isEmpty ||
        turnId.isEmpty ||
        trimmed.isEmpty ||
        isControlPending(threadId)) return null;
    if (!canSteerTurn) {
      _setControlError(
          threadId, 'Steering the active Codex turn is unavailable.');
      return null;
    }
    final retryable = _retryableSubmissions[threadId];
    if (retryable != null) {
      final originalText = _asString(retryable.payload['text']).trim();
      if (retryable.pending.action != 'steer_turn' || originalText != trimmed) {
        _setControlError(
          threadId,
          'The previous Codex submission has an unknown outcome. Retry the exact submitted text or refresh before sending a different instruction.',
        );
        return null;
      }
      if (retryable.pending.sessionIdentity != _operationSessionIdentity ||
          retryable.pending.generation != _operationGeneration) {
        _setControlError(
          threadId,
          'The connection changed while this Codex submission was uncertain. Refresh the task to reconcile it before retrying.',
        );
        return null;
      }
      return _sendControl(
        retryable.key,
        retryable.pending,
        retryable.payload,
        operationId: retryable.pending.operationId,
      );
    }
    return _sendControl(
      'codex-steer-turn',
      _PendingCodexControl(
        action: 'steer_turn',
        threadId: threadId,
        targetIdentity: 'thread:$threadId/turn:$turnId',
        text: trimmed,
      ),
      {'thread_id': threadId, 'turn_id': turnId, 'text': trimmed},
    );
  }

  Future<String?> queue(String threadId, String text) async {
    final trimmed = text.trim();
    final turnId = activeTurnIdFor(threadId);
    if (threadId.isEmpty ||
        turnId.isEmpty ||
        trimmed.isEmpty ||
        isControlPending(threadId)) return null;
    if (!canQueueTurn) {
      _setControlError(
          threadId, 'Queueing the next Codex instruction is unavailable.');
      return null;
    }
    final retryable = _retryableSubmissions[threadId];
    if (retryable != null) {
      final originalText = _asString(retryable.payload['text']).trim();
      final originalTurnId = _asString(retryable.payload['turn_id']);
      if (retryable.pending.action != 'queue_turn' ||
          originalText != trimmed ||
          originalTurnId != turnId) {
        _setControlError(
          threadId,
          'The previous Codex queue request has an unknown outcome. Retry the exact queued instruction on the same turn or refresh before changing it.',
        );
        return null;
      }
      if (retryable.pending.sessionIdentity != _operationSessionIdentity ||
          retryable.pending.generation != _operationGeneration) {
        _setControlError(
          threadId,
          'The connection changed while this Codex queue request was uncertain. Refresh the task before retrying.',
        );
        return null;
      }
      return _sendControl(
        retryable.key,
        retryable.pending,
        retryable.payload,
        operationId: retryable.pending.operationId,
      );
    }
    return _sendControl(
      'codex-queue-turn',
      _PendingCodexControl(
        action: 'queue_turn',
        threadId: threadId,
        targetIdentity: 'thread:$threadId/turn:$turnId/queue',
        text: trimmed,
      ),
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
      _PendingCodexControl(
        action: 'interrupt_turn',
        threadId: threadId,
        targetIdentity: 'thread:$threadId/turn:$turnId',
      ),
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
        targetIdentity: 'approval:${authoritative.id}'
            '/thread:${authoritative.threadId}'
            '/turn:${authoritative.turnId}'
            '/item:${authoritative.itemId}'
            '/decision:${approve ? 'approve' : 'deny'}',
        approvalId: authoritative.id,
      ),
      {
        'approval_id': authoritative.id,
        'thread_id': authoritative.threadId,
        'turn_id': authoritative.turnId,
        'item_id': authoritative.itemId,
        'decision': approve ? 'approve' : 'deny',
      },
    );
  }

  Future<bool> openWindowsApp([String threadId = '']) async {
    if (isWindowsAppHandoffPending(threadId)) return false;

    final requestId = _nextRequestId('open_windows_app');
    final pending =
        _PendingCodexControl(action: 'open_windows_app', threadId: threadId);
    final completer = Completer<bool>();
    _pendingControlRequests[requestId] = pending;
    _windowsAppHandoffCompleters[requestId] = completer;
    if (threadId.isNotEmpty) {
      _threadErrors.remove(threadId);
    } else {
      error = '';
    }
    notifyListeners();

    try {
      await _commandSender(
        'codex-open-windows-app',
        jsonEncode({'request_id': requestId, 'thread_id': threadId}),
      );
    } catch (e) {
      _pendingControlRequests.remove(requestId);
      _windowsAppHandoffCompleters.remove(requestId);
      _setControlError(
        threadId,
        'Unable to open the Windows Codex app: $e',
        notify: false,
      );
      if (!completer.isCompleted) completer.complete(false);
      notifyListeners();
    }

    return completer.future;
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
      case 'workspace_list':
        _applyWorkspaceList(event);
        break;
      case 'thread_history':
        _applyThreadHistory(event);
        break;
      case 'task_change_list':
        _applyTaskChangeList(event);
        break;
      case 'task_diff':
        _applyReviewText(event, artifact: false);
        break;
      case 'artifact_list':
        _applyArtifactList(event);
        break;
      case 'artifact':
        _applyReviewText(event, artifact: true);
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
    final pending = _pendingControlRequests[requestId];
    if (pending == null) return;
    final type = _asString(event['type']);
    if (type != 'result' && type != 'error') return;

    if (pending.operationId.isNotEmpty) {
      final generation = _asInt(event['session_generation']);
      final metadataMatches =
          _asString(event['operation_id']) == pending.operationId &&
              _asString(event['session_identity']) == pending.sessionIdentity &&
              _asString(event['target_identity']) == pending.targetIdentity &&
              generation == pending.generation &&
              pending.sessionIdentity == _operationSessionIdentity &&
              pending.generation == _operationGeneration;
      if (!metadataMatches) return;

      final accepted = _asBool(event['accepted']);
      final applied = _asBool(event['applied']);
      if ((type == 'result' && (!accepted || !applied)) ||
          (type == 'error' && applied)) {
        return;
      }
      _completeOperation(
        pending.operationId,
        type == 'result'
            ? RemoteOperationState.applied
            : RemoteOperationState.failed,
      );
    }

    _pendingControlRequests.remove(requestId);
    _controlTimeouts.remove(requestId)?.cancel();
    final handoffCompleter = _windowsAppHandoffCompleters.remove(requestId);
    final responseThreadId = _asString(event['thread_id']);
    final threadId =
        responseThreadId.isNotEmpty ? responseThreadId : pending.threadId;

    if (type == 'error') {
      final errorCode = _asString(event['error_code']);
      final rawMessage = _asString(event['message']);
      final message = rawMessage.isEmpty
          ? (errorCode.isEmpty ? 'Codex control failed.' : errorCode)
          : rawMessage;
      _setControlError(
        threadId,
        message,
        notify: false,
      );
      if (pending.action == 'respond_approval' && threadId.isNotEmpty) {
        unawaited(loadApprovals(threadId));
      }
      if (handoffCompleter != null && !handoffCompleter.isCompleted) {
        handoffCompleter.complete(false);
      }
      notifyListeners();
      return;
    }

    final action = _asString(event['action']);
    final turnId = _asString(event['turn_id']);
    final state = _asString(event['state']);
    final queueStartedBeforeAck = action == 'turn_queued' &&
        pending.operationId.isNotEmpty &&
        _startedQueuedOperationIds.contains(pending.operationId);
    if (threadId.isNotEmpty &&
        pending.text.isNotEmpty &&
        (pending.action == 'start_turn' ||
            pending.action == 'steer_turn' ||
            pending.action == 'queue_turn')) {
      final draft = _drafts[threadId];
      if (draft != null && draft.trim() == pending.text) {
        _drafts.remove(threadId);
      }
    }
    if (threadId.isNotEmpty) {
      _threadErrors.remove(threadId);
      if (state.isNotEmpty && !queueStartedBeforeAck) {
        _updateThreadState(threadId, state);
      }
    } else {
      error = '';
    }

    switch (action) {
      case 'thread_started':
        if (threadId.isNotEmpty) {
          lastStartedThreadId = threadId;
          workspaceError = '';
          if (!threads.any((thread) => thread.id == threadId)) {
            final workspaceId = pending.workspaceId;
            final workspace = workspaces.where(
              (item) => item.id == workspaceId,
            );
            final source = workspace.isEmpty ? null : workspace.first;
            threads = [
              CodexThread(
                id: threadId,
                title: 'New Codex task',
                project: source?.name ?? '',
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
      case 'turn_queued':
        if (threadId.isNotEmpty &&
            turnId.isNotEmpty &&
            pending.text.isNotEmpty) {
          final startedBeforeAck =
              _startedQueuedOperationIds.remove(pending.operationId);
          if (!startedBeforeAck) {
            _queuedInstructions.putIfAbsent(threadId, () => []).add(
                  CodexQueuedInstruction(
                    text: pending.text,
                    queuedBehindTurnId: turnId,
                    operationId: pending.operationId,
                  ),
                );
          }
        }
        break;
      case 'turn_interrupted':
        if (threadId.isNotEmpty) _queuedInstructions.remove(threadId);
        break;
      case 'thread_resumed':
        if (threadId.isNotEmpty) {
          _startingTurnIds.remove(threadId);
          if (turnId.isNotEmpty) {
            _activeTurnIds[threadId] = turnId;
          } else {
            _activeTurnIds.remove(threadId);
          }
          if (_mutationCapabilities.allows('codex.queue.reconcile.v1')) {
            final rawQueuedOperations = event['queued_operation_ids'];
            final queuedOperationIds = rawQueuedOperations is List
                ? rawQueuedOperations
                    .map(_asString)
                    .where((id) => id.isNotEmpty)
                    .toList(growable: false)
                : const <String>[];
            _reconcileQueuedInstructions(threadId, queuedOperationIds);
          }
        }
        break;
      case 'approval_approved':
      case 'approval_denied':
        if (pending.approvalId.isNotEmpty) {
          _removeApproval(threadId, pending.approvalId);
        }
        break;
      case 'windows_app_opened':
        break;
      case 'unknown':
        break;
    }
    if (handoffCompleter != null && !handoffCompleter.isCompleted) {
      handoffCompleter.complete(action == 'windows_app_opened');
    }
    notifyListeners();
  }

  void reset() {
    _markScopedPendingUnknown(
        'The connection changed before the Codex request was confirmed. Refresh before retrying.');
    for (final timer in _controlTimeouts.values) {
      timer.cancel();
    }
    _controlTimeouts.clear();
    threads = const [];
    workspaces = const [];
    serviceState = 'unavailable';
    codexVersion = '';
    error = '';
    lastStartedThreadId = '';
    selectedThreadId = null;
    _subscribedThreadId = null;
    loadingThreads = false;
    loadingWorkspaces = false;
    supportsWorkspaces = false;
    workspaceError = '';
    nextWorkspaceCursor = '';
    _history.clear();
    _nextCursors.clear();
    _threadErrors.clear();
    _loadingHistory.clear();
    _pendingThreadListRequests.clear();
    _pendingWorkspaceListRequests.clear();
    _workspaceResetByRequest.clear();
    _historyResetByRequest.clear();
    _historyThreadByRequest.clear();
    _activeTurnIds.clear();
    _startingTurnIds.clear();
    _queuedInstructions.clear();
    _startedQueuedOperationIds.clear();
    _clearReviewState();
    _pendingControlRequests.clear();
    for (final completer in _windowsAppHandoffCompleters.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _windowsAppHandoffCompleters.clear();
    _approvals.clear();
    canResumeThread = false;
    canStartThread = false;
    canStartTurn = false;
    canSteerTurn = false;
    canQueueTurn = false;
    canInterruptTurn = false;
    canRespondToApprovals = false;
    supportsReview = false;
    _mutationCapabilities = RemoteCapabilitySet.fromWire(null);
    _operationSessionIdentity = '';
    _operationGeneration = 0;
    notifyListeners();
  }

  void _applyThreadList(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    _pendingThreadListRequests.remove(requestId);
    loadingThreads = _pendingThreadListRequests.isNotEmpty;
    serviceState = _asString(event['service_state']);
    codexVersion = _asString(event['codex_version']);
    final nextOperationIdentity =
        _asString(event['operation_session_identity']);
    final nextOperationGeneration = _asInt(event['operation_generation']);
    final sessionChanged = _operationSessionIdentity.isNotEmpty &&
        (nextOperationIdentity != _operationSessionIdentity ||
            nextOperationGeneration != _operationGeneration);
    if (sessionChanged) {
      _markScopedPendingUnknown(
          'The Codex session changed before the request was confirmed. Refresh before retrying.');
      _activeTurnIds.clear();
      _startingTurnIds.clear();
      _queuedInstructions.clear();
      _startedQueuedOperationIds.clear();
      _approvals.clear();
      _clearReviewState();
    }
    _mutationCapabilities = RemoteCapabilitySet.fromWire(event['capabilities']);
    supportsWorkspaces = _mutationCapabilities.allows('codex.workspaces.v1');
    supportsReview = _mutationCapabilities.allows('codex.review.v1') &&
        nextOperationIdentity.isNotEmpty &&
        nextOperationGeneration > 0;
    if (!supportsWorkspaces) {
      workspaces = const [];
      nextWorkspaceCursor = '';
      loadingWorkspaces = false;
      _pendingWorkspaceListRequests.clear();
      _workspaceResetByRequest.clear();
    }
    if (!supportsReview) _clearReviewState();
    _operationSessionIdentity = nextOperationIdentity;
    _operationGeneration = nextOperationGeneration;
    final mutationContractReady = _operationSessionIdentity.isNotEmpty &&
        _operationGeneration > 0 &&
        _mutationCapabilities.allows('codex.operation.identity.v1') &&
        _mutationCapabilities.allows('codex.operation.ack.v1');
    final rawControl = event['control'];
    if (rawControl is Map) {
      canResumeThread =
          mutationContractReady && _asBool(rawControl['resume_thread']);
      canStartThread =
          mutationContractReady && _asBool(rawControl['start_thread']);
      canStartTurn = mutationContractReady && _asBool(rawControl['start_turn']);
      canSteerTurn = mutationContractReady && _asBool(rawControl['steer_turn']);
      canQueueTurn = mutationContractReady &&
          _mutationCapabilities.allows('codex.queue.v1') &&
          _asBool(rawControl['queue_turn']);
      canInterruptTurn =
          mutationContractReady && _asBool(rawControl['interrupt_turn']);
      canRespondToApprovals =
          mutationContractReady && _asBool(rawControl['approvals']);
    } else {
      canResumeThread = false;
      canStartThread = false;
      canStartTurn = false;
      canSteerTurn = false;
      canQueueTurn = false;
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

  void _applyWorkspaceList(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    if (!_pendingWorkspaceListRequests.remove(requestId)) return;
    final reset = _workspaceResetByRequest.remove(requestId) ?? false;
    loadingWorkspaces = _pendingWorkspaceListRequests.isNotEmpty;
    final rawWorkspaces = event['workspaces'];
    final incoming = rawWorkspaces is List
        ? rawWorkspaces
            .whereType<Map>()
            .map((workspace) => CodexWorkspace.fromJson(
                  workspace
                      .map((key, value) => MapEntry(key.toString(), value)),
                ))
            .where((workspace) => workspace.id.isNotEmpty)
            .toList(growable: false)
        : const <CodexWorkspace>[];
    if (reset) {
      workspaces = incoming;
    } else {
      final merged = <CodexWorkspace>[...workspaces];
      for (final workspace in incoming) {
        final index = merged.indexWhere((item) => item.id == workspace.id);
        if (index >= 0) {
          merged[index] = workspace;
        } else {
          merged.add(workspace);
        }
      }
      workspaces = merged;
    }
    nextWorkspaceCursor = _asString(event['next_cursor']);
    workspaceError = '';
    notifyListeners();
  }

  void _applyTaskChangeList(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    final pending = _takeReviewRequest(requestId, 'changes', event);
    if (pending == null) return;
    final rawChanges = event['changes'];
    if (rawChanges is List && rawChanges.length > _maxReviewListPageItems) {
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex returned too many review changes in one page. Retry after refreshing.',
      );
      notifyListeners();
      return;
    }
    final incoming = rawChanges is List
        ? rawChanges
            .whereType<Map>()
            .map((change) => CodexTaskChange.fromJson(
                  change.map((key, value) => MapEntry(key.toString(), value)),
                ))
            .where((change) => change.id.isNotEmpty)
            .toList(growable: false)
        : const <CodexTaskChange>[];
    final merged = pending.reset
        ? incoming
        : _mergeById<CodexTaskChange>(
            _taskChanges[pending.threadId] ?? const [],
            incoming,
            (item) => item.id,
          );
    final nextCursor = _asString(event['next_cursor']);
    final reachedLimit = merged.length > _maxTaskChangesPerThread ||
        (merged.length >= _maxTaskChangesPerThread && nextCursor.isNotEmpty);
    _taskChanges[pending.threadId] =
        merged.take(_maxTaskChangesPerThread).toList(growable: false);
    if (reachedLimit) {
      _taskChangeCursors.remove(pending.threadId);
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex review reached the safe change-list limit. Refresh after the task is smaller.',
      );
    } else {
      _taskChangeCursors[pending.threadId] = nextCursor;
      _clearReviewFailure(pending.threadId,
          kind: pending.kind, itemId: pending.itemId);
    }
    notifyListeners();
  }

  void _applyArtifactList(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    final pending = _takeReviewRequest(requestId, 'artifacts', event);
    if (pending == null) return;
    final rawArtifacts = event['artifacts'];
    if (rawArtifacts is List && rawArtifacts.length > _maxReviewListPageItems) {
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex returned too many artifacts in one page. Retry after refreshing.',
      );
      notifyListeners();
      return;
    }
    final incoming = rawArtifacts is List
        ? rawArtifacts
            .whereType<Map>()
            .map((artifact) => CodexArtifact.fromJson(
                  artifact.map((key, value) => MapEntry(key.toString(), value)),
                ))
            .where((artifact) => artifact.id.isNotEmpty)
            .toList(growable: false)
        : const <CodexArtifact>[];
    final merged = pending.reset
        ? incoming
        : _mergeById<CodexArtifact>(
            _artifacts[pending.threadId] ?? const [],
            incoming,
            (item) => item.id,
          );
    final nextCursor = _asString(event['next_cursor']);
    final reachedLimit = merged.length > _maxArtifactsPerThread ||
        (merged.length >= _maxArtifactsPerThread && nextCursor.isNotEmpty);
    _artifacts[pending.threadId] =
        merged.take(_maxArtifactsPerThread).toList(growable: false);
    if (reachedLimit) {
      _artifactCursors.remove(pending.threadId);
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex review reached the safe artifact-list limit. Refresh after the task is smaller.',
      );
    } else {
      _artifactCursors[pending.threadId] = nextCursor;
      _clearReviewFailure(pending.threadId,
          kind: pending.kind, itemId: pending.itemId);
    }
    notifyListeners();
  }

  void _applyReviewText(Map<String, dynamic> event, {required bool artifact}) {
    final requestId = _asString(event['request_id']);
    final pending = _takeReviewRequest(
      requestId,
      artifact ? 'artifact' : 'diff',
      event,
      responseItemId: _asString(event['id']),
    );
    if (pending == null) return;
    final store = artifact ? _artifactPreviews : _taskDiffs;
    final existing = store[pending.itemId];
    final expectedOffset = pending.reset ? 0 : (existing?.nextOffset ?? -1);
    final offset = _asInt(event['offset']);
    if (offset != expectedOffset) {
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex review page changed while it was loading. Refresh the preview.',
      );
      notifyListeners();
      return;
    }
    final nextOffset = _asInt(event['next_offset']);
    final complete = _asBool(event['complete']);
    final pageText = _asString(event['text']);
    final pageBytes = utf8.encode(pageText).length;
    if (pageBytes > _maxReviewTextPageBytes) {
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex review page exceeded the safe preview size. Retry the preview.',
      );
      notifyListeners();
      return;
    }
    if (nextOffset != offset + pageBytes ||
        (!complete && nextOffset <= offset)) {
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex review page byte range did not match its content. Retry the preview.',
      );
      notifyListeners();
      return;
    }
    final text = pending.reset ? pageText : '${existing?.text ?? ''}$pageText';
    final maxBytes = artifact ? _maxArtifactPreviewBytes : _maxTaskDiffBytes;
    if (utf8.encode(text).length > maxBytes) {
      _setReviewFailure(
        pending.threadId,
        pending.kind,
        pending.itemId,
        'Codex review preview exceeded the safe accumulated size. Refresh the review.',
      );
      notifyListeners();
      return;
    }
    final reviewText = CodexReviewText(
      id: pending.itemId,
      text: text,
      nextOffset: nextOffset,
      complete: complete,
      fallbackReason: _asString(event['fallback_reason']),
    );
    store[pending.itemId] = reviewText;
    if (artifact) {
      _artifactPreviewCacheOrder.remove(pending.itemId);
      _artifactPreviewCacheOrder.add(pending.itemId);
      while (_artifactPreviewCacheOrder.length > _maxCachedArtifactPreviews) {
        _artifactPreviews.remove(_artifactPreviewCacheOrder.removeAt(0));
      }
    } else {
      _taskDiffCacheOrder.remove(pending.itemId);
      _taskDiffCacheOrder.add(pending.itemId);
      while (_taskDiffCacheOrder.length > _maxCachedTaskDiffs) {
        _taskDiffs.remove(_taskDiffCacheOrder.removeAt(0));
      }
    }
    _clearReviewFailure(pending.threadId,
        kind: pending.kind, itemId: pending.itemId);
    notifyListeners();
  }

  _PendingCodexReviewRequest? _takeReviewRequest(
    String requestId,
    String expectedKind,
    Map<String, dynamic> event, {
    String? responseItemId,
  }) {
    final pending = _pendingReviewRequests[requestId];
    if (pending == null) return null;
    if (pending.kind != expectedKind) return null;
    if (!_reviewResponseMatchesScope(pending, event)) return null;
    if (responseItemId != null && responseItemId != pending.itemId) return null;
    _pendingReviewRequests.remove(requestId);
    _reviewTimeouts.remove(requestId)?.cancel();
    _finishReviewLoading(pending);
    return pending;
  }

  bool _reviewResponseMatchesScope(
      _PendingCodexReviewRequest pending, Map<String, dynamic> event) {
    return _asString(event['thread_id']) == pending.threadId &&
        pending.sessionIdentity == _operationSessionIdentity &&
        pending.generation == _operationGeneration;
  }

  void _finishReviewLoading(_PendingCodexReviewRequest pending) {
    switch (pending.kind) {
      case 'changes':
        _loadingTaskChanges.remove(pending.threadId);
        break;
      case 'artifacts':
        _loadingArtifacts.remove(pending.threadId);
        break;
      case 'diff':
        _loadingTaskDiffs.remove(pending.itemId);
        break;
      case 'artifact':
        _loadingArtifactPreviews.remove(pending.itemId);
        break;
    }
  }

  void _armReviewTimeout(String requestId) {
    _reviewTimeouts.remove(requestId)?.cancel();
    _reviewTimeouts[requestId] = Timer(_reviewTimeout, () {
      final pending = _pendingReviewRequests.remove(requestId);
      _reviewTimeouts.remove(requestId);
      if (pending == null) return;
      _finishReviewLoading(pending);
      _retireReviewRequest(requestId);
      if (pending.sessionIdentity == _operationSessionIdentity &&
          pending.generation == _operationGeneration) {
        _setReviewFailure(
          pending.threadId,
          pending.kind,
          pending.itemId,
          'Codex review request timed out. Retry to request this page again.',
        );
        notifyListeners();
      }
    });
  }

  void _failPendingReviewRequest(String requestId, String message) {
    final pending = _pendingReviewRequests.remove(requestId);
    _reviewTimeouts.remove(requestId)?.cancel();
    if (pending == null) return;
    _finishReviewLoading(pending);
    _retireReviewRequest(requestId);
    if (!_isCurrentReviewRequest(pending)) return;
    _setReviewFailure(
      pending.threadId,
      pending.kind,
      pending.itemId,
      message,
    );
    notifyListeners();
  }

  void _setReviewFailure(
      String threadId, String kind, String itemId, String message) {
    _reviewErrors[threadId] = message;
    _reviewRetryKinds[threadId] = kind;
    if (itemId.isEmpty) {
      _reviewRetryItems.remove(threadId);
    } else {
      _reviewRetryItems[threadId] = itemId;
    }
  }

  void _clearReviewFailure(
    String threadId, {
    String? kind,
    String itemId = '',
  }) {
    if (kind != null) {
      if (_reviewRetryKinds[threadId] != kind) return;
      if ((_reviewRetryItems[threadId] ?? '') != itemId) return;
    }
    _reviewErrors.remove(threadId);
    _reviewRetryKinds.remove(threadId);
    _reviewRetryItems.remove(threadId);
  }

  bool _isCurrentReviewRequest(_PendingCodexReviewRequest pending) =>
      pending.sessionIdentity == _operationSessionIdentity &&
      pending.generation == _operationGeneration;

  bool _isReviewRequestId(String requestId) =>
      requestId.startsWith('codex-task-changes-') ||
      requestId.startsWith('codex-artifacts-') ||
      requestId.startsWith('codex-task-diff-') ||
      requestId.startsWith('codex-artifact-');

  void _retireReviewRequest(String requestId) {
    if (requestId.isEmpty) return;
    _retiredReviewRequestIds.add(requestId);
    while (_retiredReviewRequestIds.length > 512) {
      _retiredReviewRequestIds.remove(_retiredReviewRequestIds.first);
    }
  }

  void _clearReviewState() {
    for (final requestId in _pendingReviewRequests.keys) {
      _retireReviewRequest(requestId);
    }
    for (final timer in _reviewTimeouts.values) {
      timer.cancel();
    }
    _reviewTimeouts.clear();
    _taskChanges.clear();
    _taskChangeCursors.clear();
    _artifacts.clear();
    _artifactCursors.clear();
    _taskDiffs.clear();
    _taskDiffCacheOrder.clear();
    _artifactPreviews.clear();
    _artifactPreviewCacheOrder.clear();
    _reviewErrors.clear();
    _reviewRetryKinds.clear();
    _reviewRetryItems.clear();
    _pendingReviewRequests.clear();
    _loadingTaskChanges.clear();
    _loadingArtifacts.clear();
    _loadingTaskDiffs.clear();
    _loadingArtifactPreviews.clear();
  }

  List<T> _mergeById<T>(
      List<T> existing, List<T> incoming, String Function(T) idOf) {
    final merged = <T>[...existing];
    for (final item in incoming) {
      final index =
          merged.indexWhere((candidate) => idOf(candidate) == idOf(item));
      if (index >= 0) {
        merged[index] = item;
      } else {
        merged.add(item);
      }
    }
    return merged;
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
    if (approval.actionable && _hasKnownThread(approval.threadId)) {
      _considerTaskNotification(
        TaskNotificationEvent(
          eventId: 'approval:${approval.id}',
          runtimeId: _notificationRuntimeIdProvider(),
          taskId: approval.threadId,
          taskTitle: _taskTitle(approval.threadId),
          type: TaskNotificationType.approval,
        ),
        live: true,
      );
    }
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
    for (final approval in approvals) {
      if (!approval.actionable) continue;
      _considerTaskNotification(
        TaskNotificationEvent(
          eventId: 'approval:${approval.id}',
          runtimeId: _notificationRuntimeIdProvider(),
          taskId: approval.threadId,
          taskTitle: _taskTitle(approval.threadId),
          type: TaskNotificationType.approval,
        ),
        live: false,
      );
    }
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
      final previousTurnId = _activeTurnIds[threadId];
      _startingTurnIds.remove(threadId);
      _activeTurnIds[threadId] = turnId;
      if (previousTurnId != turnId &&
          _asString(event['status']) == 'queuedStart') {
        final queued = _queuedInstructions[threadId];
        final operationId = _asString(event['operation_id']);
        if (operationId.isNotEmpty) {
          final index = queued?.indexWhere(
                (instruction) => instruction.operationId == operationId,
              ) ??
              -1;
          if (index >= 0) {
            queued!.removeAt(index);
            if (queued.isEmpty) _queuedInstructions.remove(threadId);
          } else {
            _rememberStartedQueueOperation(operationId);
          }
        } else if (queued != null && queued.isNotEmpty) {
          queued.removeAt(0);
          if (queued.isEmpty) _queuedInstructions.remove(threadId);
        }
      }
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
    if (kind == 'turn_completed' &&
        turnId.isNotEmpty &&
        _hasKnownThread(threadId)) {
      final status = _asString(event['status']).toLowerCase();
      final failed = state.toLowerCase() == 'failed' || status == 'failed';
      if (failed) {
        _considerTaskNotification(
          TaskNotificationEvent(
            eventId: 'failure:$threadId:$turnId',
            runtimeId: _notificationRuntimeIdProvider(),
            taskId: threadId,
            taskTitle: _taskTitle(threadId),
            type: TaskNotificationType.failure,
          ),
          live: true,
        );
      } else if (status == 'completed' ||
          status == 'success' ||
          status == 'succeeded') {
        _considerTaskNotification(
          TaskNotificationEvent(
            eventId: 'review:$threadId:$turnId',
            runtimeId: _notificationRuntimeIdProvider(),
            taskId: threadId,
            taskTitle: _taskTitle(threadId),
            type: TaskNotificationType.reviewReady,
          ),
          live: true,
        );
      }
    }
    notifyListeners();
  }

  void _applyError(Map<String, dynamic> event) {
    final requestId = _asString(event['request_id']);
    final threadId = _asString(event['thread_id']);
    final message = _asString(event['message']);
    final errorCode = _asString(event['error_code']);

    if (_retiredReviewRequestIds.contains(requestId)) return;
    final reviewRequest = _pendingReviewRequests[requestId];
    if (reviewRequest != null) {
      if (!_isCurrentReviewRequest(reviewRequest) ||
          (threadId.isNotEmpty && threadId != reviewRequest.threadId)) {
        return;
      }
      _pendingReviewRequests.remove(requestId);
      _reviewTimeouts.remove(requestId)?.cancel();
      _finishReviewLoading(reviewRequest);
      _retireReviewRequest(requestId);
      _setReviewFailure(
        reviewRequest.threadId,
        reviewRequest.kind,
        reviewRequest.itemId,
        message.isEmpty ? 'Codex review request failed.' : message,
      );
      notifyListeners();
      return;
    }
    if (_isReviewRequestId(requestId)) return;

    if (_pendingThreadListRequests.remove(requestId)) {
      loadingThreads = _pendingThreadListRequests.isNotEmpty;
    }
    final workspaceRequest = _pendingWorkspaceListRequests.remove(requestId);
    if (workspaceRequest) {
      _workspaceResetByRequest.remove(requestId);
      loadingWorkspaces = _pendingWorkspaceListRequests.isNotEmpty;
      workspaceError = message;
    }
    final pendingThread = _historyThreadByRequest.remove(requestId);
    _historyResetByRequest.remove(requestId);
    if (pendingThread != null) {
      _loadingHistory.remove(pendingThread);
    }

    if (threadId.isNotEmpty) {
      if (errorCode == 'queue_cleared') {
        _queuedInstructions.remove(threadId);
      }
      _threadErrors[threadId] = message;
    } else if (!workspaceRequest) {
      error = message;
    }
    notifyListeners();
  }

  String _taskTitle(String threadId) {
    for (final thread in threads) {
      if (thread.id == threadId) {
        return thread.title.trim().isEmpty ? 'Codex task' : thread.title.trim();
      }
    }
    return 'Codex task';
  }

  bool _hasKnownThread(String threadId) =>
      threads.any((thread) => thread.id == threadId);

  void _considerTaskNotification(
    TaskNotificationEvent event, {
    required bool live,
  }) {
    final before = _taskNotificationPolicy.encodeSeenEventIds();
    final alert = _taskNotificationPolicy.consider(event, live: live);
    if (_taskNotificationPolicy.encodeSeenEventIds() != before) {
      unawaited(_persistTaskNotificationSettings());
    }
    if (alert == null || _notificationSender == null) return;
    unawaited(_sendTaskNotification(alert, _notificationPreferenceRevision));
  }

  Future<void> _sendTaskNotification(
    TaskNotificationAlert alert,
    int preferenceRevision,
  ) async {
    var delivered = false;
    try {
      delivered = await _notificationSender!(alert);
    } catch (_) {
      delivered = false;
    }
    if (delivered || preferenceRevision != _notificationPreferenceRevision) {
      return;
    }
    _taskNotificationPolicy.enabled = false;
    notificationSettingsError =
        'Task alerts are paused. Re-enable them to request notification access again.';
    await _persistTaskNotificationSettings();
    notifyListeners();
  }

  Future<void> _persistTaskNotificationSettings() async {
    final saver = _notificationSettingsSaver;
    if (saver == null) return;
    final enabled = _taskNotificationPolicy.enabled;
    final hideSensitiveContent = _taskNotificationPolicy.hideSensitiveContent;
    final encodedSeenEventIds = _taskNotificationPolicy.encodeSeenEventIds();
    final queued = _notificationPersistence.then((_) async {
      try {
        await saver(enabled, hideSensitiveContent, encodedSeenEventIds);
      } catch (_) {
        // Persistence failure must not interrupt the in-app Codex workflow.
      }
    });
    _notificationPersistence = queued;
    await queued;
  }

  void _rememberStartedQueueOperation(String operationId) {
    if (operationId.isEmpty) return;
    _startedQueuedOperationIds.add(operationId);
    while (_startedQueuedOperationIds.length > _maxStartedQueueOperations) {
      _startedQueuedOperationIds.remove(_startedQueuedOperationIds.first);
    }
  }

  void _reconcileQueuedInstructions(
      String threadId, List<String> hostOperationIds) {
    if (hostOperationIds.isEmpty) {
      _queuedInstructions.remove(threadId);
      return;
    }
    final local =
        _queuedInstructions[threadId] ?? const <CodexQueuedInstruction>[];
    final byOperationId = <String, CodexQueuedInstruction>{
      for (final instruction in local)
        if (instruction.operationId.isNotEmpty)
          instruction.operationId: instruction,
    };
    final reconciled = <CodexQueuedInstruction>[];
    for (final operationId in hostOperationIds) {
      if (operationId.isEmpty ||
          reconciled.any((item) => item.operationId == operationId)) {
        continue;
      }
      reconciled.add(
        byOperationId[operationId] ??
            CodexQueuedInstruction(
              text: 'Queued instruction on PC · details unavailable',
              queuedBehindTurnId: '',
              operationId: operationId,
            ),
      );
    }
    if (reconciled.isEmpty) {
      _queuedInstructions.remove(threadId);
    } else {
      _queuedInstructions[threadId] = reconciled;
    }
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

  Future<String?> _sendControl(
    String key,
    _PendingCodexControl pending,
    Map<String, dynamic> payload, {
    String? operationId,
  }) async {
    final scopedOperationId = operationId ?? const Uuid().v4();
    final scopedPending = _PendingCodexControl(
      action: pending.action,
      threadId: pending.threadId,
      targetIdentity: pending.targetIdentity,
      workspaceId: pending.workspaceId,
      workspaceThreadId: pending.workspaceThreadId,
      approvalId: pending.approvalId,
      text: pending.text,
      operationId: scopedOperationId,
      sessionIdentity: _operationSessionIdentity,
      generation: _operationGeneration,
    );
    if (pending.action == 'start_turn' ||
        pending.action == 'steer_turn' ||
        pending.action == 'queue_turn') {
      _retryableSubmissions[pending.threadId] = _RetryableCodexSubmission(
        key: key,
        pending: scopedPending,
        payload: Map<String, dynamic>.unmodifiable(payload),
      );
    }
    _operationStates[scopedOperationId] = RemoteOperationState.pending;
    _operationCompleters[scopedOperationId] = Completer<RemoteOperationState>();
    if (pending.threadId.isNotEmpty) {
      _threadErrors.remove(pending.threadId);
    } else {
      error = '';
    }
    notifyListeners();

    Future<bool> dispatch({required bool reconciliation}) async {
      if (scopedPending.sessionIdentity != _operationSessionIdentity ||
          scopedPending.generation != _operationGeneration) {
        _completeOperation(
            scopedOperationId, RemoteOperationState.unknownOutcome);
        _setControlError(
          scopedPending.threadId,
          'The Codex session changed before the request was confirmed. Refresh before retrying.',
          notify: false,
        );
        notifyListeners();
        return false;
      }

      final requestId = _nextRequestId(
        reconciliation ? '${pending.action}_reconcile' : pending.action,
      );
      _pendingControlRequests[requestId] = scopedPending;
      _controlTimeouts[requestId]?.cancel();
      _controlTimeouts[requestId] = Timer(_controlTimeout, () {
        final current = _pendingControlRequests[requestId];
        if (current == null || current.operationId != scopedOperationId) return;
        _pendingControlRequests.remove(requestId);
        _controlTimeouts.remove(requestId);
        if (!reconciliation &&
            current.sessionIdentity == _operationSessionIdentity &&
            current.generation == _operationGeneration) {
          unawaited(dispatch(reconciliation: true));
          return;
        }
        _completeOperation(
            scopedOperationId, RemoteOperationState.unknownOutcome);
        _setControlError(
          current.threadId,
          'The PC may have applied this Codex request. Refresh the task before retrying.',
          notify: false,
        );
        if (current.action == 'respond_approval' &&
            current.threadId.isNotEmpty) {
          unawaited(loadApprovals(current.threadId));
        }
        notifyListeners();
      });

      try {
        await _commandSender(
          key,
          jsonEncode({
            'request_id': requestId,
            'operation_id': scopedOperationId,
            'session_identity': scopedPending.sessionIdentity,
            'target_identity': scopedPending.targetIdentity,
            'session_generation': scopedPending.generation,
            ...payload,
          }),
        );
        return true;
      } catch (e) {
        _pendingControlRequests.remove(requestId);
        _controlTimeouts.remove(requestId)?.cancel();
        _completeOperation(
          scopedOperationId,
          reconciliation
              ? RemoteOperationState.unknownOutcome
              : RemoteOperationState.failed,
        );
        _setControlError(
          pending.threadId,
          reconciliation
              ? 'The PC may have applied this Codex request. Refresh the task before retrying.'
              : 'Unable to send Codex control request: $e',
          notify: false,
        );
        if (pending.action == 'respond_approval' &&
            pending.threadId.isNotEmpty) {
          unawaited(loadApprovals(pending.threadId));
        }
        notifyListeners();
        return false;
      }
    }

    return await dispatch(reconciliation: false) ? scopedOperationId : null;
  }

  void _completeOperation(String operationId, RemoteOperationState state) {
    if (operationId.isEmpty) return;
    _operationStates[operationId] = state;
    if (state == RemoteOperationState.applied ||
        state == RemoteOperationState.failed) {
      _retryableSubmissions.removeWhere(
        (_, submission) => submission.pending.operationId == operationId,
      );
    }
    final completer = _operationCompleters.remove(operationId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(state);
    }
    if (_operationStates.length > 128) {
      final removable = _operationStates.entries
          .where((entry) => entry.value != RemoteOperationState.pending)
          .map((entry) => entry.key)
          .take(_operationStates.length - 128)
          .toList(growable: false);
      for (final key in removable) {
        _operationStates.remove(key);
      }
    }
  }

  void _markScopedPendingUnknown(String message) {
    final pendingEntries = _pendingControlRequests.entries
        .where((entry) => entry.value.operationId.isNotEmpty)
        .toList(growable: false);
    for (final entry in pendingEntries) {
      _pendingControlRequests.remove(entry.key);
      _controlTimeouts.remove(entry.key)?.cancel();
      _completeOperation(
          entry.value.operationId, RemoteOperationState.unknownOutcome);
      _setControlError(entry.value.threadId, message, notify: false);
    }
  }

  @override
  void dispose() {
    for (final timer in _controlTimeouts.values) {
      timer.cancel();
    }
    _controlTimeouts.clear();
    for (final timer in _reviewTimeouts.values) {
      timer.cancel();
    }
    _reviewTimeouts.clear();
    for (final pending in _pendingControlRequests.values) {
      if (pending.operationId.isNotEmpty) {
        _completeOperation(
            pending.operationId, RemoteOperationState.unknownOutcome);
      }
    }
    _pendingControlRequests.clear();
    super.dispose();
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
