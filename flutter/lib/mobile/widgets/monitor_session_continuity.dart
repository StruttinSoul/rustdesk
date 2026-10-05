bool monitorFrameIsCurrent({
  required int previewRequest,
  required int acknowledgedRequest,
  required int? frameRequest,
}) =>
    previewRequest != 0 &&
    acknowledgedRequest == previewRequest &&
    frameRequest == previewRequest;

class MonitorInputEpoch {
  int _value = 0;

  int capture() => _value;

  void invalidate() {
    _value++;
  }

  bool accepts(int value) => value == _value;
}
