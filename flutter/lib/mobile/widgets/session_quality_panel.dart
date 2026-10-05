import 'package:flutter/material.dart';

import '../../consts.dart';
import '../../models/model.dart';

enum MirpgQualityProfile { auto, sharpText, smoothMotion }

String mirpgQualityProfileLabel(MirpgQualityProfile profile) {
  switch (profile) {
    case MirpgQualityProfile.auto:
      return 'Auto';
    case MirpgQualityProfile.sharpText:
      return 'Sharp text';
    case MirpgQualityProfile.smoothMotion:
      return 'Smooth motion';
  }
}

String mirpgQualityProfileDescription(MirpgQualityProfile profile) {
  switch (profile) {
    case MirpgQualityProfile.auto:
      return 'Uses RustDesk Balanced quality for an adaptive everyday profile.';
    case MirpgQualityProfile.sharpText:
      return 'Uses RustDesk Good image quality to favor readable detail.';
    case MirpgQualityProfile.smoothMotion:
      return 'Uses RustDesk Optimize reaction time to favor responsiveness.';
  }
}

String mirpgQualityProfileValue(MirpgQualityProfile profile) {
  switch (profile) {
    case MirpgQualityProfile.auto:
      return kRemoteImageQualityBalanced;
    case MirpgQualityProfile.sharpText:
      return kRemoteImageQualityBest;
    case MirpgQualityProfile.smoothMotion:
      return kRemoteImageQualityLow;
  }
}

MirpgQualityProfile mirpgQualityProfileFromStored(String raw) {
  for (final profile in MirpgQualityProfile.values) {
    if (profile.name == raw) return profile;
  }
  return MirpgQualityProfile.auto;
}

MirpgQualityProfile mirpgQualityProfileFromEffective(String? value) {
  switch (value) {
    case kRemoteImageQualityBest:
      return MirpgQualityProfile.sharpText;
    case kRemoteImageQualityLow:
      return MirpgQualityProfile.smoothMotion;
    case kRemoteImageQualityBalanced:
    default:
      return MirpgQualityProfile.auto;
  }
}

String rustDeskQualityLabel(String? value) {
  switch (value) {
    case kRemoteImageQualityBest:
      return 'Good image quality';
    case kRemoteImageQualityBalanced:
      return 'Balanced';
    case kRemoteImageQualityLow:
      return 'Optimize reaction time';
    case kRemoteImageQualityCustom:
      return 'Custom';
    case null:
    case '':
      return 'Unavailable';
    default:
      return value;
  }
}

bool qualityMetricIsFresh(DateTime? updatedAt, DateTime now,
    {Duration staleAfter = const Duration(seconds: 6)}) {
  if (updatedAt == null) return false;
  final age = now.difference(updatedAt);
  return !age.isNegative && age <= staleAfter;
}

int? qualityDelayMs(String? value) {
  if (value == null || value.isEmpty) return null;
  final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(value);
  if (match == null) return null;
  final parsed = double.tryParse(match.group(0)!);
  return parsed?.round();
}

bool qualityConnectionIsSlow(QualityMonitorData data, DateTime now) {
  if (!qualityMetricIsFresh(data.delayUpdatedAt, now)) return false;
  final delay = qualityDelayMs(data.delay);
  return delay != null && delay >= 250;
}

String _metricValue(String? value, DateTime? updatedAt, DateTime now,
    {String suffix = ''}) {
  if (value == null || value.isEmpty) return 'Unavailable';
  final rendered = '$value$suffix';
  return qualityMetricIsFresh(updatedAt, now) ? rendered : '$rendered · stale';
}

class SessionStatusButton extends StatelessWidget {
  const SessionStatusButton({
    super.key,
    required this.direct,
    required this.data,
    required this.now,
    this.onPressed,
  });

  final bool? direct;
  final QualityMonitorData data;
  final DateTime now;
  final VoidCallback? onPressed;

  String get _transport => direct == null
      ? 'Connecting'
      : direct!
          ? 'Direct'
          : 'Relay';

