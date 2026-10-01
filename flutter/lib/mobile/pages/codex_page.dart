import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/codex_model.dart';

class CodexPage extends StatefulWidget {
  const CodexPage({super.key, required this.model});

  final CodexModel model;

  @override
  State<CodexPage> createState() => _CodexPageState();
}

class _CodexPageState extends State<CodexPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.model.listThreads());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Codex'),
        actions: [
          IconButton(
            tooltip: 'Refresh threads',
            onPressed: widget.model.loadingThreads
                ? null
                : () => unawaited(widget.model.listThreads()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.model,
        builder: (context, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final model = widget.model;
    if (model.loadingThreads && model.threads.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (model.error.isNotEmpty && model.threads.isEmpty) {
      return _CodexMessageState(
        icon: Icons.cloud_off_outlined,
        title: 'Codex is unavailable',
        message: model.error,
        actionLabel: 'Retry',
        onAction: () => unawaited(model.listThreads()),
      );
    }

    return Column(
      children: [
        _CodexServiceHeader(model: model),
        if (model.error.isNotEmpty)
          MaterialBanner(
            content: Text(model.error),
            actions: [
              TextButton(
                onPressed: () => unawaited(model.listThreads()),
                child: const Text('Retry'),
              ),
            ],
          ),
        Expanded(
          child: model.threads.isEmpty
              ? const _CodexMessageState(
                  icon: Icons.forum_outlined,
                  title: 'No Codex threads found',
                  message:
                      'Tasks from the local Codex installation will appear here.',
                )
              : RefreshIndicator(
                  onRefresh: model.listThreads,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: model.threads.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final thread = model.threads[index];
                      return _CodexThreadTile(
                        thread: thread,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CodexThreadPage(
                                model: model,
                                thread: thread,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _CodexServiceHeader extends StatelessWidget {
  const _CodexServiceHeader({required this.model});

  final CodexModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = model.codexVersion.isEmpty ? '' : ' ${model.codexVersion}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Icon(Icons.code, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Codex$version',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  _stateLabel(model.serviceState),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const _ReadOnlyBadge(),
        ],
      ),
    );
  }
}

class _CodexThreadTile extends StatelessWidget {
  const _CodexThreadTile({required this.thread, required this.onTap});

  final CodexThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadata = <String>[
      if (thread.originator.isNotEmpty) thread.originator,
      if (thread.project.isNotEmpty) thread.project,
      if (thread.updatedAt > 0) _formatTimestamp(thread.updatedAt),
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
        foregroundColor: theme.colorScheme.primary,
        child: Icon(_stateIcon(thread.state), size: 20),
      ),
      title: Text(
        thread.title.isEmpty ? 'Untitled task' : thread.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: metadata.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                metadata.join('  •  '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
      trailing: _StateBadge(state: thread.state),
      onTap: onTap,
    );
  }
}

class CodexThreadPage extends StatefulWidget {
  const CodexThreadPage({
    super.key,
    required this.model,
    required this.thread,
  });

  final CodexModel model;
  final CodexThread thread;

  @override
  State<CodexThreadPage> createState() => _CodexThreadPageState();
}

class _CodexThreadPageState extends State<CodexThreadPage> {
  final ScrollController _scrollController = ScrollController();
  int _lastItemCount = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModelChanged);
    unawaited(widget.model.selectThread(widget.thread.id));
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    widget.model.leaveThread(widget.thread.id);
    _scrollController.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    final itemCount = widget.model.historyFor(widget.thread.id).length;
    if (itemCount == _lastItemCount) return;
    final followTail = !_scrollController.hasClients ||
        _scrollController.position.extentAfter < 160;
    _lastItemCount = itemCount;
    if (!followTail) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final thread = widget.model.threads.firstWhere(
          (candidate) => candidate.id == widget.thread.id,
          orElse: () => widget.thread,
        );
        return Scaffold(
          appBar: AppBar(
            title: Text(
              thread.title.isEmpty ? 'Codex task' : thread.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: const [
              Padding(
                padding: EdgeInsets.only(right: 12),
                child: Center(child: _ReadOnlyBadge()),
              ),
            ],
          ),
          body: _buildThreadBody(context, thread),
        );
      },
    );
  }

  Widget _buildThreadBody(BuildContext context, CodexThread thread) {
    final model = widget.model;
    final items = model.historyFor(thread.id);
    final loading = model.isHistoryLoading(thread.id);
    final error = model.errorFor(thread.id);

    if (loading && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error.isNotEmpty && items.isEmpty) {
      return _CodexMessageState(
        icon: Icons.error_outline,
        title: 'Unable to load this task',
        message: error,
        actionLabel: 'Retry',
        onAction: () => unawaited(model.loadHistory(thread.id)),
      );
    }

    return Column(
      children: [
        _ThreadStatusBar(thread: thread),
        if (error.isNotEmpty)
          MaterialBanner(
            content: Text(error),
            actions: [
              TextButton(
                onPressed: () => unawaited(model.loadHistory(thread.id)),
                child: const Text('Retry'),
              ),
            ],
          ),
        Expanded(
          child: items.isEmpty
              ? const _CodexMessageState(
                  icon: Icons.notes_outlined,
                  title: 'No visible history',
                  message:
                      'This task has no history that is available on the read-only surface.',
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
                  itemCount: items.length +
                      (model.nextCursorFor(thread.id).isNotEmpty ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (model.nextCursorFor(thread.id).isNotEmpty &&
                        index == 0) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextButton.icon(
                            onPressed: loading
                                ? null
                                : () => unawaited(model.loadHistory(
                                      thread.id,
                                      reset: false,
                                    )),
                            icon: loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.expand_less),
                            label: const Text('Load older history'),
                          ),
                        ),
                      );
                    }
                    final offset =
                        model.nextCursorFor(thread.id).isNotEmpty ? 1 : 0;
                    return _HistoryItemView(item: items[index - offset]);
                  },
                ),
        ),
      ],
    );
  }
}

