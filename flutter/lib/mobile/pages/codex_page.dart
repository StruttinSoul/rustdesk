import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/codex_model.dart';
import '../../models/remote_operation_state.dart';
import '../widgets/codex_review_panel.dart';
import '../widgets/codex_workspace_picker.dart';

class CodexPage extends StatefulWidget {
  const CodexPage({
    super.key,
    required this.model,
    this.embedded = false,
    this.initialThreadId,
    this.onWindowsAppOpened,
  });

  final CodexModel model;
  final bool embedded;
  final String? initialThreadId;
  final VoidCallback? onWindowsAppOpened;

  @override
  State<CodexPage> createState() => _CodexPageState();
}

class _CodexPageState extends State<CodexPage> {
  String? _selectedThreadId;
  String _seenStartedThreadId = '';

  @override
  void initState() {
    super.initState();
    final initial = widget.initialThreadId?.trim() ?? '';
    if (initial.isNotEmpty) _selectedThreadId = initial;
    widget.model.addListener(_handleModelChanged);
    unawaited(widget.model.listThreads());
  }

  @override
  void didUpdateWidget(covariant CodexPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model == widget.model) return;
    oldWidget.model.removeListener(_handleModelChanged);
    widget.model.addListener(_handleModelChanged);
    final initial = widget.initialThreadId?.trim() ?? '';
    _selectedThreadId = initial.isEmpty ? null : initial;
    _seenStartedThreadId = '';
    unawaited(widget.model.listThreads());
  }

  @override
  void dispose() {
    widget.model.removeListener(_handleModelChanged);
    super.dispose();
  }

  void _handleModelChanged() {
    final started = widget.model.lastStartedThreadId;
    if (!mounted || started.isEmpty || started == _seenStartedThreadId) return;
    final match = widget.model.threads.where((thread) => thread.id == started);
    if (match.isEmpty) return;
    _seenStartedThreadId = started;
    setState(() => _selectedThreadId = match.first.id);
  }

  void _selectThread(CodexThread thread) {
    if (_selectedThreadId == thread.id) return;
    setState(() => _selectedThreadId = thread.id);
  }

  void _clearSelection() {
    if (_selectedThreadId == null) return;
    setState(() => _selectedThreadId = null);
  }

  Future<void> _openWindowsApp([String threadId = '']) async {
    final opened = await widget.model.openWindowsApp(threadId);
    if (!mounted || !opened) return;
    if (widget.onWindowsAppOpened != null) {
      widget.onWindowsAppOpened!();
      return;
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final workspace = AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          return ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: wide ? _buildWide(context) : _buildCompact(context),
          );
        },
      ),
    );
    if (widget.embedded) return workspace;
    return Scaffold(body: SafeArea(child: workspace));
  }

  Widget _buildCompact(BuildContext context) {
    final thread = _currentThread();
    if (thread != null) {
      return _CodexThreadView(
        key: ValueKey('codex-thread-${thread.id}'),
        model: widget.model,
        thread: thread,
        compact: true,
        onBack: _clearSelection,
        onOpenWindowsApp: () => _openWindowsApp(thread.id),
      );
    }
    return _TaskListPane(
      model: widget.model,
      selectedThreadId: null,
      onSelect: _selectThread,
      onOpenWindowsApp: () => _openWindowsApp(),
    );
  }

  Widget _buildWide(BuildContext context) {
    final theme = Theme.of(context);
    final thread = _currentThread();
    return Row(
      children: [
        SizedBox(
          width: 330,
          child: _TaskListPane(
            model: widget.model,
            selectedThreadId: thread?.id,
            onSelect: _selectThread,
            onOpenWindowsApp: () => _openWindowsApp(),
          ),
        ),
        VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: thread == null
              ? const _EmptyThreadPane()
              : _CodexThreadView(
                  key: ValueKey('codex-thread-${thread.id}'),
                  model: widget.model,
                  thread: thread,
                  compact: false,
                  onOpenWindowsApp: () => _openWindowsApp(thread.id),
                ),
        ),
      ],
    );
  }

  CodexThread? _currentThread() {
    final selectedId = _selectedThreadId;
    if (selectedId == null) return null;
    for (final thread in widget.model.threads) {
      if (thread.id == selectedId) return thread;
    }
    return null;
  }
}

