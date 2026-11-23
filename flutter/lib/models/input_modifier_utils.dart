import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Identifies where terminal input originated so paste data can bypass all
/// keyboard-only transformations.
enum TerminalInputSource {
  keyboard,
  paste,
}

/// Returns true when a stale mobile one-shot Shift state should be released
/// by replaying a tracked Shift key-down as a synthesized key-up.
///
/// This is only valid on mobile when Flutter's cached Shift state is still on
/// (`cachedShiftPressed == true`) but the current hardware/raw event reports
/// Shift as off (`actualShiftPressed == false`).
///
/// A tracked Shift key-down is required so the caller can safely synthesize the
/// matching key-up. Both `shiftLeft` and `shiftRight` are excluded because the
/// Shift key event itself must be processed first; otherwise we could release
/// the tracked key while still handling the original Shift press/release.
/// Callers should evaluate this only after their cached modifier state has been
/// updated for the current event.
///
/// When this returns true, the caller logs a line like:
/// `input: releasing stale mobile Shift before replaying tracked raw key-up`
/// immediately before calling `_releaseTrackedRawShiftKeyEventIfNeeded()`.
bool shouldReleaseStaleMobileShift({
  required bool isMobile,
  required bool cachedShiftPressed,
  required bool actualShiftPressed,
  required LogicalKeyboardKey logicalKey,
  required bool hasTrackedShiftKeyDown,
}) {
  if (!isMobile || !cachedShiftPressed || actualShiftPressed) {
    return false;
  }
  if (!hasTrackedShiftKeyDown) {
    return false;
  }
  if (logicalKey == LogicalKeyboardKey.shiftLeft ||
      logicalKey == LogicalKeyboardKey.shiftRight) {
    return false;
  }
  return true;
}

/// Applies the terminal Ctrl/Alt one-shot modifiers to a single input payload.
///
String applyTerminalInputModifiers(
  String data, {
  required bool ctrlLocked,
  required bool altLocked,
}) {
  var result = data;
  if (ctrlLocked) {
    result = _applyTerminalCtrlModifier(result);
  }
  if (altLocked) {
    result = '\x1B$result';
  }
  return result;
}

/// Builds the exact payload xterm sends for paste, without applying modifiers.
String terminalPastePayload(String text, {required bool bracketedPasteMode}) {
  if (!bracketedPasteMode) {
    return text;
  }
  return '\x1B[200~$text\x1B[201~';
}

const _terminalBracketedPasteStart = '\x1B[200~';
const _terminalBracketedPasteEnd = '\x1B[201~';

bool isBracketedTerminalPastePayload(String data) =>
    data.startsWith(_terminalBracketedPasteStart) &&
    data.endsWith(_terminalBracketedPasteEnd) &&
    data.length >=
        _terminalBracketedPasteStart.length + _terminalBracketedPasteEnd.length;

/// Returns the exact clipboard text represented by xterm's bracketed-paste
/// framing. Non-paste input is returned unchanged.
String terminalPasteReviewText(String data) {
  if (!isBracketedTerminalPastePayload(data)) return data;
  return data.substring(
    _terminalBracketedPasteStart.length,
    data.length - _terminalBracketedPasteEnd.length,
  );
}

/// Returns whether one-shot Ctrl/Alt may transform and consume this input.
///
/// xterm emits terminal control keys as either one control byte or a longer
/// escape sequence. Neither form is ordinary text input, so a pending modifier
/// must survive until the user enters a printable character.
bool shouldApplyTerminalInputModifiers(String data) {
  if (data.characters.length != 1) return false;
  final codeUnit = data.codeUnitAt(0);
  return codeUnit >= 0x20 && codeUnit != 0x7F;
}

/// Builds the payload sent to the remote terminal for keyboard and paste input.
///
/// Keyboard input keeps the mobile Enter workaround and one-shot Ctrl/Alt
/// mapping. Paste input deliberately bypasses both transformations so even a
/// one-character clipboard payload is preserved exactly.
String prepareTerminalInputPayload(
  String data, {
  required TerminalInputSource source,
  required bool isMobileOrWebMobile,
  required bool bracketedPasteMode,
  required bool ctrlLocked,
  required bool altLocked,
}) {
  if (source == TerminalInputSource.paste) {
    return terminalPastePayload(
      data,
      bracketedPasteMode: bracketedPasteMode,
    );
  }

  var result = data;
  if (isMobileOrWebMobile && result == '\n') {
    result = '\r';
  }
  if ((ctrlLocked || altLocked) && shouldApplyTerminalInputModifiers(result)) {
    result = applyTerminalInputModifiers(
      result,
      ctrlLocked: ctrlLocked,
      altLocked: altLocked,
    );
  }
  return result;
}

/// Returns true when a hardware paste shortcut must bypass keyboard modifiers.
///
/// xterm already handles each platform's paste shortcut in the common case.
/// Only intercept while a virtual Ctrl/Alt lock is active, because xterm can
/// emit a one-character paste as normal text when bracketed paste mode is off.
bool shouldHandleTerminalPasteShortcut({
  required TargetPlatform platform,
  required LogicalKeyboardKey logicalKey,
  required bool isKeyDown,
  required bool isKeyRepeat,
  required bool controlPressed,
  required bool metaPressed,
  required bool altPressed,
  required bool shiftPressed,
  required bool modifierLockActive,
}) {
  if (!modifierLockActive) return false;
  if (!isKeyDown && !isKeyRepeat) return false;
  if (logicalKey != LogicalKeyboardKey.keyV) return false;
  if (altPressed) return false;
  switch (platform) {
    case TargetPlatform.linux:
      return controlPressed && !metaPressed && shiftPressed;
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return !controlPressed && metaPressed && !shiftPressed;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.windows:
      return controlPressed && !metaPressed && !shiftPressed;
  }
}

