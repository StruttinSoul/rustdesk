import 'package:flutter/material.dart';

import '../../common.dart' show translate;

/// Local option key: this PC has already been offered pairing once.
String pairPromptedKey(String peerId) => 'aperture-pair-prompted:$peerId';

/// Local option key: 'Y' when this phone is trusted by the PC, 'N' when it
/// could be but is not. Read by the Computers page.
String pairedFlagKey(String peerId) => 'aperture-paired:$peerId';

/// The pairing prompt is offered once per PC, and only when the PC can pair.
bool shouldOfferPairing({
  required String pairingState,
  required String promptedFlag,
}) =>
    pairingState == 'can-pair' && promptedFlag != 'Y';

/// Asks whether to trust this phone on [hostName]. Returns true for Trust,
/// false for Not now and null when dismissed.
Future<bool?> showTrustPhoneSheet(
  BuildContext context, {
  required String hostName,
  String Function(String) tr = translate,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('Trust this phone on {$hostName}?'),
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(tr('Next time it connects without a password.'),
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: Text(tr('Trust')),
              ),
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.of(sheetContext).pop(false),
                child: Text(tr('Not now')),
              ),
            ],
          ),
        ),
      );
    },
  );
}