class _TaskListPane extends StatelessWidget {
  const _TaskListPane({
    required this.model,
    required this.selectedThreadId,
    required this.onSelect,
    required this.onOpenWindowsApp,
  });

  final CodexModel model;
  final String? selectedThreadId;
  final ValueChanged<CodexThread> onSelect;
  final VoidCallback onOpenWindowsApp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = _groupThreads(model.threads);
    if (model.loadingThreads && model.threads.isEmpty) {
      return Column(
        children: [
          _TaskListHeader(model: model),
          const Expanded(child: _TaskListSkeleton()),
        ],
      );
    }
    if (model.error.isNotEmpty && model.threads.isEmpty) {
      return Column(
        children: [
          _TaskListHeader(model: model),
          Expanded(
            child: _CodexMessageState(
              icon: Icons.cloud_off_outlined,
              title: 'Codex is unavailable',
              message: model.error,
              actionLabel: 'Retry',
              onAction: () => unawaited(model.listThreads()),
              secondaryActionLabel: 'Open Windows app',
              onSecondaryAction: onOpenWindowsApp,
            ),
          ),
        ],
      );
    }

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          _TaskListHeader(model: model),
          if (model.error.isNotEmpty)
            _InlineError(
              message: model.error,
              onRetry: () => unawaited(model.listThreads()),
            ),
          Expanded(
            child: model.threads.isEmpty
                ? const _CodexMessageState(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'No tasks yet',
                    message:
                        'Start a Codex task on this PC and it will appear here.',
                  )
                : RefreshIndicator(
                    onRefresh: model.listThreads,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
                      children: [
                        for (final group in groups) ...[
                          _TaskGroupHeader(
                            label: group.label,
                            count: group.threads.length,
                          ),
                          for (final thread in group.threads)
                            _TaskRow(
                              thread: thread,
                              selected: selectedThreadId == thread.id,
                              onTap: () => onSelect(thread),
                            ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TaskGroup {
  const _TaskGroup(this.label, this.threads);

  final String label;
  final List<CodexThread> threads;
}

List<_TaskGroup> _groupThreads(List<CodexThread> threads) {
  final needsYou = <CodexThread>[];
  final running = <CodexThread>[];
  final review = <CodexThread>[];
  final desktopHistory = <CodexThread>[];

  for (final thread in threads) {
    final state = thread.state.toLowerCase();
    final originator = thread.originator.toLowerCase().replaceAll('_', ' ');
    final desktopImported =
        state == 'resumable' && originator.contains('codex desktop');
    if (desktopImported) {
      desktopHistory.add(thread);
    } else if (state == 'waiting_for_approval' ||
        state == 'waiting_for_input') {
      needsYou.add(thread);
    } else if (state == 'working' ||
        state == 'starting' ||
        state == 'interrupting') {
      running.add(thread);
    } else {
      review.add(thread);
    }
  }

  void sortNewestFirst(List<CodexThread> items) {
    items.sort((a, b) {
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      return byUpdated != 0 ? byUpdated : a.id.compareTo(b.id);
    });
  }

  for (final items in [needsYou, running, review, desktopHistory]) {
    sortNewestFirst(items);
  }

  return [
    if (needsYou.isNotEmpty) _TaskGroup('Needs you', needsYou),
    if (running.isNotEmpty) _TaskGroup('Running', running),
    if (review.isNotEmpty) _TaskGroup('Review', review),
    if (desktopHistory.isNotEmpty)
      _TaskGroup('Desktop history', desktopHistory),
  ];
}

class _TaskGroupHeader extends StatelessWidget {
  const _TaskGroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskListHeader extends StatelessWidget {
  const _TaskListHeader({required this.model});

  final CodexModel model;

  Future<void> _handleAlertAction(BuildContext context, String action) async {
    if (action == 'toggle') {
      final enabling = !model.taskNotificationsEnabled;
      final ok = await model.setTaskNotificationsEnabled(enabling);
      if (!context.mounted || !enabling || ok) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            model.notificationSettingsError.isEmpty
                ? 'Task alerts could not be enabled.'
                : model.notificationSettingsError,
          ),
        ),
      );
      return;
    }
    if (action == 'privacy') {
      await model.setHideSensitiveNotificationContent(
        !model.hideSensitiveNotificationContent,
      );
    }
  }

  Future<void> _chooseWorkspace(BuildContext context) async {
    if (!model.canStartInWorkspace) return;
    await model.listWorkspaces();
    if (!context.mounted) return;
    final workspace = await showModalBottomSheet<CodexWorkspace>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (sheetContext) => CodexWorkspacePicker(
        model: model,
        onSelected: (workspace) => Navigator.of(sheetContext).pop(workspace),
      ),
    );
    if (workspace == null) return;
    await model.startThread(workspaceId: workspace.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = model.codexVersion.isEmpty ? '' : model.codexVersion;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.code_rounded,
                  size: 18,
                  color: theme.colorScheme.surface,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Codex',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Row(
                      children: [
                        _ServiceDot(state: model.serviceState),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            [
                              _stateLabel(model.serviceState),
                              if (version.isNotEmpty) version,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Task alerts',
                enabled: !model.notificationSettingsPending,
                icon: model.notificationSettingsPending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        model.taskNotificationsEnabled
                            ? Icons.notifications_active_outlined
                            : Icons.notifications_none_outlined,
                      ),
                onSelected: (action) =>
                    unawaited(_handleAlertAction(context, action)),
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    value: 'toggle',
                    enabled: model.taskNotificationsSupported,
                    child: Row(
                      children: [
                        Icon(
                          model.taskNotificationsEnabled
                              ? Icons.check_circle_outline
                              : Icons.notifications_outlined,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(model.taskNotificationsEnabled
                              ? 'Disable task alerts'
                              : model.taskNotificationsSupported
                                  ? 'Enable task alerts'
                                  : 'Task alerts unavailable'),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'privacy',
                    child: Row(
                      children: [
                        Icon(
                          model.hideSensitiveNotificationContent
                              ? Icons.lock_outline
                              : Icons.lock_open_outlined,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            model.hideSensitiveNotificationContent
                                ? 'Task names hidden on lock screen'
                                : 'Task names visible in alerts',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    enabled: false,
                    child: Text(
                      'Alerts are generated while this remote session is connected. Android may stop them after the app process is closed.',
                    ),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'Refresh tasks',
                onPressed: model.loadingThreads
                    ? null
                    : () => unawaited(model.listThreads()),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (model.canStartThread) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: model.isStartingThread || !model.canStartInWorkspace
                    ? null
                    : () => unawaited(_chooseWorkspace(context)),
                icon: model.isStartingThread
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded, size: 19),
                label: const Text('New task'),
              ),
            ),
            if (!model.supportsWorkspaces) ...[
              const SizedBox(height: 6),
              Text(
                'Workspace selection is unavailable on this host.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
          if (!model.hasInteractiveControl && model.isReady) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.visibility_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Read only',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
          if (model.notificationSettingsError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              model.notificationSettingsError,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.thread,
    required this.selected,
    required this.onTap,
  });

  final CodexThread thread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      if (thread.project.isNotEmpty) thread.project,
      if (thread.updatedAt > 0) _formatTimestamp(thread.updatedAt),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? theme.colorScheme.surfaceContainerHigh
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    _stateIcon(thread.state),
                    size: 17,
                    color: _stateColor(theme, thread.state),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        thread.title.isEmpty ? 'Untitled task' : thread.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CodexThreadView extends StatefulWidget {
  const _CodexThreadView({
    super.key,
    required this.model,
    required this.thread,
    required this.compact,
    required this.onOpenWindowsApp,
    this.onBack,
  });

  final CodexModel model;
  final CodexThread thread;
  final bool compact;
  final VoidCallback onOpenWindowsApp;
  final VoidCallback? onBack;

  @override
  State<_CodexThreadView> createState() => _CodexThreadViewState();
}

class _CodexThreadViewState extends State<_CodexThreadView> {
  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _composerController;
  int _lastVisibleItemCount = 0;
  bool _showReview = false;

  @override
  void initState() {
    super.initState();
    _composerController = TextEditingController(
      text: widget.model.draftFor(widget.thread.id),
    );
    _composerController.addListener(_onComposerChanged);
    widget.model.addListener(_onModelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.model.selectThread(widget.thread.id));
    });
  }

  @override
  void didUpdateWidget(covariant _CodexThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_onModelChanged);
      widget.model.addListener(_onModelChanged);
      _syncComposerDraft();
    }
    if (oldWidget.thread.id != widget.thread.id) {
      _showReview = false;
      _leaveThreadAfterFrame(oldWidget.model, oldWidget.thread.id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.model.selectThread(widget.thread.id));
      });
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    _leaveThreadAfterFrame(widget.model, widget.thread.id);
    _composerController.removeListener(_onComposerChanged);
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    _syncComposerDraft();
    final count = widget.model.historyFor(widget.thread.id).length +
        widget.model.approvalsFor(widget.thread.id).length;
    if (count == _lastVisibleItemCount) return;
    final followTail = !_scrollController.hasClients ||
        _scrollController.position.extentAfter < 180;
    _lastVisibleItemCount = count;
    if (!followTail) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _onComposerChanged() {
    widget.model.updateDraft(widget.thread.id, _composerController.text);
  }

  void _syncComposerDraft() {
    final draft = widget.model.draftFor(widget.thread.id);
    if (_composerController.text == draft) return;
    _composerController.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
  }

  void _setReviewMode(bool showReview) {
    if (_showReview == showReview) return;
    setState(() => _showReview = showReview);
    if (!showReview) return;
    unawaited(widget.model.loadTaskChanges(widget.thread.id));
    unawaited(widget.model.loadArtifacts(widget.thread.id));
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final thread = model.threads.firstWhere(
      (candidate) => candidate.id == widget.thread.id,
      orElse: () => widget.thread,
    );
    final error = model.errorFor(thread.id);
    final showingReview = _showReview && model.supportsReview;
    return Column(
      children: [
        _ThreadHeader(
          thread: thread,
          compact: widget.compact,
          onBack: widget.onBack,
          readOnly: !model.hasInteractiveControl,
        ),
        if (model.supportsReview)
          _ThreadModeBar(
            showingReview: showingReview,
            onConversation: () => _setReviewMode(false),
            onReview: () => _setReviewMode(true),
          ),
        if (error.isNotEmpty)
          _InlineError(
            message: error,
            onRetry: () => unawaited(model.loadHistory(thread.id)),
          ),
        Expanded(
          child: showingReview
              ? CodexReviewPanel(model: model, threadId: thread.id)
              : _buildTimeline(context, thread),
        ),
        if (!showingReview)
          _Composer(
            model: model,
            thread: thread,
            controller: _composerController,
            onOpenWindowsApp: widget.onOpenWindowsApp,
          ),
      ],
    );
  }

  Widget _buildTimeline(BuildContext context, CodexThread thread) {
    final model = widget.model;
    final items = model.historyFor(thread.id);
    final approvals = model.approvalsFor(thread.id);
    final loading = model.isHistoryLoading(thread.id);
    final hasOlder = model.nextCursorFor(thread.id).isNotEmpty;

    if (loading && items.isEmpty && approvals.isEmpty) {
      return const _TimelineSkeleton();
    }

    if (items.isEmpty && approvals.isEmpty) {
      return const _CodexMessageState(
        icon: Icons.notes_rounded,
        title: 'Ready for the next instruction',
        message: 'Send a message below to continue this Codex task.',
      );
    }

    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        widget.compact ? 14 : 24,
        16,
        widget.compact ? 14 : 24,
        16,
      ),
      children: [
        if (hasOlder)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextButton.icon(
                onPressed: loading
                    ? null
                    : () => unawaited(
                          model.loadHistory(thread.id, reset: false),
                        ),
                icon: loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_less_rounded),
                label: const Text('Load older activity'),
              ),
            ),
          ),
        for (final item in items) _ActivityRow(item: item),
        for (final approval in approvals)
          _ApprovalInline(model: model, approval: approval),
        const SizedBox(height: 10),
      ],
    );
  }
}

void _leaveThreadAfterFrame(CodexModel model, String threadId) {
  WidgetsBinding.instance
      .addPostFrameCallback((_) => model.leaveThread(threadId));
}

class CodexThreadPage extends StatelessWidget {
  const CodexThreadPage({
    super.key,
    required this.model,
    required this.thread,
  });

  final CodexModel model;
  final CodexThread thread;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: _CodexThreadView(
            model: model,
            thread: thread,
            compact: true,
            onBack: () => Navigator.of(context).pop(),
            onOpenWindowsApp: () async {
              final opened = await model.openWindowsApp(thread.id);
              if (context.mounted && opened) Navigator.of(context).pop(true);
            },
          ),
        ),
      );
}

