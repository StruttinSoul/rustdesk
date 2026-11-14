import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/clipboard_transfer_sheet.dart';
import 'package:flutter_hbb/models/clipboard_transfer_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late ClipboardTransferContext context;
  late List<Map<String, dynamic>> sent;

  ClipboardTransferModel createModel({
    Future<void> Function(String key, String value)? sender,
  }) {
    sent = <Map<String, dynamic>>[];
    return ClipboardTransferModel(
      const Uuid().v4obj(),
      contextProvider: () => context,
      commandSender: sender ??
          (key, value) async {
            sent.add(jsonDecode(value) as Map<String, dynamic>);
          },
    );
  }

  setUp(() {
    context = const ClipboardTransferContext(
      targetIdentity: 'peer:jarvis',
      generation: 7,
      authenticated: true,
      capabilitySupported: true,
      permissionGranted: true,
    );
  });

  test('denied clipboard stays denied without sending a request', () async {
    context = context.copyWith(permissionGranted: false);
    final model = createModel();
    addTearDown(model.dispose);

    model.stagePhoneToHost('private text');
    expect(await model.copyPreviewToHost(), isFalse);
    expect(sent, isEmpty);
    expect(model.errorCode, 'clipboard_permission_denied');
  });

  test('target change invalidates preview and ignores the late host reply',
      () async {
    final model = createModel();
    addTearDown(model.dispose);

    expect(await model.requestHostToPhone(), isTrue);
    final request = sent.single;
    context = context.copyWith(
      targetIdentity: 'peer:other',
      generation: 8,
    );
    model.onContextChanged();

    model.handleResponse(<String, dynamic>{
      'request_id': request['request_id'],
      'direction': 'host_to_phone',
      'accepted': true,
      'applied': true,
      'text': 'late host clipboard',
      'target_identity': 'peer:jarvis',
      'error_code': '',
      'error': '',
    });

    expect(model.preview, isNull);
    expect(model.pending, isFalse);
  });

  test('permission revocation clears an ephemeral preview', () {
    final model = createModel();
    addTearDown(model.dispose);
    model.stagePhoneToHost('private text');
    expect(model.preview, isNotNull);

    context = context.copyWith(permissionGranted: false);
    model.onContextChanged();

    expect(model.preview, isNull);
    expect(model.pending, isFalse);
  });

  test('pending transfer cannot be replaced by a new phone clipboard read',
      () async {
    final model = createModel();
    addTearDown(model.dispose);
    expect(model.stagePhoneToHost('first'), isTrue);
    expect(await model.copyPreviewToHost(), isTrue);
    expect(model.pending, isTrue);

    expect(model.stagePhoneToHost('second'), isFalse);
    expect(model.preview?.text, 'first');
    expect(model.pending, isTrue);
  });

  test('clipboard request times out without retrying or losing staged text',
      () async {
    var attempts = 0;
    final model = ClipboardTransferModel(
      const Uuid().v4obj(),
      contextProvider: () => context,
      requestTimeout: const Duration(milliseconds: 10),
      commandSender: (key, value) async {
        attempts++;
      },
    );
    addTearDown(model.dispose);
    expect(model.stagePhoneToHost('keep me'), isTrue);
    expect(await model.copyPreviewToHost(), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(attempts, 1);
    expect(model.pending, isFalse);
    expect(model.preview?.text, 'keep me');
    expect(model.errorCode, 'clipboard_timeout');
  });

  test('late response after reconnect generation changes is discarded',
      () async {
    final model = createModel();
    addTearDown(model.dispose);
    expect(await model.requestHostToPhone(), isTrue);
    final request = sent.single;
    context = context.copyWith(generation: context.generation + 1);

    model.handleResponse(<String, dynamic>{
      'request_id': request['request_id'],
      'direction': 'host_to_phone',
      'accepted': true,
      'applied': true,
      'text': 'stale',
      'target_identity': 'peer:jarvis',
      'error_code': '',
      'error': '',
    });

    expect(model.preview, isNull);
    expect(model.pending, isFalse);
  });

  test('permission is revalidated when the PC response arrives', () async {
    final model = createModel();
    addTearDown(model.dispose);
    expect(await model.requestHostToPhone(), isTrue);
    final request = sent.single;
    context = context.copyWith(permissionGranted: false);

    model.handleResponse(<String, dynamic>{
      'request_id': request['request_id'],
      'direction': 'host_to_phone',
      'accepted': true,
      'applied': true,
      'text': 'must not surface',
      'target_identity': 'peer:jarvis',
      'error_code': '',
      'error': '',
    });

    expect(model.preview, isNull);
    expect(model.pending, isFalse);
    expect(model.errorCode, 'clipboard_permission_denied');
  });

  test('client refuses clipboard text larger than one MiB', () {
    final model = createModel();
    addTearDown(model.dispose);
    final oversized = List<String>.filled(
      kManualClipboardMaxBytes + 1,
      'a',
      growable: false,
    ).join();

    expect(model.stagePhoneToHost(oversized), isFalse);
    expect(model.preview, isNull);
    expect(model.errorCode, 'clipboard_too_large');
  });

  test('host clipboard becomes an exact preview before local Copy', () async {
    final model = createModel();
    addTearDown(model.dispose);
    const text = 'one\n二\r\n🙂';

    expect(await model.requestHostToPhone(), isTrue);
    final request = sent.single;
    model.handleResponse(<String, dynamic>{
      'request_id': request['request_id'],
      'direction': 'host_to_phone',
      'accepted': true,
      'applied': true,
      'text': text,
      'target_identity': 'peer:jarvis',
      'error_code': '',
      'error': '',
    });

    expect(model.preview?.direction, ClipboardTransferDirection.hostToPhone);
    expect(model.preview?.text, text);
    expect(model.pending, isFalse);
    expect(model.message, 'Ready to copy to this phone.');
  });

  test('copy-to-phone completion revalidates permission and scope', () async {
    final model = createModel();
    addTearDown(model.dispose);
    expect(await model.requestHostToPhone(), isTrue);
    final request = sent.single;
    model.handleResponse(<String, dynamic>{
      'request_id': request['request_id'],
      'direction': 'host_to_phone',
      'accepted': true,
      'applied': true,
      'text': 'host text',
      'target_identity': 'peer:jarvis',
      'error_code': '',
      'error': '',
    });
    final preview = model.preview!;
    expect(model.canCopyPreviewToPhone(preview), isTrue);

    context = context.copyWith(permissionGranted: false);

    expect(model.markCopiedToPhone(preview), isFalse);
    expect(model.preview, isNull);
  });

  test('transport failure is not retried and keeps the staged phone text',
      () async {
    var attempts = 0;
    final model = createModel(sender: (key, value) async {
      attempts++;
      throw StateError('transport down');
    });
    addTearDown(model.dispose);

    model.stagePhoneToHost('keep me');
    expect(await model.copyPreviewToHost(), isFalse);

    expect(attempts, 1);
    expect(model.preview?.text, 'keep me');
    expect(model.pending, isFalse);
    expect(model.errorCode, 'clipboard_transport_failed');
  });

  testWidgets('clipboard sheet exposes copy actions but no paste or execute',
      (tester) async {
    final model = createModel();
    addTearDown(model.dispose);
    model.stagePhoneToHost('echo one\necho two');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClipboardTransferSheet(
          model: model,
          targetLabel: 'Jarvis',
          initialDirection: ClipboardTransferDirection.phoneToHost,
        ),
      ),
    ));

    expect(find.text('Target: Jarvis'), findsOneWidget);
    expect(find.text('Copy to PC'), findsOneWidget);
    expect(find.textContaining('Paste'), findsNothing);
    expect(find.textContaining('Run'), findsNothing);
    expect(find.textContaining('Execute'), findsNothing);
  });
}