  String get _label {
    if (direct == null) return _transport;
    if (qualityConnectionIsSlow(data, now)) {
      final delay = qualityDelayMs(data.delay);
      return '$_transport · ${delay ?? '?'} ms';
    }
    if (qualityMetricIsFresh(data.delayUpdatedAt, now)) {
      final delay = qualityDelayMs(data.delay);
      if (delay != null) return '$_transport · $delay ms';
    }
    if (data.latestUpdatedAt != null &&
        !qualityMetricIsFresh(data.latestUpdatedAt, now)) {
      return '$_transport · stale';
    }
    return _transport;
  }

  @override
  Widget build(BuildContext context) {
    final slow = qualityConnectionIsSlow(data, now);
    final foreground = Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onSurface;
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: foreground),
      icon: Icon(slow ? Icons.network_check : Icons.lan_outlined, size: 18),
      label: Text(_label),
    );
  }
}

class SessionQualityConnectionSheet extends StatelessWidget {
  const SessionQualityConnectionSheet({
    super.key,
    required this.preferredProfile,
    required this.effectiveQuality,
    required this.applying,
    required this.direct,
    required this.data,
    required this.now,
    required this.onProfileChanged,
    this.error = '',
  });

  final MirpgQualityProfile preferredProfile;
  final String? effectiveQuality;
  final bool applying;
  final bool? direct;
  final QualityMonitorData data;
  final DateTime now;
  final ValueChanged<MirpgQualityProfile> onProfileChanged;
  final String error;

  Widget _metric(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 118,
                child:
                    Text(label, style: Theme.of(context).textTheme.bodyMedium)),
            const SizedBox(width: 12),
            Expanded(
                child: Text(value,
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final transport = direct == null
        ? 'Connecting'
        : direct!
            ? 'Direct'
            : 'Relay';
    final latest = data.latestUpdatedAt;
    final slow = qualityConnectionIsSlow(data, now);
    final telemetryState = latest == null
        ? 'No stream telemetry yet'
        : qualityMetricIsFresh(latest, now)
            ? 'Telemetry current'
            : 'Telemetry stale';

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Quality & connection',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              slow
                  ? '$transport · Connection slow'
                  : '$transport · $telemetryState',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            Text('Quality profile',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            for (final profile in MirpgQualityProfile.values)
              RadioListTile<MirpgQualityProfile>(
                contentPadding: EdgeInsets.zero,
                value: profile,
                groupValue: preferredProfile,
                onChanged: applying
                    ? null
                    : (value) {
                        if (value != null) onProfileChanged(value);
                      },
                title: Text(mirpgQualityProfileLabel(profile)),
                subtitle: Text(mirpgQualityProfileDescription(profile)),
              ),
            if (applying) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            _metric(context, 'Preferred',
                mirpgQualityProfileLabel(preferredProfile)),
            _metric(
                context, 'Effective', rustDeskQualityLabel(effectiveQuality)),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const Divider(height: 28),
            Text('Session health',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _metric(context, 'Transport', transport),
            _metric(
                context,
                'Latency',
                _metricValue(data.delay, data.delayUpdatedAt, now,
                    suffix: ' ms')),
            _metric(context, 'FPS',
                _metricValue(data.fps, data.fpsUpdatedAt, now, suffix: ' fps')),
            _metric(context, 'Receive',
                _metricValue(data.speed, data.speedUpdatedAt, now)),
            _metric(
                context,
                'Target bitrate',
                _metricValue(
                    data.targetBitrate, data.targetBitrateUpdatedAt, now,
                    suffix: ' kb/s')),
            _metric(context, 'Codec',
                _metricValue(data.codecFormat, data.codecFormatUpdatedAt, now)),
            _metric(context, 'Chroma',
                _metricValue(data.chroma, data.chromaUpdatedAt, now)),
            const SizedBox(height: 6),
            Text(
              'Only values reported by the active RustDesk session are shown. '
              'Direct/Relay describes the negotiated transport and does not by itself prove a LAN route.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
