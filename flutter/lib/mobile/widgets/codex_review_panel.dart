import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/codex_model.dart';

enum _ReviewSection { changes, artifacts }

class CodexReviewPanel extends StatefulWidget {
  const CodexReviewPanel({
    super.key,
    required this.model,
    required this.threadId,
  });

  final CodexModel model;
  final String threadId;

  @override
  State<CodexReviewPanel> createState() => _CodexReviewPanelState();
}

class _CodexReviewPanelState extends State<CodexReviewPanel> {
  _ReviewSection _section = _ReviewSection.changes;

  Future<void> _refresh() async {
    if (_section == _ReviewSection.changes) {
      await widget.model.loadTaskChanges(widget.threadId);
    } else {
      await widget.model.loadArtifacts(widget.threadId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final model = widget.model;
        final changes = model.taskChangesFor(widget.threadId);
        final artifacts = model.artifactsFor(widget.threadId);
        final error = model.reviewErrorFor(widget.threadId);
        return Column(
          children: [
            _ReviewSectionPicker(
              section: _section,
              changeCount: changes.length,
              artifactCount: artifacts.length,
              onRefresh: () => unawaited(_refresh()),
              onChanged: (section) {
                if (_section == section) return;
                setState(() => _section = section);
              },
            ),
            if (error.isNotEmpty)
              _ReviewError(
                message: error,
                onRetry: () =>
                    unawaited(model.retryReviewFailure(widget.threadId)),
              ),
            Expanded(
              child: _section == _ReviewSection.changes
                  ? _ChangesList(model: model, threadId: widget.threadId)
                  : _ArtifactsList(model: model, threadId: widget.threadId),
            ),
          ],
        );
      },
    );
  }
}

class _ReviewSectionPicker extends StatelessWidget {
  const _ReviewSectionPicker({
    required this.section,
    required this.changeCount,
    required this.artifactCount,
    required this.onRefresh,
    required this.onChanged,
  });

