enum CapabilityStatus { supported, unsupported, unknown }

enum RemoteOperationState { idle, pending, applied, failed, unknownOutcome }

class RemoteCapabilitySet {
  const RemoteCapabilitySet._(this._supported, this._negotiated);

  factory RemoteCapabilitySet.fromWire(Object? value) {
    if (value is! List) {
      return const RemoteCapabilitySet._(<String>{}, false);
    }
    return RemoteCapabilitySet._(
      value.whereType<String>().toSet(),
      true,
    );
  }

  final Set<String> _supported;
  final bool _negotiated;

  CapabilityStatus status(String capability) {
    if (!_negotiated) return CapabilityStatus.unknown;
    return _supported.contains(capability)
        ? CapabilityStatus.supported
        : CapabilityStatus.unsupported;
  }

  bool allows(String capability) =>
      status(capability) == CapabilityStatus.supported;
}

class RemoteOperationRecord {
  RemoteOperationRecord({
    required this.requestId,
    required this.operationId,
    required this.sessionIdentity,
    required this.targetIdentity,
    required this.generation,
    required this.action,
  });

  final int requestId;
  final String operationId;
  final String sessionIdentity;
  final String targetIdentity;
  final int generation;
  final String action;
  bool accepted = false;
  RemoteOperationState state = RemoteOperationState.pending;
  String errorCode = '';
  String error = '';
  Object? observedState;
}

class RemoteOperationTracker {
  RemoteOperationTracker({int initialGeneration = 1})
      : _generation = initialGeneration;

  int _generation;
  final Map<int, RemoteOperationRecord> _operations = {};

  int get generation => _generation;

  RemoteOperationRecord begin({
    required int requestId,
    required String operationId,
    required String sessionIdentity,
    required String targetIdentity,
    required String action,
  }) {
    final operation = RemoteOperationRecord(
      requestId: requestId,
      operationId: operationId,
      sessionIdentity: sessionIdentity,
      targetIdentity: targetIdentity,
      generation: _generation,
      action: action,
    );
    _operations[requestId] = operation;
    return operation;
  }

  RemoteOperationRecord? operationForRequest(int requestId) =>
      _operations[requestId];

  bool resolve({
    required int requestId,
    required String operationId,
    required String sessionIdentity,
    required String targetIdentity,
    required int generation,
    required bool accepted,
    required bool applied,
    String errorCode = '',
    String error = '',
    Object? observedState,
  }) {
    final operation = _operations[requestId];
    if (operation == null ||
        operation.state != RemoteOperationState.pending ||
        generation != _generation ||
        operation.generation != generation ||
        operation.operationId != operationId ||
        operation.sessionIdentity != sessionIdentity ||
        operation.targetIdentity != targetIdentity) {
      return false;
    }
    if (applied && !accepted) return false;
    operation.accepted = accepted;
    operation.state =
        applied ? RemoteOperationState.applied : RemoteOperationState.failed;
    operation.errorCode = errorCode;
    operation.error = error;
    operation.observedState = observedState;
    return true;
  }

  bool markTimedOut(int requestId) {
    final operation = _operations[requestId];
    if (operation == null || operation.state != RemoteOperationState.pending) {
      return false;
    }
    operation.state = RemoteOperationState.unknownOutcome;
    return true;
  }

  bool markUnknownOutcome(
    int requestId, {
    String errorCode = '',
    String error = '',
  }) {
    final operation = _operations[requestId];
    if (operation == null || operation.state == RemoteOperationState.applied) {
      return false;
    }
    operation.state = RemoteOperationState.unknownOutcome;
    operation.errorCode = errorCode;
    operation.error = error;
    return true;
  }

  void moveToGeneration(int generation) {
    for (final operation in _operations.values) {
      if (operation.state == RemoteOperationState.pending) {
        operation.state = RemoteOperationState.unknownOutcome;
      }
    }
    _generation = generation;
  }

  void advanceGeneration() {
    moveToGeneration(_generation + 1);
  }
}
