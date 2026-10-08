import 'dart:collection';
import 'dart:convert';

const kCodexTaskNotificationsOption = 'mirpg-codex-task-notifications';
const kCodexTaskNotificationPrivacyOption =
    'mirpg-codex-task-notification-hide-sensitive';
const kCodexTaskNotificationSeenOption = 'mirpg-codex-task-notification-seen';

enum TaskNotificationType {
  approval,
  reviewReady,
  failure,
}

typedef TaskNotificationSender = Future<bool> Function(
  TaskNotificationAlert alert,
);
typedef TaskNotificationPermissionRequester = Future<bool> Function();
typedef TaskNotificationSettingsSaver = Future<void> Function(
  bool enabled,
  bool hideSensitiveContent,
  String encodedSeenEventIds,
);

class TaskNotificationEvent {
  const TaskNotificationEvent({
    required this.eventId,
    required this.runtimeId,
    required this.taskId,
    required this.taskTitle,
    required this.type,
  });

  final String eventId;
  final String runtimeId;
  final String taskId;
  final String taskTitle;
  final TaskNotificationType type;

  Uri get deepLink => Uri(
        scheme: 'rustdesk',
        host: runtimeId,
        queryParameters: <String, String>{'codex_thread': taskId},
      );
}

class TaskNotificationAlert {
  const TaskNotificationAlert({
    required this.eventId,
    required this.title,
    required this.body,
    required this.deepLink,
    required this.hideSensitiveContent,
  });

  final String eventId;
  final String title;
  final String body;
  final Uri deepLink;
  final bool hideSensitiveContent;

  Map<String, dynamic> toPlatformMap() => <String, dynamic>{
        'event_id': eventId,
        'title': title,
        'body': body,
        'deep_link': deepLink.toString(),
        'hide_sensitive_content': hideSensitiveContent,
      };
}

class TaskNotificationPolicy {
  TaskNotificationPolicy({
    required this.enabled,
    this.hideSensitiveContent = true,
    Iterable<String> seenEventIds = const <String>[],
  }) {
    for (final id in seenEventIds) {
      if (id.trim().isNotEmpty) _seenEventIds.add(id);
    }
    _trimSeen();
  }

  static const int maxRememberedEvents = 128;

  bool enabled;
  bool hideSensitiveContent;
  final LinkedHashSet<String> _seenEventIds = LinkedHashSet<String>();

  Iterable<String> get seenEventIds => List<String>.unmodifiable(_seenEventIds);

  TaskNotificationAlert? consider(
    TaskNotificationEvent event, {
    required bool live,
  }) {
    final eventId = event.eventId.trim();
    final runtimeId = event.runtimeId.trim();
    if (eventId.isEmpty || runtimeId.isEmpty || event.taskId.trim().isEmpty) {
      return null;
    }

    final scopedEventId = '$runtimeId:$eventId';
    final legacySeen = _seenEventIds.contains(eventId);
    final unseen = !legacySeen && _seenEventIds.add(scopedEventId);
    if (legacySeen) {
      // Migrate pre-runtime-scoping entries without causing an upgrade replay.
      _seenEventIds.add(scopedEventId);
    }
    _trimSeen();
    if (!live || !unseen || !enabled) return null;

    final label = switch (event.type) {
      TaskNotificationType.approval => 'Codex needs your approval',
      TaskNotificationType.reviewReady => 'Codex task is ready to review',
      TaskNotificationType.failure => 'Codex task needs attention',
    };
    final body = hideSensitiveContent || event.taskTitle.trim().isEmpty
        ? 'Open MIRPG Remote to view the task.'
        : event.taskTitle.trim();

    return TaskNotificationAlert(
      eventId: scopedEventId,
      title: label,
      body: body,
      deepLink: event.deepLink,
      hideSensitiveContent: hideSensitiveContent,
    );
  }

  void _trimSeen() {
    while (_seenEventIds.length > maxRememberedEvents) {
      _seenEventIds.remove(_seenEventIds.first);
    }
  }

  String encodeSeenEventIds() => jsonEncode(_seenEventIds.toList());

  static List<String> decodeSeenEventIds(String encoded) {
    if (encoded.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return const <String>[];
      return decoded
          .whereType<String>()
          .where((value) => value.trim().isNotEmpty)
          .take(maxRememberedEvents)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }
}

class TaskNotificationNavigationTarget {
  const TaskNotificationNavigationTarget({
    required this.runtimeId,
    required this.taskId,
  });

  final String runtimeId;
  final String? taskId;

  @override
  bool operator ==(Object other) =>
      other is TaskNotificationNavigationTarget &&
      other.runtimeId == runtimeId &&
      other.taskId == taskId;

  @override
  int get hashCode => Object.hash(runtimeId, taskId);
}

TaskNotificationNavigationTarget? resolveTaskNotificationTarget(
  Uri uri, {
  required String runtimeId,
  required Iterable<String> knownTaskIds,
}) {
  if (uri.scheme != 'rustdesk' || uri.host != runtimeId) return null;
  final requested = uri.queryParameters['codex_thread']?.trim() ?? '';
  final known = requested.isNotEmpty && knownTaskIds.contains(requested);
  return TaskNotificationNavigationTarget(
    runtimeId: runtimeId,
    taskId: known ? requested : null,
  );
}

class TaskNotificationDeepLinkStore {
  TaskNotificationDeepLinkStore._();

  static TaskNotificationNavigationTarget? _pending;

  static void remember(Uri uri) {
    if (uri.scheme != 'rustdesk') return;
    final runtimeId = uri.host.trim();
    final taskId = uri.queryParameters['codex_thread']?.trim() ?? '';
    if (runtimeId.isEmpty || taskId.isEmpty) return;
    _pending = TaskNotificationNavigationTarget(
      runtimeId: runtimeId,
      taskId: taskId,
    );
  }

  static TaskNotificationNavigationTarget? takeForRuntime(String runtimeId) {
    final pending = _pending;
    if (pending == null || pending.runtimeId != runtimeId) return null;
    _pending = null;
    return pending;
  }

  static void clear() => _pending = null;
}
