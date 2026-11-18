import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';
import 'package:flutter_hbb/mobile/widgets/avd_settings_sheet.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_action_sheet.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'support/fake_translate.dart';

const _allCaps = [
  'operation.identity.v1',
  'operation.ack.v1',
  'host.emulator_shutdown.v1',
  'host.avd_manage.v1',
  'host.emulator_power.v1',
  'host.avd_settings.v1',
];

Map<String, dynamic> _inst(String id, String state, {String provider = 'avd'}) => {
      'target_id': id,
      'provider': provider,
      'name': id.split(':').last,
      'state': state,
      'progress_percent': state == 'cloning' ? 10 : 0,
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
        _inst('avd:Maple_1', 'ready'),
        _inst('bluestacks:Pie64', 'running', provider: 'bluestacks'),
        _inst('avd:Off', 'stopped'),
        _inst('avd:Copy', 'cloning'),
      ]);
      expect(model.canRebootEmulator('avd:Maple_1'), isTrue);
      expect(model.canRebootEmulator('bluestacks:Pie64'), isTrue);
      expect(model.canRebootEmulator('avd:Off'), isFalse);
      expect(model.canRebootEmulator('avd:Copy'), isFalse);
      model.dispose();

      final older = <Map<String, dynamic>>[];
      final old = await _connected(older, [_inst('avd:Maple_1', 'ready')],
          capabilities: _allCaps.where((c) => c != 'host.emulator_power.v1').toList());
      expect(old.canRebootEmulator('avd:Maple_1'), isFalse);
      final before = older.length;
      final outcome = await old.rebootEmulator('avd:Maple_1');
      expect(outcome.ok, isFalse);
      expect(older.length, before);
      old.dispose();
    });

    test('sends an identified request and reports the PC answer', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(
          sent, [_inst('bluestacks:Pie64', 'running', provider: 'bluestacks')]);
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

  group('settings', () {
    test('are read for a managed emulator', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [_inst('avd:Maple_1', 'ready')]);
      expect(model.canChangeAvdSettings('avd:Maple_1'), isTrue);
      final result = model.loadAvdSettings('avd:Maple_1');
      await Future<void>.delayed(Duration.zero);
      final request = Map<String, dynamic>.from(sent.last);
      expect(request['action'], 'avd_settings_get');
      expect(request['component'], 'avd:Maple_1');
      model.handleResponse(_reply(request, {
        'ok': true,
        'avd_settings': {
          'current': {
            'ram_mb': 4096,
            'cpu_cores': 4,
            'screen_width': 1080,
            'screen_height': 2208
          },
          'pending': {'ram_mb': 6144},
          'running': true,
        },
      }));
      final loaded = await result;
      expect(loaded.error, isEmpty);
      final info = loaded.info!;
      expect(info.running, isTrue);
      expect(info.current.ramMb, 4096);
      expect(info.pending.ramMb, 6144);
      expect(info.pending.cores, isNull);
      expect(info.next.ramMb, 6144);
      expect(info.next.cores, 4);
      expect(info.next.screen, (1080, 2208));
      model.dispose();
    });

    test('a failed read says why', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [_inst('avd:Maple_1', 'stopped')]);
      final result = model.loadAvdSettings('avd:Maple_1');
      await Future<void>.delayed(Duration.zero);
      model.handleResponse(_reply(Map<String, dynamic>.from(sent.last),
          {'ok': false, 'error': 'Maple_1 is not in Aperture\'s emulator folder'}));
      final loaded = await result;
      expect(loaded.info, isNull);
      expect(loaded.error, contains('emulator folder'));
      model.dispose();
    });

    test('are only for managed emulators on a PC that offers them', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [
        _inst('avd:Maple_1', 'ready'),
        _inst('bluestacks:Pie64', 'running', provider: 'bluestacks'),
      ], capabilities: _allCaps.where((c) => c != 'host.avd_settings.v1').toList());
      expect(model.canChangeAvdSettings('avd:Maple_1'), isFalse);
      model.dispose();

      final sent2 = <Map<String, dynamic>>[];
      final full = await _connected(sent2, [
        _inst('bluestacks:Pie64', 'running', provider: 'bluestacks'),
      ]);
      expect(full.canChangeAvdSettings('bluestacks:Pie64'), isFalse);
      final before = sent2.length;
      expect((await full.loadAvdSettings('bluestacks:Pie64')).info, isNull);
      expect(sent2.length, before);
      full.dispose();
    });

    test('save sends only the changed values and works while running', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [_inst('avd:Maple_1', 'ready')]);
      expect(model.avdActionBlocker('avd:Maple_1', 'avd_settings_set'), isNull);
      final result = model.saveAvdSettings(
          'avd:Maple_1', const AvdSettings(ramMb: 6144, screen: (1080, 2400)),
          restart: true);
      await Future<void>.delayed(Duration.zero);
      final request = Map<String, dynamic>.from(sent.last);
      expect(request['action'], 'avd_settings_set');
      expect(request['component'], 'avd:Maple_1');
      expect(request['ram_mb'], 6144);
      expect(request['cpu_cores'], 0);
      expect(request['screen_width'], 1080);
      expect(request['screen_height'], 2400);
      expect(request['restart'], isTrue);
      expect(request['target_identity'], 'emulator:avd:Maple_1');
      model.handleResponse(_reply(request,
          {'ok': true, 'accepted': true, 'message': 'Restarting Maple_1'}));
      expect((await result).ok, isTrue);
      model.dispose();
    });

    test('a copy in progress blocks saving', () async {
      final sent = <Map<String, dynamic>>[];
      final model = await _connected(sent, [_inst('avd:Copy', 'cloning')]);
      expect(model.avdActionBlocker('avd:Copy', 'avd_settings_set'),
          'Copy in progress');
      final before = sent.length;
      final outcome =
          await model.saveAvdSettings('avd:Copy', const AvdSettings(cores: 2));
      expect(outcome.ok, isFalse);
      expect(sent.length, before);
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

    EmulatorActionSheet sheet(
            {bool stopped = false,
            VoidCallback? onReboot,
            AvdCardActions? avd}) =>
        EmulatorActionSheet(
          title: 'Maple_1',
          subtitle: 'Android Emulator',
          state: stopped
              ? const EmulatorUiState(EmulatorUiWord.stopped, 'Stopped')
              : const EmulatorUiState(EmulatorUiWord.live, 'Live'),
          stopped: stopped,
          onOpen: () {},
          onStop: () {},
          onReboot: onReboot,
          onLabel: () {},
          avd: avd,
          tr: fakeTr,
        );

    ListTile tile(WidgetTester tester, String text) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, text));

    testWidgets('a running emulator offers Stop, Reboot and Settings',
        (tester) async {
      var reboots = 0;
      var settings = 0;
      await open(
          tester,
          sheet(
              onReboot: () => reboots++,
              avd: AvdCardActions(
                running: true,
                blocker: 'Stop it first',
                onSettings: () => settings++,
                onClone: () {},
              )));
      expect(tile(tester, 'Stop').enabled, isTrue);
      expect(tile(tester, 'Reboot').enabled, isTrue);
      expect(tile(tester, 'Settings').enabled, isTrue,
          reason: 'settings save while running and apply at the next start');
      final rows = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => ((t.title as Text).data ?? ''))
          .toList();
      expect(rows.indexOf('Reboot'), rows.indexOf('Stop') + 1);
      await tester.tap(find.text('Reboot'));
      await tester.pumpAndSettle();
      expect(reboots, 1);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(settings, 1);
    });

    testWidgets('a stopped emulator offers Start but no Reboot', (tester) async {
      await open(
          tester,
          sheet(
              stopped: true,
              onReboot: () {},
              avd: AvdCardActions(onSettings: () {})));
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Reboot'), findsNothing);
      expect(find.text('Stop'), findsNothing);
      expect(tile(tester, 'Settings').enabled, isTrue);
    });

    testWidgets('a copy in progress blocks Settings', (tester) async {
      await open(
          tester,
          sheet(
              stopped: true,
              avd: AvdCardActions(
                  cloningLabel: 'Cloning 10%', onSettings: () {})));
      expect(tile(tester, 'Settings').enabled, isFalse);
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

    testWidgets('Save and restart asks first', (tester) async {
      bool? answer;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async => answer =
                          await showEmulatorRestartConfirmation(
                              context, 'Maple_1',
                              tr: fakeTr),
                      child: const Text('go'))))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Restart Maple_1?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
    });
  });

  group('settings sheet', () {
    const info = AvdSettingsInfo(
      current: AvdSettings(ramMb: 4096, cores: 4, screen: (1080, 2208)),
      pending: AvdSettings(),
      running: true,
    );

    Future<void> show(WidgetTester tester, AvdSettingsInfo info,
        {double scale = 1.0}) async {
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => showAvdSettingsSheet(context,
                            name: 'Maple_1', info: info, tr: fakeTr),
                        child: const Text('go'))))),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('a running emulator can save or save and restart',
        (tester) async {
      AvdSettingsChoice? choice;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () async => choice = await showAvdSettingsSheet(
                            context,
                            name: 'Maple_1',
                            info: info,
                            tr: fakeTr),
                        child: const Text('go'))))),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Memory'), findsOneWidget);
      expect(find.text('CPU cores'), findsOneWidget);
      expect(find.text('Screen'), findsOneWidget);
      expect(find.text('Changes apply the next time it starts.'), findsOneWidget);
      FilledButton restart() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Save and restart'));
      expect(restart().onPressed, isNull, reason: 'nothing changed yet');
      await tester.tap(find.text('6 GB'));
      await tester.tap(find.text('1080 × 2400'));
      await tester.pumpAndSettle();
      expect(restart().onPressed, isNotNull);
      expect(find.widgetWithText(TextButton, 'Save'), findsOneWidget);
      await tester.tap(find.text('Save and restart'));
      await tester.pumpAndSettle();
      expect(choice, isNotNull);
      expect(choice!.restart, isTrue);
      expect(choice!.change.ramMb, 6144);
      expect(choice!.change.cores, isNull);
      expect(choice!.change.screen, (1080, 2400));
    });

    testWidgets('a stopped emulator only saves', (tester) async {
      AvdSettingsChoice? choice;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () async => choice = await showAvdSettingsSheet(
                            context,
                            name: 'Maple_1',
                            info: const AvdSettingsInfo(
                                current: AvdSettings(
                                    ramMb: 4096, cores: 4, screen: (1080, 2208)),
                                pending: AvdSettings(),
                                running: false),
                            tr: fakeTr),
                        child: const Text('go'))))),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Save and restart'), findsNothing);
      expect(find.text('Changes apply the next time it starts.'), findsNothing);
      await tester.tap(find.text('8'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(choice!.restart, isFalse);
      expect(choice!.change.cores, 8);
      expect(choice!.change.ramMb, isNull);
    });

    testWidgets('saved changes still to apply are shown selected',
        (tester) async {
      await show(
          tester,
          const AvdSettingsInfo(
              current: AvdSettings(ramMb: 4096, cores: 4, screen: (1080, 2208)),
              pending: AvdSettings(ramMb: 8192),
              running: true));
      final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '8 GB'));
      expect(chip.selected, isTrue);
      expect(find.text('Saved changes apply the next time it starts.'),
          findsOneWidget);
    });

    testWidgets('is usable at 1.75 text scale', (tester) async {
      await show(tester, info, scale: 1.75);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Save and restart'));
      expect(find.text('Save and restart'), findsOneWidget);
    });
  });
}
