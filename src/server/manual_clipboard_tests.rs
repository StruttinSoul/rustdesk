use super::manual_clipboard::{
    extract_text_clipboard, handle_manual_clipboard_request_with, manual_clipboard_allowed,
    MAX_MANUAL_CLIPBOARD_BYTES,
};
use base::message_proto::{
    Clipboard, ClipboardFormat, ManualClipboardDirection, ManualClipboardRequest, MultiClipboards,
};

fn request(direction: ManualClipboardDirection, text: &str) -> ManualClipboardRequest {
    ManualClipboardRequest {
        request_id: "request-1".to_owned(),
        direction: direction.into(),
        text: text.to_owned(),
        target_identity: "peer-a".to_owned(),
        ..Default::default()
    }
}

#[test]
fn denied_clipboard_stays_denied_without_touching_host_clipboard() {
    let mut read_called = false;
    let mut write_called = false;
    let response = handle_manual_clipboard_request_with(
        request(
            ManualClipboardDirection::ManualClipboardPhoneToHost,
            "secret",
        ),
        false,
        || {
            read_called = true;
            Ok("host".to_owned())
        },
        |_| {
            write_called = true;
            Ok(())
        },
    );

    assert!(!response.accepted);
    assert!(!response.applied);
    assert_eq!(response.error_code, "clipboard_permission_denied");
    assert!(!read_called);
    assert!(!write_called);
}

#[test]
fn view_only_does_not_override_separate_clipboard_permission() {
    assert!(manual_clipboard_allowed(true, true));
    assert!(!manual_clipboard_allowed(false, false));
    assert!(!manual_clipboard_allowed(false, true));
}

#[test]
fn host_to_phone_returns_exact_text_without_writing_clipboard() {
    let expected = "one\n二\r\n🙂";
    let mut write_called = false;
    let response = handle_manual_clipboard_request_with(
        request(ManualClipboardDirection::ManualClipboardHostToPhone, ""),
        true,
        || Ok(expected.to_owned()),
        |_| {
            write_called = true;
            Ok(())
        },
    );

    assert!(response.accepted);
    assert!(response.applied);
    assert_eq!(response.text, expected);
    assert!(!write_called);
}

#[test]
fn oversized_phone_to_host_payload_is_rejected_before_write() {
    let mut write_called = false;
    let text = "x".repeat(MAX_MANUAL_CLIPBOARD_BYTES + 1);
    let response = handle_manual_clipboard_request_with(
        request(ManualClipboardDirection::ManualClipboardPhoneToHost, &text),
        true,
        || Ok(String::new()),
        |_| {
            write_called = true;
            Ok(())
        },
    );

    assert!(response.accepted);
    assert!(!response.applied);
    assert_eq!(response.error_code, "clipboard_text_too_large");
    assert!(!write_called);
}

#[test]
fn interactive_clipboard_text_decode_preserves_unicode_and_compression() {
    let expected = "first line\n二🙂\r\nlast line";
    let compressed = hbb_common::compress::compress(expected.as_bytes());
    let clipboards = MultiClipboards {
        clipboards: vec![Clipboard {
            compress: true,
            content: compressed.into(),
            format: ClipboardFormat::Text.into(),
            ..Default::default()
        }],
        ..Default::default()
    };

    assert_eq!(extract_text_clipboard(clipboards).unwrap(), expected);
}

#[test]
fn compressed_clipboard_text_is_rejected_at_manual_transfer_limit() {
    let oversized = vec![b'x'; MAX_MANUAL_CLIPBOARD_BYTES + 1];
    let compressed = hbb_common::compress::compress(&oversized);
    let clipboards = MultiClipboards {
        clipboards: vec![Clipboard {
            compress: true,
            content: compressed.into(),
            format: ClipboardFormat::Text.into(),
            ..Default::default()
        }],
        ..Default::default()
    };

    let error = extract_text_clipboard(clipboards).unwrap_err();
    assert!(error.contains("too large"));
}
