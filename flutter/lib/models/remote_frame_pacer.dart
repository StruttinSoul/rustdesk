/// Paces image presentation without discarding compressed reference frames.
class RemoteFramePacer {
  bool _focused = true;
  final Map<int, Duration> _lastPresented = {};

  set focused(bool value) {
    if (_focused == value) return;
    _focused = value;
    _lastPresented.clear();
  }

  bool shouldPresent(int channel, Duration elapsed) {
    if (_focused) return true;
    final previous = _lastPresented[channel];
    if (previous != null &&
        elapsed - previous < const Duration(microseconds: 333334)) {
      return false;
    }
    _lastPresented[channel] = elapsed;
    return true;
  }
}
