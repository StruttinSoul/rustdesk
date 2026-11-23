import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteEmulator emu(String state, {String error = ''}) => RemoteEmulator(
    id: 'bluestacks:Main',
    name: 'Main',
    provider: 'bluestacks',
    state: state,
    error: error);

void main() {
  test('a stopped emulator the phone has seen live since the list reads Live',
      () {
    final s = emulatorUiState(emu('stopped'),
        flags: const EmulatorUiFlags(seenLive: true, startRequested: true));
    expect((s.word, s.label), (EmulatorUiWord.live, 'Live'));
    expect(
        emulatorUiState(emu('stopped'),
                flags: const EmulatorUiFlags(seenLive: true, shuttingDown: true))
            .word,
        EmulatorUiWord.stopping);
    expect(emulatorUiState(emu('stopped')).word, EmulatorUiWord.stopped);
  });

  test('stopping wins over every other signal', () {
    final s = emulatorUiState(emu('running'),
        flags: const EmulatorUiFlags(shuttingDown: true, guestFailure: 'x'));
    expect(s.word, EmulatorUiWord.stopping);
    expect(s.label, 'Stopping');
    expect(s.canOpen, isFalse);
    expect(emulatorUiState(emu('stopping')).word, EmulatorUiWord.stopping);
  });
  test('shutdown_failed is a Problem with the PC message or a cause key', () {
    final s = emulatorUiState(emu('shutdown_failed', error: 'Still busy'));
    expect((s.word, s.label, s.causeKey, s.pcMessage),
        (EmulatorUiWord.problem, 'Problem', '', 'Still busy'));
    final t = emulatorUiState(emu('shutdown_failed'));
    expect((t.causeKey, t.pcMessage), ("Couldn't stop", ''));
    expect(t.hasCause, isTrue);
  });
  test('guest failure or failed preview is a Problem', () {
    const failed = RemotePreview('bluestacks:Main', 7, 'failed', 0, 0, 'Encoder died');
    final s = emulatorUiState(emu('running'), preview: failed);
    expect((s.word, s.pcMessage, s.causeKey),
        (EmulatorUiWord.problem, 'Encoder died', 'Stream stopped'));
    const noErr = RemotePreview('bluestacks:Main', 7, 'failed', 0, 0, '');
    final t = emulatorUiState(emu('running'),
        preview: noErr, flags: const EmulatorUiFlags(guestFailure: 'Lost'));
    expect(t.pcMessage, 'Lost');
  });
  test('start requested before the list refreshes reads Starting', () {
    final s = emulatorUiState(emu('stopped'),
        flags: const EmulatorUiFlags(startRequested: true));
    expect(s.word, EmulatorUiWord.starting);
    expect(s.label, 'Starting');
  });
  test('stopped keeps a failed copy message', () {
    final s = emulatorUiState(emu('stopped', error: 'Copy failed'));
    expect((s.word, s.label, s.causeKey, s.pcMessage),
        (EmulatorUiWord.stopped, 'Stopped', '', 'Copy failed'));
    expect(s.canOpen, isTrue);
  });
  test('booting and starting read Starting', () {
    for (final st in ['booting', 'starting']) {
      final s = emulatorUiState(emu(st));
      expect((s.word, s.label, s.causeKey, s.pcMessage),
          (EmulatorUiWord.starting, 'Starting', '', ''));
    }
  });
  test('adb_offline is a Problem', () {
    final s = emulatorUiState(emu('adb_offline', error: 'no adb'));
    expect((s.word, s.label, s.causeKey, s.pcMessage),
        (EmulatorUiWord.problem, 'Problem', 'Android not responding', 'no adb'));
  });
  test('a failed start on a stopped emulator is a Problem with the PC message',
      () {
    final s = emulatorUiState(emu('stopped'),
        flags: const EmulatorUiFlags(guestFailure: 'Boot timed out'));
    expect((s.word, s.pcMessage, s.causeKey),
        (EmulatorUiWord.problem, 'Boot timed out', 'Stream stopped'));
  });
  test('running without a preview slot is Live', () {
    final s = emulatorUiState(emu('running'));
    expect((s.word, s.label), (EmulatorUiWord.live, 'Live'));
    expect(s.hasCause, isFalse);
  });
  test('stalled preview is a Problem, current frame is Live', () {
    const p = RemotePreview('bluestacks:Main', 7, 'streaming', 1080, 1920, '');
    final s = emulatorUiState(emu('running'), preview: p);
    expect((s.word, s.causeKey), (EmulatorUiWord.problem, 'Stream stopped'));
    expect(
        emulatorUiState(emu('running'),
                preview: p,
                flags: const EmulatorUiFlags(frameCurrent: true))
            .word,
        EmulatorUiWord.live);
  });
  test('unknown state never reads Unknown', () {
    final s = emulatorUiState(emu(''));
    expect((s.word, s.causeKey), (EmulatorUiWord.problem, 'Status unavailable'));
    expect(emulatorUiState(emu('weird', error: 'e')).pcMessage, 'e');
  });
}
