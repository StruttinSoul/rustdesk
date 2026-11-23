import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/share_chat_button.dart';

import 'support/fake_translate.dart';

Widget _host(int unread, VoidCallback onPressed) => MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [
          ShareChatButton(unread: unread, onPressed: onPressed, tr: fakeTr),
        ]),
      ),
    );

void main() {
  testWidgets('shows unread count and opens chat', (tester) async {
    var opens = 0;
    await tester.pumpWidget(_host(3, () => opens++));
    expect(find.byTooltip('Chat'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byTooltip('Chat'));
    expect(opens, 1);
  });

  testWidgets('no badge when nothing unread, 48 dp target', (tester) async {
    await tester.pumpWidget(_host(0, () {}));
    expect(find.text('0'), findsNothing);
    final size = tester.getSize(find.byType(IconButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });
}
