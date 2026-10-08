import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/widgets/shell_paste_sheet.dart';
import 'package:flutter_hbb/models/input_modifier_utils.dart';
import 'package:flutter_hbb/models/terminal_copy_shortcut.dart';
import 'package:flutter_hbb/models/rustdesk_terminal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('multiline paste is classified for local staging before execution', () {
    const fixture = 'Write-Output one\nWrite-Output two';
    expect(shouldStagePotentialMobileTerminalPaste(fixture), isTrue);
    expect(shouldStagePotentialMobileTerminalPaste('\n'), isFalse);
    expect(
      terminalPastePayload(fixture, bracketedPasteMode: false),
      fixture,
    );
    expect(
      terminalPastePayload(fixture, bracketedPasteMode: true),
      '\x1B[200~$fixture\x1B[201~',
    );
  });

  test('mobile paste shortcut is intercepted without virtual modifier locks',
      () {
    expect(
      shouldInterceptMobileTerminalPasteShortcut(
        platform: TargetPlatform.android,
        logicalKey: LogicalKeyboardKey.keyV,
        isKeyDown: true,
        isKeyRepeat: false,
        controlPressed: true,
        metaPressed: false,
        altPressed: false,
        shiftPressed: false,
      ),
      isTrue,
    );
  });

  test('mobile terminal shortcut map removes xterm paste intents', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      final shortcuts = platformTerminalShortcuts(
        allowPaste: false,
        platform: platform,
      );
      expect(shortcuts, isNotNull,
          reason: '$platform must override xterm paste');
      expect(shortcuts!.values.whereType<PasteTextIntent>(), isEmpty);
    }
  });

  test('bracketed xterm paste framing is removed before review', () {
    const text = 'echo one\necho two';
    expect(
      terminalPasteReviewText('\x1B[200~$text\x1B[201~'),
      text,
    );
    expect(terminalPasteReviewText(text), text);
  });

  test('terminal paste hook can intercept even a single-line xterm paste', () {
    final reviewed = <String>[];
    final forwarded = <String>[];
    final terminal = RustDeskTerminal(
      clipboardWritePermission: () => TerminalClipboardWritePermission.denied,
      onClipboardWrite: (_) async => false,
      onPasteRequest: (text) {
        reviewed.add(text);
        return true;
      },
    );
    terminal.onOutput = forwarded.add;

    terminal.paste('echo safe');

    expect(reviewed, ['echo safe']);
    expect(forwarded, isEmpty);
  });

  test('ansi and controls are visible before send', () {
    const text = 'safe\n\x1B[31mred\x1B[0m\r';
    final inspection = inspectTerminalPaste(text);
    expect(inspection.hasLineBreaks, isTrue);
    expect(inspection.hasAnsiEscape, isTrue);
    expect(inspection.controlCharacters, contains('ESC (U+001B)'));
    expect(inspection.controlCharacters, contains('CR (U+000D)'));
    expect(terminalPasteVisibleControls(text), contains('␛'));
    expect(terminalPasteVisibleControls(text), contains('␍'));
  });

  testWidgets('paste review requires Insert text and never offers Run',
      (tester) async {
    const text = 'echo one\necho two';
    bool? inserted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  inserted = await showModalBottomSheet<bool>(
                    context: context,
                    builder: (_) => const ShellPasteSheet(
                      targetLabel: 'Jarvis · PowerShell',
                      text: text,
                    ),
                  );
                },
                child: const Text('Paste'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(find.text('Target: Jarvis · PowerShell'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('shell-paste-exact-text')), findsOneWidget);
    expect(find.text('Run / Enter'), findsNothing);
    expect(inserted, isNull);

    await tester.tap(find.text('Insert text'));
    await tester.pumpAndSettle();
    expect(inserted, isTrue);
  });

  testWidgets('paste review scrolls at landscape size with 2x text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(892, 412));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const text =
        'Write-Output one\nWrite-Output two\nWrite-Output three\nWrite-Output four\n\x1B[31mred\x1B[0m';

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(892, 412),
            textScaler: TextScaler.linear(2),
          ),
          child: const Scaffold(
            body: ShellPasteSheet(
              targetLabel: 'Jarvis · PowerShell',
              text: text,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Insert text'), findsOneWidget);
  });
}
