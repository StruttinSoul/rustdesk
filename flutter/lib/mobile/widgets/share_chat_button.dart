import 'package:flutter/material.dart';

import '../../common.dart';

/// App-bar action on the Share tab that opens the chat page.
class ShareChatButton extends StatelessWidget {
  const ShareChatButton({
    super.key,
    required this.unread,
    required this.onPressed,
    this.tr = translate,
  });

  final int unread;
  final VoidCallback onPressed;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tr('Chat'),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.chat_bubble_outline),
          if (unread > 0)
            Positioned(
              top: -6,
              right: -8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                constraints:
                    const BoxConstraints(minWidth: 16, minHeight: 16),
                decoration: BoxDecoration(
                  color: scheme.error,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$unread',
                  style: TextStyle(
                    color: scheme.onError,
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