class _ThreadModeBar extends StatelessWidget {
  const _ThreadModeBar({
    required this.showingReview,
    required this.onConversation,
    required this.onReview,
  });

  final bool showingReview;
  final VoidCallback onConversation;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ThreadModeButton(
              key: const ValueKey('codex-conversation-tab'),
              label: 'Conversation',
              icon: Icons.chat_bubble_outline_rounded,
              selected: !showingReview,
              onTap: onConversation,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ThreadModeButton(
              key: const ValueKey('codex-review-tab'),
              label: 'Review',
              icon: Icons.difference_outlined,
              selected: showingReview,
              onTap: onReview,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadModeButton extends StatelessWidget {
  const _ThreadModeButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Material(
          color: selected
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 17),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({
    required this.thread,
    required this.compact,
    required this.readOnly,
    this.onBack,
  });

  final CodexThread thread;
  final bool compact;
  final bool readOnly;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        padding: EdgeInsets.fromLTRB(compact ? 6 : 22, 12, 16, 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            if (compact)
              IconButton(
                tooltip: 'Back to tasks',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    thread.title.isEmpty ? 'Codex task' : thread.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        _stateIcon(thread.state),
                        size: 15,
                        color: _stateColor(theme, thread.state),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          [
                            _stateLabel(thread.state),
                            if (thread.project.isNotEmpty) thread.project,
                            if (thread.updatedAt > 0)
                              _formatTimestamp(thread.updatedAt),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (readOnly)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  'Read only',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item});

  final CodexHistoryItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = item.kind == 'user_message';
    final body = item.text.isNotEmpty
        ? item.text
        : (item.detail.isNotEmpty ? item.detail : item.status);
    final technical = item.kind == 'command' ||
        item.kind == 'tool' ||
        item.kind == 'file_change' ||
        item.kind == 'web_search';

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.only(left: 34, bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: SelectableText(body, style: theme.textTheme.bodyMedium),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              _historyIcon(item.kind),
              size: 17,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _historyLabel(item.kind),
                        style: theme.textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (item.status.isNotEmpty)
                      Text(
                        _stateLabel(item.status),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Container(
                    width: double.infinity,
                    padding:
                        technical ? const EdgeInsets.all(12) : EdgeInsets.zero,
                    decoration: technical
                        ? BoxDecoration(
                            color: theme.colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(12),
                          )
                        : null,
                    child: SelectableText(
                      body,
                      style: technical
                          ? theme.textTheme.bodyMedium
                              ?.copyWith(fontFamily: 'monospace')
                          : theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
                if (item.detail.isNotEmpty && item.text.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    item.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalInline extends StatelessWidget {
  const _ApprovalInline({required this.model, required this.approval});

  final CodexModel model;
  final CodexApproval approval;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = model.isApprovalPending(approval.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_open_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  approval.title.isEmpty ? 'Approval required' : approval.title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (approval.summary.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              approval.summary,
              style: approval.kind == 'command'
                  ? theme.textTheme.bodyMedium
                      ?.copyWith(fontFamily: 'monospace')
                  : theme.textTheme.bodyMedium,
            ),
          ],
          if (approval.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              approval.reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (approval.workingDirectory.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Working directory',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            SelectableText(
              approval.workingDirectory,
              style:
                  theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
          if (approval.scope.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Scope',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            SelectableText(
              approval.scope,
              style:
                  theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
          const SizedBox(height: 12),
          if (approval.actionable && model.canRespondToApprovals)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: pending
                      ? null
                      : () => unawaited(
                            model.respondToApproval(approval, false),
                          ),
                  child: const Text('Deny'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: pending
                      ? null
                      : () => unawaited(
                            model.respondToApproval(approval, true),
                          ),
                  child: pending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Approve'),
                ),
              ],
            )
          else
            Text(
              'This request needs a compatible MIRPG bridge action. Opening Windows Codex does not transfer this approval.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.model,
    required this.thread,
    required this.controller,
    required this.onOpenWindowsApp,
  });

  final CodexModel model;
  final CodexThread thread;
  final TextEditingController controller;
  final VoidCallback onOpenWindowsApp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = model.isControlPending(thread.id);
    final handoffPending = model.isWindowsAppHandoffPending(thread.id);

    Widget openWindowsButton() => TextButton.icon(
          onPressed: pending ? null : onOpenWindowsApp,
          icon: handoffPending
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.open_in_new_rounded, size: 17),
          label: const Text('Open Windows app'),
        );

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: !model.hasInteractiveControl
              ? Align(
                  alignment: Alignment.centerRight,
                  child: openWindowsButton(),
                )
              : model.needsNativeResume(thread.id)
                  ? Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: pending
                                ? null
                                : () =>
                                    unawaited(model.resumeThread(thread.id)),
                            icon: pending && !handoffPending
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.play_arrow_rounded),
                            label: Text(
                              pending && !handoffPending
                                  ? 'Connecting to task…'
                                  : 'Resume',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        openWindowsButton(),
                      ],
                    )
                  : _InteractiveComposer(
                      model: model,
                      thread: thread,
                      controller: controller,
                      pending: pending,
                      openWindowsButton: openWindowsButton(),
                    ),
        ),
      ),
    );
  }
}

class _InteractiveComposer extends StatelessWidget {
  const _InteractiveComposer({
    required this.model,
    required this.thread,
    required this.controller,
    required this.pending,
    required this.openWindowsButton,
  });

  final CodexModel model;
  final CodexThread thread;
  final TextEditingController controller;
  final bool pending;
  final Widget openWindowsButton;

  Future<void> _submit(BuildContext context, {bool steerNow = false}) async {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    final working = model.activeTurnIdFor(thread.id).isNotEmpty;
    final operationId = steerNow
        ? await model.steer(thread.id, text)
        : working
            ? await model.queue(thread.id, text)
            : await model.send(thread.id, text);
    if (operationId == null) return;
    final outcome = await model.waitForOperation(operationId);
    if (!context.mounted) return;
    if (outcome == RemoteOperationState.applied &&
        controller.text.trim() == text) {
      controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final turnId = model.activeTurnIdFor(thread.id);
    final starting = model.isTurnStarting(thread.id);
    final working = turnId.isNotEmpty;
    final canType = !starting &&
        (working
            ? model.canQueueTurn || model.canSteerTurn
            : model.canStartTurn);
    final canPrimary =
        !starting && (working ? model.canQueueTurn : model.canStartTurn);
    final actionLabel =
        starting ? 'Starting' : (working ? 'Queue next' : 'Send');
    final queued = model.queuedInstructionsFor(thread.id);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.fromLTRB(12, 3, 6, 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: canType,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: starting
                        ? 'Starting Codex turn…'
                        : working
                            ? 'Add the next instruction or steer this run…'
                            : 'Message Codex…',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: FilledButton(
                  onPressed:
                      pending || !canPrimary ? null : () => _submit(context),
                  child: Text(actionLabel),
                ),
              ),
            ],
          ),
        ),
        if (queued.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer.withOpacity(0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Queued next · ${queued.length}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                for (final instruction in queued.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      instruction.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (queued.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '+${queued.length - 3} more',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final turnActions = <Widget>[
              if (working && model.canInterruptTurn)
                TextButton.icon(
                  onPressed: pending
                      ? null
                      : () => unawaited(model.interrupt(thread.id)),
                  icon: const Icon(Icons.stop_circle_outlined, size: 17),
                  label: const Text('Stop'),
                ),
              if (working && model.canSteerTurn)
                TextButton.icon(
                  onPressed:
                      pending ? null : () => _submit(context, steerNow: true),
                  icon: const Icon(Icons.tune_rounded, size: 17),
                  label: const Text('Steer now'),
                ),
            ];
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (turnActions.isNotEmpty)
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: turnActions,
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: openWindowsButton,
                  ),
                ],
              );
            }
            return Row(
              children: [
                ...turnActions,
                const Spacer(),
                openWindowsButton,
              ],
            );
          },
        ),
      ],
    );
  }
}

