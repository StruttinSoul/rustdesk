import 'dart:convert';

import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final _sessionId = UuidValue('00000000-0000-4000-8000-0000000000f7');

JobProgress _activeTransfer(int id) => JobProgress()
  ..id = id
  ..type = JobType.transfer
  ..state = JobState.inProgress
  ..fileName = 'save.dat'
  ..jobName = '/source/save.dat';

void main() {
  test('pause_ack_controls_label', () async {
    var pauseCalls = 0;
    final controller = JobController(
      () => _sessionId,
      () => null,
      pauseTransferJob: (_, __) async => pauseCalls++,
    );
    controller.jobTable.add(_activeTransfer(41));

    expect(await controller.pauseJob(41, supported: true), isTrue);
    expect(pauseCalls, 1);
    expect(controller.jobTable.single.state, JobState.pauseRequested);

    controller.jobPaused({'id': '41', 'accepted': 'true', 'error': ''});
    expect(controller.jobTable.single.state, JobState.paused);
  });

  test('old_peer_reports_unsupported', () async {
    var pauseCalls = 0;
    final controller = JobController(
      () => _sessionId,
      () => null,
      pauseTransferJob: (_, __) async => pauseCalls++,
    );
    controller.jobTable.add(_activeTransfer(42));

    expect(await controller.pauseJob(42, supported: false), isFalse);
    expect(pauseCalls, 0);
    expect(controller.jobTable.single.state, JobState.inProgress);
  });

  test('pause timeout becomes interrupted instead of claiming success',
      () async {
    final resumed = <int>[];
    final controller = JobController(
      () => _sessionId,
      () => null,
      pauseTransferJob: (_, __) async {},
      resumeTransferJob: (_, jobId, __) async => resumed.add(jobId),
    );
    controller.jobTable.add(_activeTransfer(43));

    expect(await controller.pauseJob(43, supported: true), isTrue);
    controller.jobPaused({
      'id': '43',
      'accepted': 'false',
      'error': 'pause_outcome_unknown: no pause acknowledgment received',
    });

    expect(controller.jobTable.single.state, JobState.interrupted);
    expect(controller.jobTable.single.err, contains('outcome_unknown'));
    expect(await controller.resumeJob(43), isFalse);
    expect(resumed, isEmpty);

    controller.jobPaused({'id': '43', 'accepted': 'true', 'error': ''});
    expect(controller.jobTable.single.state, JobState.paused);
    expect(controller.jobTable.single.err, isEmpty);
    expect(await controller.resumeJob(43), isTrue);
    expect(resumed, [43]);
  });

  test('local pause flush failure remains interrupted and reviewable', () async {
    final resumed = <int>[];
    final controller = JobController(
      () => _sessionId,
      () => null,
      pauseTransferJob: (_, __) async {},
      resumeTransferJob: (_, jobId, __) async => resumed.add(jobId),
    );
    controller.jobTable.add(_activeTransfer(53));

    expect(await controller.pauseJob(53, supported: true), isTrue);
    controller.jobPaused({
      'id': '53',
      'accepted': 'false',
      'error':
          'pause_local_flush_failed: remote source paused but local partial flush failed: disk error',
    });

    expect(controller.jobTable.single.state, JobState.interrupted);
    expect(controller.jobTable.single.err, contains('local partial flush failed'));
    expect(await controller.resumeJob(53), isTrue);
    expect(resumed, [53]);
  });

  test('cancel stays requested until the matching terminal result', () async {
    final cancelled = <int>[];
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, jobId) async => cancelled.add(jobId),
    );
    controller.jobTable.add(_activeTransfer(45));

    await controller.cancelJob(45);

    expect(cancelled, [45]);
    expect(controller.jobTable.single.state, JobState.cancelRequested);

    controller.jobCancelled({
      'id': '45',
      'applied': 'true',
      'confirmed': 'true',
      'error': '',
    });

    expect(controller.jobTable.single.state, JobState.cancelled);
    expect(controller.jobTable.single.err, isEmpty);
  });

  test('legacy cancel stays honest when remote acknowledgement is unavailable',
      () async {
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, __) async {},
    );
    controller.jobTable.add(_activeTransfer(46));

    await controller.cancelJob(46);
    controller.jobCancelled({
      'id': '46',
      'applied': 'true',
      'confirmed': 'false',
      'error': 'Remote cancel acknowledgment is unavailable on this peer',
    });

    expect(controller.jobTable.single.state, JobState.cancelled);
    expect(controller.jobTable.single.err, contains('acknowledgment'));
  });

  test('unknown cancel outcome never claims cancelled', () async {
    final resumed = <int>[];
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, __) async {},
      resumeTransferJob: (_, jobId, __) async => resumed.add(jobId),
    );
    controller.jobTable.add(_activeTransfer(47));

    await controller.cancelJob(47);
    controller.jobCancelled({
      'id': '47',
      'applied': 'false',
      'confirmed': 'false',
      'error': 'cancel_outcome_unknown: no cancel acknowledgment received',
    });

    expect(controller.jobTable.single.state, JobState.interrupted);
    expect(controller.jobTable.single.err, contains('outcome_unknown'));
    expect(await controller.resumeJob(47), isFalse);
    expect(resumed, isEmpty);
  });

  test('confirmed cancel rejection can be reconciled by resume', () async {
    final resumed = <int>[];
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, __) async {},
      resumeTransferJob: (_, jobId, __) async => resumed.add(jobId),
    );
    controller.jobTable.add(_activeTransfer(49));

    await controller.cancelJob(49);
    controller.jobCancelled({
      'id': '49',
      'applied': 'false',
      'confirmed': 'true',
      'error': 'Transfer job is no longer active',
    });

    expect(controller.jobTable.single.state, JobState.interrupted);
    expect(await controller.resumeJob(49), isTrue);
    expect(resumed, [49]);
    expect(controller.jobTable.single.state, JobState.resumeRequested);
  });

  test('cancel send failure returns an active transfer to in progress', () async {
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, __) async {},
    );
    controller.jobTable.add(_activeTransfer(50));

    await controller.cancelJob(50);
    controller.jobCancelled({
      'id': '50',
      'applied': 'false',
      'confirmed': 'false',
      'error': 'cancel_request_failed: could not send cancel request: disconnected',
    });

    expect(controller.jobTable.single.state, JobState.inProgress);
    expect(controller.jobTable.single.err, contains('disconnected'));
  });

  test('progress cannot move a cancel-requested transfer', () async {
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, __) async {},
    );
    final job = _activeTransfer(51)
      ..fileNum = 2
      ..finishedSize = 100;
    controller.jobTable.add(job);

    await controller.cancelJob(51);
    controller.tryUpdateJobProgress({
      'id': '51',
      'file_num': '3',
      'speed': '999',
      'finished_size': '900',
    });

    expect(job.state, JobState.cancelRequested);
    expect(job.fileNum, 2);
    expect(job.finishedSize, 100);
  });

  test('terminal cancel state cannot send another cancel request', () async {
    var cancelCalls = 0;
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, __) async => cancelCalls++,
    );
    final job = _activeTransfer(52)..state = JobState.cancelled;
    controller.jobTable.add(job);

    await controller.cancelJob(52);

    expect(cancelCalls, 0);
    expect(job.state, JobState.cancelled);
  });

  test('late done cannot roll a pending cancel forward to success', () async {
    final controller = JobController(
      () => _sessionId,
      () => null,
      cancelTransferJob: (_, __) async {},
    );
    controller.jobTable.add(_activeTransfer(48));

    await controller.cancelJob(48);
    await controller.jobDone({'id': '48', 'file_num': '0', 'speed': '0'});

    expect(controller.jobTable.single.state, JobState.cancelRequested);
  });

  test('reconnect_does_not_duplicate_job', () async {
    final added = <int>[];
    final resumed = <int>[];
    String? restoredOwnershipToken;
    final controller = JobController(
      () => _sessionId,
      () => null,
      addTransferJob:
          (_, jobId, __, ___, ____, _____, ______, ownershipToken) async {
        added.add(jobId);
        restoredOwnershipToken = ownershipToken;
      },
      resumeTransferJob: (_, jobId, __) async => resumed.add(jobId),
    );

    const ownershipToken = '7c026b99-9b89-45f8-9c6d-4467c7f7e9ea';

    await controller.loadLastJob({
      'value': jsonEncode({
        'id': 99,
        'remote': '/remote/save.dat',
        'to': '/local/save.dat',
        'show_hidden': false,
        'file_num': 0,
        'is_remote': true,
        'ownership_token': ownershipToken,
        'auto_start': true,
      })
    });

    expect(added, hasLength(1));
    expect(resumed, isEmpty);
    expect(controller.jobTable, hasLength(1));
    expect(controller.jobTable.single.state, JobState.interrupted);
    expect(controller.jobTable.single.id, isNot(99));
    expect(restoredOwnershipToken, ownershipToken);
  });

  test('resume remains requested until transfer progress confirms activity',
      () async {
    final resumed = <int>[];
    final controller = JobController(
      () => _sessionId,
      () => null,
      resumeTransferJob: (_, jobId, __) async => resumed.add(jobId),
    );
    final job = _activeTransfer(44)..state = JobState.interrupted;
    controller.jobTable.add(job);

    expect(await controller.resumeJob(44), isTrue);
    expect(resumed, [44]);
    expect(job.state, JobState.resumeRequested);

    controller.tryUpdateJobProgress({
      'id': '44',
      'file_num': '0',
      'speed': '1',
      'finished_size': '1',
    });
    expect(job.state, JobState.inProgress);
  });
}
