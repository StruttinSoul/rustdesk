import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/connection_page.dart';
import 'package:flutter_hbb/mobile/pages/home_page.dart';

class _FakePage extends StatelessWidget implements PageShape {
  const _FakePage(this.title, this.icon);

  @override
  final String title;

  @override
  final Widget icon;

  @override
  List<Widget> get appBarActions => const [];

  @override
  Widget build(BuildContext context) => Text('body-$title');
}

void main() {
  test('remote root is named Computers', () {
    expect(ConnectionPage(appBarActions: const []).title, 'Computers');
  });

  testWidgets('mobile root uses a Material navigation bar and selects pages',
      (tester) async {
    var selected = 0;
    const pages = <PageShape>[
      _FakePage('Computers', Icon(Icons.computer_outlined)),
      _FakePage('Chat', Icon(Icons.chat_bubble_outline)),
      _FakePage('Share', Icon(Icons.screen_share_outlined)),
      _FakePage('Settings', Icon(Icons.settings_outlined)),
    ];

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        return Scaffold(
          body: pages[selected],
          bottomNavigationBar: MobileHomeNavigationBar(
            pages: pages,
            currentIndex: selected,
            onDestinationSelected: (index) => setState(() => selected = index),
          ),
        );
      }),
    ));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
    for (final label in ['Computers', 'Chat', 'Share', 'Settings']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(selected, 2);
    expect(find.text('body-Share'), findsOneWidget);
  });

  testWidgets('mobile root remains usable at 130 percent text scale',
      (tester) async {
    const pages = <PageShape>[
      _FakePage('Computers', Icon(Icons.computer_outlined)),
      _FakePage('Chat', Icon(Icons.chat_bubble_outline)),
      _FakePage('Share', Icon(Icons.screen_share_outlined)),
      _FakePage('Settings', Icon(Icons.settings_outlined)),
    ];

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: Scaffold(
          bottomNavigationBar: MobileHomeNavigationBar(
            pages: pages,
            currentIndex: 0,
            onDestinationSelected: (_) {},
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
  });
}
