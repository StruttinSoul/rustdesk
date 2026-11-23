import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final _sessionId = UuidValue('00000000-0000-0000-0000-000000000000');

class _FakeFFI implements FFI {
  @override
  UuidValue get sessionId => _sessionId;

  @override
  late final FfiModel ffiModel = FfiModel(WeakReference(this));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('the quality monitor names the WebRTC transport only on web', () {
    final ffi = _FakeFFI();
    ffi.ffiModel.cachedPeerData.streamType = 'WebRTC';
    final model = QualityMonitorModel(WeakReference(ffi));
    // Off the web the session tab's tooltip already names the transport.
    expect(isWeb, isFalse);
    expect(model.webrtcTransport, isNull);
  });

  test('explicitly unavailable telemetry does not keep an old value', () {
    final ffi = _FakeFFI();
    final model = QualityMonitorModel(WeakReference(ffi));

    model.updateQualityStatus({
      'speed': '4.2 MB/s',
      'delay': '28',
    });
    expect(model.data.speed, '4.2 MB/s');
    expect(model.data.delay, '28');

    model.updateQualityStatus({
      'speed': '',
      'delay': '',
    });
    expect(model.data.speed, isNull);
    expect(model.data.delay, isNull);
  });

  test('reconnect continuity generation advances immediately', () {
    final ffi = _FakeFFI();
    expect(ffi.ffiModel.reconnectGeneration, 0);

    ffi.ffiModel.markReconnectStarted();

    expect(ffi.ffiModel.reconnectGeneration, 1);
  });

  test('the per-second status fills FPS, codec and chroma', () {
    final ffi = _FakeFFI();
    final model = QualityMonitorModel(WeakReference(ffi));

    // As the io_loop sends it every second (src/flutter.rs).
    model.updateQualityStatus({
      'speed': '512.00kB/s',
      'fps': '{"0":30}',
      'delay': '',
      'target_bitrate': '',
      'codec_format': 'H265',
      'chroma': '4:2:0',
    });

    expect(model.data.fps, '30');
    expect(model.data.codecFormat, 'H265');
    expect(model.data.chroma, '4:2:0');
  });
}