class _ThreadStatusBar extends StatelessWidget {
  const _ThreadStatusBar({required this.thread});

  final CodexThread thread;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final working = thread.state == 'working' ||
        thread.state == 'waiting_for_approval' ||
        thread.state == 'waiting_for_input';
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.45),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          if (working) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 9),
          ] else ...[
            Icon(_stateIcon(thread.state), size: 17),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              _stateLabel(thread.state),
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (thread.updatedAt > 0)
            Text(
              _formatTimestamp(thread.updatedAt),
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _HistoryItemView extends StatelessWidget {
  const _HistoryItemView({required this.item});

  final CodexHistoryItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = item.kind == 'user_message';
    final body = item.text.isNotEmpty
        ? item.text
        : (item.detail.isNotEmpty ? item.detail : item.status);
    final background = isUser
        ? theme.colorScheme.primary.withOpacity(0.08)
        : theme.colorScheme.surface;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_historyIcon(item.kind), size: 17),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _historyLabel(item.kind),
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (item.status.isNotEmpty)
                  Text(
                    _stateLabel(item.status),
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                body,
                style: item.kind == 'command'
                    ? theme.textTheme.bodyMedium
                        ?.copyWith(fontFamily: 'monospace')
                    : theme.textTheme.bodyMedium,
              ),
            ],
            if (item.detail.isNotEmpty && item.text.isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(item.detail, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _stateLabel(state),
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

class _ReadOnlyBadge extends StatelessWidget {
  const _ReadOnlyBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('Read only', style: theme.textTheme.labelSmall),
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
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

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
              Icon(icon, size: 38, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 14),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
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
    case 'waiting_for_approval':
      return Icons.approval_outlined;
    case 'waiting_for_input':
      return Icons.input_outlined;
    case 'failed':
      return Icons.error_outline;
    case 'disconnected':
      return Icons.cloud_off_outlined;
    case 'completed':
      return Icons.check_circle_outline;
    default:
      return Icons.forum_outlined;
  }
}

IconData _historyIcon(String kind) {
  switch (kind) {
    case 'user_message':
      return Icons.person_outline;
    case 'agent_message':
      return Icons.auto_awesome_outlined;
    case 'plan':
      return Icons.checklist_outlined;
    case 'reasoning':
      return Icons.lightbulb_outline;
    case 'command':
      return Icons.terminal;
    case 'file_change':
      return Icons.description_outlined;
    case 'tool':
      return Icons.build_outlined;
    case 'web_search':
      return Icons.search;
    default:
      return Icons.info_outline;
  }
}

String _historyLabel(String kind) {
  switch (kind) {
    case 'user_message':
      return 'You';
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
