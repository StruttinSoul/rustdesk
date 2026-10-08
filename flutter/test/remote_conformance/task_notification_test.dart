import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/task_notification_policy.dart';

TaskNotificationEvent _approval({
  String eventId = 'approval:approve-1',
  String runtimeId = '123456789',
  String taskId = 'thread-1',
  String title = 'Fix remote controls',
}) =>
    TaskNotificationEvent(
      eventId: eventId,
      runtimeId: runtimeId,
      taskId: taskId,
      taskTitle: title,
      type: TaskNotificationType.approval,
    );

void main() {
  test('opt_out_no_notification', () {
    final policy = TaskNotificationPolicy(enabled: false);

    expect(policy.consider(_approval(), live: true), isNull);
  });

  test('duplicate_event_one_alert', () {
    final policy = TaskNotificationPolicy(enabled: true);
    final event = _approval();

    expect(policy.consider(event, live: true), isNotNull);
    expect(policy.consider(event, live: true), isNull);
  });

  test('same event id on different runtimes alerts independently', () {
    final policy = TaskNotificationPolicy(enabled: true);

    expect(
        policy.consider(_approval(runtimeId: 'pc-1'), live: true), isNotNull);
    expect(
        policy.consider(_approval(runtimeId: 'pc-2'), live: true), isNotNull);
  });

  test('bounded seen history persists the newest scoped event', () {
    final policy = TaskNotificationPolicy(enabled: true);
    for (var index = 0;
        index <= TaskNotificationPolicy.maxRememberedEvents;
        index++) {
      policy.consider(
        _approval(eventId: 'approval:$index', runtimeId: 'pc-1'),
        live: false,
      );
    }

    final restored = TaskNotificationPolicy(
      enabled: true,
      seenEventIds: TaskNotificationPolicy.decodeSeenEventIds(
        policy.encodeSeenEventIds(),
      ),
    );
    expect(
      restored.consider(
        _approval(eventId: 'approval:128', runtimeId: 'pc-1'),
        live: true,
      ),
      isNull,
    );
  });

  test('stale_task_safe_fallback', () {
    final uri = _approval().deepLink;

    expect(
      resolveTaskNotificationTarget(
        uri,
        runtimeId: '123456789',
        knownTaskIds: const {'another-thread'},
      ),
      const TaskNotificationNavigationTarget(
        runtimeId: '123456789',
        taskId: null,
      ),
    );
  });

  test('sensitive_content_hidden_when_requested', () {
    final policy = TaskNotificationPolicy(
      enabled: true,
      hideSensitiveContent: true,
    );

    final alert = policy.consider(
      _approval(title: 'Secret customer project'),
      live: true,
    );

    expect(alert, isNotNull);
    expect(alert!.body, isNot(contains('Secret customer project')));
    expect(alert.hideSensitiveContent, isTrue);
  });

  test('reconnect_does_not_realert_history', () {
    final policy = TaskNotificationPolicy(enabled: true);
    final event = _approval();

    expect(policy.consider(event, live: false), isNull);
    expect(policy.consider(event, live: true), isNull);
  });
}