  final _ReviewSection section;
  final int changeCount;
  final int artifactCount;
  final VoidCallback onRefresh;
  final ValueChanged<_ReviewSection> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: _SectionButton(
              key: const ValueKey('codex-review-changes-tab'),
              label: 'Changes',
              count: changeCount,
              selected: section == _ReviewSection.changes,
              onTap: () => onChanged(_ReviewSection.changes),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _SectionButton(
              key: const ValueKey('codex-review-artifacts-tab'),
              label: 'Artifacts',
              count: artifactCount,
              selected: section == _ReviewSection.artifacts,
              onTap: () => onChanged(_ReviewSection.artifacts),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('codex-review-refresh'),
            tooltip: 'Refresh review',
            onPressed: onRefresh,
            icon: Icon(
              Icons.refresh_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
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
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
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
                  if (count > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChangesList extends StatelessWidget {
  const _ChangesList({required this.model, required this.threadId});

  final CodexModel model;
  final String threadId;

  @override
  Widget build(BuildContext context) {
    final changes = model.taskChangesFor(threadId);
    final loading = model.isTaskChangesLoading(threadId);
    if (loading && changes.isEmpty) return const _ReviewLoading();
    return RefreshIndicator(
      onRefresh: () => model.loadTaskChanges(threadId),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
        children: [
          if (changes.isEmpty)
            const _ReviewEmpty(
              icon: Icons.difference_outlined,
              title: 'No file changes',
              message: 'This task has no reviewable file changes yet.',
            )
          else
            for (final change in changes)
              _ChangeCard(
                key: ValueKey('codex-change-${change.id}'),
                model: model,
                threadId: threadId,
                change: change,
              ),
          if (model.nextTaskChangeCursorFor(threadId).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: loading
                    ? null
                    : () => unawaited(
                          model.loadTaskChanges(threadId, reset: false),
                        ),
                child: const Text('Load more changes'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArtifactsList extends StatelessWidget {
  const _ArtifactsList({required this.model, required this.threadId});

  final CodexModel model;
  final String threadId;

  @override
  Widget build(BuildContext context) {
    final artifacts = model.artifactsFor(threadId);
    final loading = model.isArtifactsLoading(threadId);
    if (loading && artifacts.isEmpty) return const _ReviewLoading();
    return RefreshIndicator(
      onRefresh: () => model.loadArtifacts(threadId),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
        children: [
          if (artifacts.isEmpty)
            const _ReviewEmpty(
              icon: Icons.inventory_2_outlined,
              title: 'No artifacts',
              message: 'No workspace artifacts are available for this task.',
            )
          else
            for (final artifact in artifacts)
              _ArtifactCard(
                key: ValueKey('codex-artifact-${artifact.id}'),
                model: model,
                threadId: threadId,
                artifact: artifact,
              ),
          if (model.nextArtifactCursorFor(threadId).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: loading
                    ? null
                    : () => unawaited(
                          model.loadArtifacts(threadId, reset: false),
                        ),
                child: const Text('Load more artifacts'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChangeCard extends StatefulWidget {
  const _ChangeCard({
    super.key,
    required this.model,
    required this.threadId,
    required this.change,
  });

  final CodexModel model;
  final String threadId;
  final CodexTaskChange change;

  @override
  State<_ChangeCard> createState() => _ChangeCardState();
}

class _ChangeCardState extends State<_ChangeCard> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded &&
        widget.change.diffAvailable &&
        widget.model.taskDiffFor(widget.change.id) == null) {
      unawaited(widget.model.loadTaskDiff(widget.threadId, widget.change.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    final theme = Theme.of(context);
    final preview = widget.model.taskDiffFor(change.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(_changeIcon(change.kind), size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            change.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              change.kind.isEmpty ? 'Changed' : change.kind,
                              _formatBytes(change.sizeBytes),
                              if (change.binary) 'Binary',
                              if (change.large) 'Large',
                            ].join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: change.diffAvailable
                    ? _TextPreview(
                        preview: preview,
                        loading: widget.model.isTaskDiffLoading(change.id),
                        loadMore: () => unawaited(widget.model.loadTaskDiff(
                          widget.threadId,
                          change.id,
                          reset: false,
                        )),
                      )
                    : _FallbackMessage(
                        message: change.fallbackReason.isEmpty
                            ? 'Diff preview is unavailable.'
                            : change.fallbackReason,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ArtifactCard extends StatefulWidget {
  const _ArtifactCard({
    super.key,
    required this.model,
    required this.threadId,
    required this.artifact,
  });

  final CodexModel model;
  final String threadId;
  final CodexArtifact artifact;

  @override
  State<_ArtifactCard> createState() => _ArtifactCardState();
}

class _ArtifactCardState extends State<_ArtifactCard> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded &&
        widget.artifact.readable &&
        widget.model.artifactPreviewFor(widget.artifact.id) == null) {
      unawaited(widget.model
          .loadArtifactPreview(widget.threadId, widget.artifact.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final artifact = widget.artifact;
    final theme = Theme.of(context);
    final preview = widget.model.artifactPreviewFor(artifact.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            artifact.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              _formatBytes(artifact.sizeBytes),
                              if (artifact.binary) 'Binary',
                              if (artifact.large) 'Large',
                            ].join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: artifact.readable
                    ? _TextPreview(
                        preview: preview,
                        loading:
                            widget.model.isArtifactPreviewLoading(artifact.id),
                        loadMore: () => unawaited(
                          widget.model.loadArtifactPreview(
                            widget.threadId,
                            artifact.id,
                            reset: false,
                          ),
                        ),
                      )
                    : _FallbackMessage(
                        message: artifact.fallbackReason.isEmpty
                            ? 'Artifact preview is unavailable.'
                            : artifact.fallbackReason,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({
    required this.preview,
    required this.loading,
    required this.loadMore,
  });

  final CodexReviewText? preview;
  final bool loading;
  final VoidCallback loadMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading && preview == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final value = preview;
    if (value == null) return const SizedBox.shrink();
    if (value.text.isEmpty && value.fallbackReason.isNotEmpty) {
      return _FallbackMessage(message: value.fallbackReason);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(10),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: SelectableText(
                  value.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (!value.complete)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
              ),
              onPressed: loading ? null : loadMore,
              icon: loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more_rounded, size: 18),
              label: const Text('Load more'),
            ),
          ),
      ],
    );
  }
}

class _ReviewLoading extends StatelessWidget {
  const _ReviewLoading();

  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
}

class _ReviewEmpty extends StatelessWidget {
  const _ReviewEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
      child: Column(
        children: [
          Icon(icon, size: 34, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewError extends StatelessWidget {
  const _ReviewError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
            ),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _FallbackMessage extends StatelessWidget {
  const _FallbackMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 17, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _changeIcon(String kind) {
  switch (kind.toLowerCase()) {
    case 'add':
    case 'added':
    case 'create':
      return Icons.note_add_outlined;
    case 'delete':
    case 'deleted':
    case 'remove':
      return Icons.delete_outline_rounded;
    case 'rename':
    case 'renamed':
      return Icons.drive_file_rename_outline_rounded;
    default:
      return Icons.edit_note_rounded;
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
}
