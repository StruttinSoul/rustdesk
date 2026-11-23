import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/aperture_host_panel.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('host background fills a tall window in ${brightness.name} mode',
        (tester) async {
      const viewport = Size(460, 700);
      final background = brightness == Brightness.dark
          ? const Color(0xFF101923)
          : const Color(0xFFF5F7FA);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(body: SizedBox.fromSize(
          size: viewport,
          child: Stack(key: const Key('host-window'), children: [
            ApertureHostPanel(
              status: const Text('Ready'),
              identity: const Text('ID'),
              password: const Text('Password'),
              translate: (key) => key,
              onSettings: () {}, onConnect: () {}, onHide: () {},
            ),
          ]),
        )),
      ));
      final surface = find.byWidgetPredicate(
          (widget) => widget is ColoredBox && widget.color == background);
      final available = tester.getSize(find.byKey(const Key('host-window')));
      expect(tester.getSize(surface), available);
      expect(tester.takeException(), isNull);
    });
  }
}
