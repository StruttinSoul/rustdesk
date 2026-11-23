import 'dart:convert';

import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

Future<EmulatorModel> _opened(int width, int height) async {
  final sent = <Map<String, dynamic>>[];
  final model = EmulatorModel(Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)));
  await model.connect('bluestacks:Tiramisu64_4');
  final select = sent.last['request_id'];
  for (final (state, w, h) in [('starting', 0, 0), ('streaming', width, height)]) {
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 7,
      'target_id': 'bluestacks:Tiramisu64_4',
      'state': state,
      'width': w,
      'height': h,
    });
  }
  return model;
}

void main() {
  // The PC's full-screen profile sends 1920 on the long edge.
  for (final (w, h) in [(1080, 1920), (1920, 886), (1280, 590), (2048, 944)]) {
    test('a $w x $h stream opens full screen', () async {
      final model = await _opened(w, h);
      expect(model.streaming, isTrue);
      expect(model.connecting, isFalse);
      expect((model.width, model.height), (w, h));
      model.dispose();
    });
  }

  for (final (w, h) in [(2049, 944), (944, 2049), (0, 720)]) {
    test('an invalid $w x $h stream is ignored', () async {
      final model = await _opened(w, h);
      expect(model.streaming, isFalse);
      model.dispose();
    });
  }
}