class _EmptyThreadPane extends StatelessWidget {
  const _EmptyThreadPane();

  @override
  Widget build(BuildContext context) => const _CodexMessageState(
        icon: Icons.chat_bubble_outline_rounded,
        title: 'Choose a task',
        message: 'Select a Codex task from the sidebar to continue working.',
      );
}

class _TaskListSkeleton extends StatelessWidget {
  const _TaskListSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHigh;
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: 6,
      itemBuilder: (_, index) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 14,
              width: 180 - index * 8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 10,
              width: 116,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineSkeleton extends StatelessWidget {
  const _TimelineSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerLow;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        for (final width in const [0.86, 0.68, 0.78])
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: width,
              child: Container(
                height: 58,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _CodexMessageState extends StatelessWidget {
  const _CodexMessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 14),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
              if (secondaryActionLabel != null &&
                  onSecondaryAction != null) ...[
                const SizedBox(height: 6),
                TextButton(
                  onPressed: onSecondaryAction,
                  child: Text(secondaryActionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceDot extends StatelessWidget {
  const _ServiceDot({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _stateColor(Theme.of(context), state),
        ),
      );
}

Color _stateColor(ThemeData theme, String state) {
  switch (state) {
    case 'ready':
    case 'idle':
    case 'completed':
      return theme.colorScheme.primary;
    case 'working':
    case 'starting':
    case 'waiting_for_input':
    case 'waiting_for_approval':
    case 'interrupting':
      return theme.colorScheme.tertiary;
    case 'failed':
    case 'disconnected':
    case 'unavailable':
      return theme.colorScheme.error;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

String _formatTimestamp(int raw) {
  final milliseconds = raw > 1000000000000 ? raw : raw * 1000;
  try {
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    return '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)} '
        '${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
  } catch (_) {
    return '';
  }
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _stateLabel(String state) {
  if (state.isEmpty) return 'Ready';
  if (state == 'resumable') return 'History';
  return state
      .split('_')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

IconData _stateIcon(String state) {
  switch (state) {
    case 'working':
      return Icons.pending_outlined;
    case 'interrupting':
      return Icons.stop_circle_outlined;
    case 'resumable':
      return Icons.play_circle_outline_rounded;
    case 'waiting_for_approval':
      return Icons.lock_open_rounded;
    case 'waiting_for_input':
      return Icons.input_rounded;
    case 'failed':
      return Icons.error_outline_rounded;
    case 'disconnected':
      return Icons.cloud_off_outlined;
    case 'completed':
      return Icons.check_circle_outline_rounded;
    default:
      return Icons.chat_bubble_outline_rounded;
  }
}

IconData _historyIcon(String kind) {
  switch (kind) {
    case 'agent_message':
      return Icons.auto_awesome_outlined;
    case 'plan':
      return Icons.checklist_rounded;
    case 'reasoning':
      return Icons.psychology_alt_outlined;
    case 'command':
      return Icons.terminal_rounded;
    case 'file_change':
      return Icons.description_outlined;
    case 'tool':
      return Icons.build_outlined;
    case 'web_search':
      return Icons.search_rounded;
    default:
      return Icons.info_outline_rounded;
  }
}

String _historyLabel(String kind) {
  switch (kind) {
    case 'agent_message':
      return 'Codex';
    case 'plan':
      return 'Plan';
    case 'reasoning':
      return 'Reasoning summary';
    case 'command':
      return 'Command';
    case 'file_change':
      return 'File changes';
    case 'tool':
      return 'Tool';
    case 'web_search':
      return 'Web search';
    case 'status':
      return 'Status';
    default:
      return 'Activity';
  }
}
