import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/codex_model.dart';

class CodexPage extends StatefulWidget {
  const CodexPage({
    super.key,
    required this.model,
    this.embedded = false,
    this.onWindowsAppOpened,
  });

  final CodexModel model;
  final bool embedded;
  final VoidCallback? onWindowsAppOpened;

  @override
  State<CodexPage> createState() => _CodexPageState();
}

class _CodexPageState extends State<CodexPage> {
  CodexThread? _selectedThread;
  String _seenStartedThreadId = '';

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_handleModelChanged);
    unawaited(widget.model.listThreads());
  }

  @override
  void didUpdateWidget(covariant CodexPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model == widget.model) return;
    oldWidget.model.removeListener(_handleModelChanged);
    widget.model.addListener(_handleModelChanged);
    _selectedThread = null;
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
    setState(() => _selectedThread = match.first);
  }

  void _selectThread(CodexThread thread) {
    if (_selectedThread?.id == thread.id) return;
    setState(() => _selectedThread = thread);
  }

  void _clearSelection() {
    if (_selectedThread == null) return;
    setState(() => _selectedThread = null);
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
    final selected = _selectedThread;
    if (selected == null) return null;
    for (final thread in widget.model.threads) {
      if (thread.id == selected.id) return thread;
    }
    return selected;
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
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
                      itemCount: model.threads.length,
                      itemBuilder: (context, index) {
                        final thread = model.threads[index];
                        return _TaskRow(
                          thread: thread,
                          selected: selectedThreadId == thread.id,
                          onTap: () => onSelect(thread),
                        );
                      },
                    ),
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
                onPressed: model.isStartingThread
                    ? null
                    : () => unawaited(model.startThread()),
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
  final TextEditingController _composerController = TextEditingController();
  int _lastVisibleItemCount = 0;

  @override
  void initState() {
    super.initState();
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
    }
    if (oldWidget.thread.id != widget.thread.id) {
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
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onModelChanged() {
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

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final thread = model.threads.firstWhere(
      (candidate) => candidate.id == widget.thread.id,
      orElse: () => widget.thread,
    );
    final error = model.errorFor(thread.id);
    return Column(
      children: [
        _ThreadHeader(
          thread: thread,
          compact: widget.compact,
          onBack: widget.onBack,
          readOnly: !model.hasInteractiveControl,
        ),
        if (error.isNotEmpty)
          _InlineError(
            message: error,
            onRetry: () => unawaited(model.loadHistory(thread.id)),
          ),
        Expanded(child: _buildTimeline(context, thread)),
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
              'Handle this approval in the Windows Codex app.',
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
                            label: const Text('Resume'),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final turnId = model.activeTurnIdFor(thread.id);
    final starting = model.isTurnStarting(thread.id);
    final working = turnId.isNotEmpty;
    final canSubmit =
        !starting && (working ? model.canSteerTurn : model.canStartTurn);
    final actionLabel = starting ? 'Starting' : (working ? 'Steer' : 'Send');

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
                  enabled: !pending && canSubmit,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: starting
                        ? 'Starting Codex turn…'
                        : working
                            ? 'Steer the active Codex turn…'
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
                  onPressed: pending || !canSubmit
                      ? null
                      : () async {
                          final text = controller.text.trim();
                          if (text.isEmpty) return;
                          if (working) {
                            await model.steer(thread.id, text);
                          } else {
                            await model.send(thread.id, text);
                          }
                          controller.clear();
                        },
                  child: Text(actionLabel),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            if (working && model.canInterruptTurn)
              TextButton.icon(
                onPressed: pending
                    ? null
                    : () => unawaited(model.interrupt(thread.id)),
                icon: const Icon(Icons.stop_circle_outlined, size: 17),
                label: const Text('Stop'),
              )
            else
              const Spacer(),
            if (working && model.canInterruptTurn) const Spacer(),
            openWindowsButton,
          ],
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
