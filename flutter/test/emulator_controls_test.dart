import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_action_sheet.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'support/fake_translate.dart';

const _allCaps = [
  'operation.identity.v1',
  'operation.ack.v1',
  'host.emulator_shutdown.v1',
  'host.emulator_power.v1',
  'host.emulator_window.v1',
];

Map<String, dynamic> _inst(String id, String state,
        {String provider = 'bluestacks'}) =>
    {
      'target_id': id,
      'provider': provider,
      'name': id.split(':').last,
      'state': state,
    };

Future<EmulatorModel> _connected(
    List<Map<String, dynamic>> sent, List<Map<String, dynamic>> instances,
    {List<String> capabilities = _allCaps}) async {
  final model = EmulatorModel(Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)));
  await model.refresh();
  model.handleResponse({
    'type': 'inventory',
    'request_id': sent.single['request_id'],
    'protocol_version': 1,
    'instances': instances,
    'provider_errors': const [],
    'capabilities': capabilities,
    'operation_session_identity': 'scope-ctl',
    'operation_generation': 3,
  });
  return model;
}

Map<String, dynamic> _reply(Map<String, dynamic> request, Map<String, dynamic> host) => {
      'type': 'host',
      'request_id': request['request_id'],
      'protocol_version': 1,
      'host': {
        ...host,
        if (request['operation_id'] != null) ...{
          'operation_id': request['operation_id'],
          'session_identity': 'scope-ctl',
          'target_identity': request['target_identity'],
          'session_generation': 3,
          'state': host['ok'] == true ? 'applied' : 'failed',
        },
      },
    };

void main() {
  group('reboot', () {
    test('needs the power capability and a running emulator', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [
        _inst('bluestacks:Pie64', 'running'),
        _inst('bluestacks:Off', 'stopped'),
        _inst('avd:Maple_1', 'ready', provider: 'avd'),
      ]);
      expect(model.canRebootEmulator('bluestacks:Pie64'), isTrue);
      expect(model.canRebootEmulator('bluestacks:Off'), isFalse);
      expect(model.canRebootEmulator('avd:Maple_1'), isFalse,
          reason: 'an older PC may still list Android Emulators');
      model.dispose();

      final older = <Map<String, dynamic>>[];
      final old = await _connected(older, [_inst('bluestacks:Pie64', 'running')],
          capabilities: _allCaps.where((c) => c != 'host.emulator_power.v1').toList());
      expect(old.canRebootEmulator('bluestacks:Pie64'), isFalse);
      final before = older.length;
      final outcome = await old.rebootEmulator('bluestacks:Pie64');
      expect(outcome.ok, isFalse);
      expect(older.length, before);
      old.dispose();
    });

    test('sends an identified request and reports the PC answer', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [_inst('bluestacks:Pie64', 'running')]);
      final result = model.rebootEmulator('bluestacks:Pie64');
      await Future<void>.delayed(Duration.zero);
      final request = Map<String, dynamic>.from(sent.last);
      expect(request['action'], 'emulator_reboot');
      expect(request['component'], 'bluestacks:Pie64');
      expect(request['target_identity'], 'emulator:bluestacks:Pie64');
      expect(request['session_identity'], 'scope-ctl');
      expect(request['session_generation'], 3);
      expect((request['operation_id'] as String).isNotEmpty, isTrue);
      model.handleResponse(_reply(request,
          {'ok': true, 'accepted': true, 'message': 'Restarting Android in Pie64…'}));
      final outcome = await result;
      expect(outcome.ok, isTrue);
      expect(outcome.message, 'Restarting Android in Pie64…');
      expect(sent.last['action'], 'list', reason: 'the list is refreshed');
      model.dispose();
    });
  });

  group('show on PC', () {
    test('is not offered while no provider supports it', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [_inst('bluestacks:Pie64', 'running')]);
      expect(model.canShowOnPc('bluestacks:Pie64'), isFalse);
      final before = sent.length;
      final outcome =
          await model.setEmulatorWindowVisible('bluestacks:Pie64', true);
      expect(outcome.ok, isFalse);
      expect(sent.length, before, reason: 'nothing is sent');
      model.dispose();
    });

    test('the listed window state is read', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [
        {..._inst('bluestacks:Pie64', 'running'), 'window_visible': true},
        _inst('bluestacks:Other', 'running'),
      ]);
      expect(model.instances.first.windowVisible, isTrue);
      expect(model.instances.last.windowVisible, isFalse);
      model.dispose();
    });
  });

  group('action sheet', () {
    Future<void> open(WidgetTester tester, EmulatorActionSheet sheet) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => showEmulatorActionSheet(context, sheet),
                        child: const Text('go'))))),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    EmulatorActionSheet sheet({bool stopped = false, VoidCallback? onReboot}) =>
        EmulatorActionSheet(
          title: 'Pie64',
          subtitle: 'BlueStacks',
          state: stopped
              ? const EmulatorUiState(EmulatorUiWord.stopped, 'Stopped')
              : const EmulatorUiState(EmulatorUiWord.live, 'Live'),
          stopped: stopped,
          onOpen: () {},
          onStop: () {},
          onReboot: onReboot,
          onLabel: () {},
          tr: fakeTr,
        );

    ListTile tile(WidgetTester tester, String text) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, text));

    testWidgets('a running emulator offers Stop, then Reboot', (tester) async {
      var reboots = 0;
      await open(tester, sheet(onReboot: () => reboots++));
      expect(tile(tester, 'Stop').enabled, isTrue);
      expect(tile(tester, 'Reboot').enabled, isTrue);
      final rows = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => ((t.title as Text).data ?? ''))
          .toList();
      expect(rows.indexOf('Reboot'), rows.indexOf('Stop') + 1);
      await tester.tap(find.text('Reboot'));
      await tester.pumpAndSettle();
      expect(reboots, 1);
    });

    testWidgets('a stopped emulator offers Start but no Reboot', (tester) async {
      await open(tester, sheet(stopped: true, onReboot: () {}));
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Reboot'), findsNothing);
      expect(find.text('Stop'), findsNothing);
    });

    testWidgets('BlueStacks has Reboot and no Settings', (tester) async {
      await open(tester, sheet(onReboot: () {}));
      expect(tile(tester, 'Reboot').enabled, isTrue);
      expect(find.text('Settings'), findsNothing);
    });
  });

  group('confirmations', () {
    Future<bool?> confirm(WidgetTester tester,
        Future<bool> Function(BuildContext) ask, String button) async {
      bool? answer;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async => answer = await ask(context),
                      child: const Text('go'))))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, button));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('Reboot asks first', (tester) async {
      final answer = await confirm(
          tester,
          (context) =>
              showEmulatorRebootConfirmation(context, 'Maple_1', tr: fakeTr),
          'Reboot');
      expect(answer, isTrue);
    });
  });
}
