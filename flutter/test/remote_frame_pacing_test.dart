import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/remote_frame_pacer.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('unfocused pictures present at 3 fps and focus restores immediately',
      () {
    final pacer = RemoteFramePacer();
    pacer.focused = false;
    var presented = 0;
    for (var ms = 0; ms < 1000; ms += 10) {
      if (pacer.shouldPresent(7, Duration(milliseconds: ms))) presented++;
    }
    expect(presented, 3);
    expect(pacer.shouldPresent(8, const Duration(milliseconds: 990)), isTrue);
    pacer.focused = true;
    expect(pacer.shouldPresent(7, const Duration(milliseconds: 991)), isTrue);
    expect(pacer.shouldPresent(7, const Duration(milliseconds: 992)), isTrue);
    pacer.focused = false;
    expect(pacer.shouldPresent(7, const Duration(milliseconds: 993)), isTrue);
  });

  test('monitor pacing is reapplied after reconnect', () async {
    final sent = <String>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (key, value) async => sent.add(value));
    await model.setMonitorPreviewMode(true);
    model.invalidatePreviewAcknowledgement();
    await model.setMonitorPreviewMode(true);
    expect(sent, ['true', 'true']);
    model.dispose();
    await model.setMonitorPreviewMode(false);
    expect(sent, ['true', 'true']);
  });

  test('failed monitor pacing can be retried', () async {
    var attempts = 0;
    final model =
        EmulatorModel(Uuid().v4obj(), commandSender: (key, value) async {
      if (++attempts == 1) throw StateError('session interrupted');
    });
    await model.setMonitorPreviewMode(true);
    await model.setMonitorPreviewMode(true);
    await model.setMonitorPreviewMode(true);
    expect(attempts, 2);
    model.dispose();
  });

  test('monitor preview pacing is transient, deduplicated and restorable',
      () async {
    final sent = <(String, String)>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (key, value) async => sent.add((key, value)));
    await model.setMonitorPreviewMode(true);
    await model.setMonitorPreviewMode(true);
    await model.setMonitorPreviewMode(false);
    await model.setMonitorPreviewMode(false);
    await model.setMonitorPreviewMode(false, force: true);
    expect(sent, [
      ('dashboard-preview-mode', 'true'),
      ('dashboard-preview-mode', 'false'),
      ('dashboard-preview-mode', 'false'),
    ]);
    model.dispose();
  });
}
