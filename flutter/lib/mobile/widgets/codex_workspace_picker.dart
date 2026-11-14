import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/codex_model.dart';

class CodexWorkspacePicker extends StatelessWidget {
  const CodexWorkspacePicker({
    super.key,
    required this.model,
    required this.onSelected,
  });

  final CodexModel model;
  final ValueChanged<CodexWorkspace> onSelected;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 620),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Choose workspace',
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'New Codex tasks start only in host-approved workspaces.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh workspaces',
                        onPressed: model.loadingWorkspaces
                            ? null
                            : () => unawaited(model.listWorkspaces()),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (model.workspaceError.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              model.workspaceError,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (model.loadingWorkspaces && model.workspaces.isEmpty)
                    const Expanded(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (model.workspaces.isEmpty)
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            'No host workspaces are available yet. Open or create a Codex task on the PC in the workspace you want to use, then refresh.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: model.workspaces.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final workspace = model.workspaces[index];
                          final enabled = workspace.accessible &&
                              !model.isStartingThread;
                          return Semantics(
                            button: enabled,
                            enabled: enabled,
                            label:
                                '${workspace.name}, ${workspace.path}, ${workspace.status}',
                            child: Material(
                              color: theme.colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: enabled
                                    ? () => onSelected(workspace)
                                    : null,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        workspace.accessible
                                            ? Icons.folder_outlined
                                            : Icons.folder_off_outlined,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              workspace.name.isEmpty
                                                  ? workspace.path
                                                  : workspace.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              workspace.path,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                color: theme.colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ),
                                            if (!workspace.accessible ||
                                                workspace.status.isNotEmpty) ...[
                                              const SizedBox(height: 3),
                                              Text(
                                                workspace.status,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.labelSmall
                                                    ?.copyWith(
                                                  color: workspace.accessible
                                                      ? theme.colorScheme
                                                          .onSurfaceVariant
                                                      : theme.colorScheme.error,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        workspace.accessible
                                            ? Icons.chevron_right_rounded
                                            : Icons.block_rounded,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  if (model.nextWorkspaceCursor.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton(
                        onPressed: model.loadingWorkspaces
                            ? null
                            : () => unawaited(
                                  model.listWorkspaces(reset: false),
                                ),
                        child: model.loadingWorkspaces
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Load more'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