/// Mobile Shell uses an explicit paste review flow. Unlike
/// [shouldHandleTerminalPasteShortcut], this intentionally intercepts the
/// platform paste chord even when no virtual modifier is locked so xterm's
/// built-in PasteTextIntent cannot forward clipboard content directly.
bool shouldInterceptMobileTerminalPasteShortcut({
  required TargetPlatform platform,
  required LogicalKeyboardKey logicalKey,
  required bool isKeyDown,
  required bool isKeyRepeat,
  required bool controlPressed,
  required bool metaPressed,
  required bool altPressed,
  required bool shiftPressed,
}) {
  if (!isKeyDown && !isKeyRepeat) return false;
  if (logicalKey != LogicalKeyboardKey.keyV || altPressed) return false;
  switch (platform) {
    case TargetPlatform.linux:
      return controlPressed && !metaPressed && shiftPressed;
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return !controlPressed && metaPressed && !shiftPressed;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.windows:
      return controlPressed && !metaPressed && !shiftPressed;
  }
}

/// Android/iOS IMEs do not identify a paste separately from normal text input.
/// A multi-character payload containing a line terminator is therefore treated
/// as potentially executable paste and must be staged locally for review.
/// A lone newline remains the user's ordinary Enter key.
bool shouldStagePotentialMobileTerminalPaste(String data) {
  if (data.runes.length <= 1) return false;
  return data.contains('\n') || data.contains('\r');
}

class TerminalPasteInspection {
  const TerminalPasteInspection({
    required this.lineCount,
    required this.hasLineBreaks,
    required this.hasAnsiEscape,
    required this.controlCharacters,
  });

  final int lineCount;
  final bool hasLineBreaks;
  final bool hasAnsiEscape;
  final List<String> controlCharacters;

  bool get hasControlWarning => controlCharacters.isNotEmpty;
}

TerminalPasteInspection inspectTerminalPaste(String text) {
  final controls = <String>{};
  var lineCount = 1;
  for (final rune in text.runes) {
    if (rune == 0x0A) {
      lineCount++;
      continue;
    }
    if (rune == 0x09) continue;
    if (rune == 0x0D) {
      controls.add('CR (U+000D)');
      continue;
    }
    if (rune == 0x1B) {
      controls.add('ESC (U+001B)');
      continue;
    }
    if (rune < 0x20 || rune == 0x7F) {
      controls.add(
        'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
      );
    }
  }
  return TerminalPasteInspection(
    lineCount: lineCount,
    hasLineBreaks: text.contains('\n') || text.contains('\r'),
    hasAnsiEscape: text.contains('\x1B'),
    controlCharacters: List.unmodifiable(controls),
  );
}

/// A secondary representation used only to make otherwise invisible controls
/// reviewable. The exact text is still shown separately and is never rewritten
/// before execution.
String terminalPasteVisibleControls(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    switch (rune) {
      case 0x00:
        out.write('␀');
      case 0x09:
        out.write('⇥');
      case 0x0A:
        out.writeln('␊');
      case 0x0D:
        out.write('␍');
      case 0x1B:
        out.write('␛');
      case 0x7F:
        out.write('␡');
      default:
        if (rune < 0x20) {
          out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  return out.toString();
}

/// Returns true when collapsing Row3 should also clear hidden modifier state.
bool shouldClearTerminalModifiersWhenRow3Collapses({
  required bool wasExpanded,
  required bool willExpand,
  required bool ctrlLocked,
  required bool altLocked,
}) {
  return wasExpanded && !willExpand && (ctrlLocked || altLocked);
}

String _applyTerminalCtrlModifier(String data) {
  // Ctrl mappings are defined only for ASCII scalars. A visible character can
  // be multiple scalars (for example, a decomposed accent), so leave those
  // graphemes untouched instead of rewriting only their ASCII base letter.
  final graphemes = data.characters.toList(growable: false);
  if (graphemes.length != 1) {
    return data;
  }

  final runes = graphemes.single.runes.toList(growable: false);
  if (runes.length != 1) {
    return data;
  }

  final code = runes.single;
  if (code >= 0x61 && code <= 0x7A) {
    return String.fromCharCode(code - 0x60);
  }
  if (code >= 0x41 && code <= 0x5A) {
    return String.fromCharCode(code - 0x40);
  }
  if (code == 0x20) {
    return String.fromCharCode(0);
  }
  if (code == 0x5B) {
    return String.fromCharCode(27);
  }
  if (code == 0x5C) {
    return String.fromCharCode(28);
  }
  if (code == 0x5D) {
    return String.fromCharCode(29);
  }
  if (code == 0x5E) {
    return String.fromCharCode(30);
  }
  if (code == 0x5F || code == 0x2F) {
    return String.fromCharCode(31);
  }
  return data;
}
