use super::*;
use crate::server::emulator::{
    remote::{authorize_request, GuestEvent},
    remote_windows::{self, GuestSession},
};

impl Connection {
    pub(super) async fn on_emulator_request(&mut self, request: EmulatorRequest) -> bool {
        let id = request.request_id;
        if let Err(error) = authorize_request(
            &request,
            self.authorized && self.is_authed_remote_conn(),
            self.peer_keyboard_enabled(),
            self.emulator_session.as_ref().map(|session| session.id),
        ) {
            return self
                .send_emulator_response(remote_windows::error_response(id, error))
                .await;
        }
        let response = match request.union.as_ref() {
            Some(emulator_request::Union::Previews(previews)) => {
                return self.set_emulator_previews(id, previews).await;
            }
            Some(emulator_request::Union::List(_)) => {
                match hbb_common::tokio::task::spawn_blocking(move || remote_windows::inventory(id))
                    .await
                {
                    Ok(response) => response,
                    Err(error) => remote_windows::error_response(id, error.to_string()),
                }
            }
            Some(emulator_request::Union::Select(_)) => {
                self.emulator_session.take();
                if !self.emulator_dashboard { self.suspend_emulator_desktop(); }
                if let Some(emulator_request::Union::Select(selection)) = request.union.as_ref() {
                    self.emulator_previews.remove(&selection.target_id);
                }
                match GuestSession::start(request.clone(), self.emulator_tx.clone()) {
                    Ok(session) => {
                        let response = remote_windows::status_response(
                            id,
                            session.id,
                            &session.target_id,
                            EmulatorSessionState::EmulatorStarting,
                            0,
                            0,
                            String::new(),
                        );
                        self.emulator_session = Some(session);
                        response
                    }
                    Err(error) => {
                        self.restore_emulator_desktop();
                        remote_windows::error_response(id, error.to_string())
                    }
                }
            }
            Some(emulator_request::Union::Desktop(_)) => {
                self.emulator_session.take();
                self.restore_emulator_desktop();
                remote_windows::status_response(
                    id,
                    0,
                    "",
                    EmulatorSessionState::EmulatorDesktop,
                    0,
                    0,
                    String::new(),
                )
            }
            _ => {
                if let Some(session) = self.emulator_session.as_ref() {
                    if let Err(error) = session.input(request.clone()) {
                        session.cancel();
                        let response = remote_windows::status_response(
                            id,
                            session.id,
                            &session.target_id,
                            EmulatorSessionState::EmulatorFailed,
                            0,
                            0,
                            error.to_string(),
                        );
                        return self.send_emulator_response(response).await;
                    }
                }
                self.update_auto_disconnect_timer();
                return true;
            }
        };
        self.send_emulator_response(response).await
    }

    pub(super) async fn handle_emulator_event(&mut self, event: GuestEvent) -> bool {
        let preview_id = match &event {
            GuestEvent::Response(response) => match response.union.as_ref() {
                Some(emulator_response::Union::Status(status)) if status.preview => Some(status.session_id),
                _ => None,
            },
            GuestEvent::Frame(frame) if self.emulator_previews.values().any(|session| session.id == frame.session_id) => Some(frame.session_id),
            _ => None,
        };
        if let Some(id) = preview_id {
            if !self.emulator_previews.values().any(|session| session.id == id) { return true; }
            let mut message = Message::new();
            match event {
                GuestEvent::Response(response) => {
                    if let Some(emulator_response::Union::Status(status)) = response.union.as_ref() {
                        if status.state.enum_value_or_default() == EmulatorSessionState::EmulatorFailed {
                            self.emulator_previews.retain(|_, session| session.id != id);
                        }
                    }
                    message.set_emulator_response(response);
                },
                GuestEvent::Frame(frame) => message.set_emulator_video_frame(frame),
            }
            return self.send_emulator_message(message).await;
        }
        let Some(session) = self.emulator_session.as_ref() else {
            return true;
        };
        let mut message = Message::new();
        match event {
            GuestEvent::Response(response) => {
                let Some(emulator_response::Union::Status(status)) = response.union.as_ref() else {
                    return true;
                };
                if status.session_id != session.id {
                    return true;
                }
                if status.state.enum_value_or_default() == EmulatorSessionState::EmulatorFailed {
                    session.cancel();
                }
                message.set_emulator_response(response);
            }
            GuestEvent::Frame(frame) => {
                if frame.session_id != session.id {
                    return true;
                }
                message.set_emulator_video_frame(frame);
            }
        }
        self.send_emulator_message(message).await
    }

    async fn set_emulator_previews(&mut self, id: u64, previews: &EmulatorPreviewRequest) -> bool {
        let displays = previews.displays.iter().map(|id| *id as usize).collect::<Vec<_>>();
        if displays.iter().any(|id| *id >= Self::video_source_count(self.video_source())) {
            return self.send_emulator_response(remote_windows::error_response(id, "Monitor is no longer available")).await;
        }
        self.emulator_dashboard = previews.enabled;
        let selected = self.emulator_session.as_ref().map(|session| session.target_id.as_str());
        self.emulator_previews.retain(|target, _| previews.enabled && previews.target_ids.contains(target) && Some(target.as_str()) != selected);
        for target in &previews.target_ids {
            if self.emulator_previews.contains_key(target) || self.emulator_session.as_ref().map(|session| &session.target_id) == Some(target) { continue; }
            match GuestSession::start_preview(id, target.clone(), self.emulator_tx.clone()) {
                Ok(session) => {
                    let response = remote_windows::with_preview(remote_windows::status_response(id, session.id, target, EmulatorSessionState::EmulatorStarting, 0, 0, String::new()), true);
                    self.emulator_previews.insert(target.clone(), session);
                    if !self.send_emulator_response(response).await { return false; }
                }
                Err(error) => {
                    if !self.send_emulator_response(remote_windows::error_response(id, error.to_string())).await { return false; }
                }
            }
        }
        if previews.enabled {
            self.capture_displays(&[], &[], &displays).await;
        } else if self.emulator_session.is_none() {
            self.capture_displays(&[], &[], &[self.display_idx]).await;
        }
        let mut response = remote_windows::response(id);
        response.set_previews(EmulatorPreviewState { enabled: previews.enabled, session_ids: self.emulator_previews.values().map(|session| session.id).collect(), ..Default::default() });
        self.send_emulator_response(response).await
    }

    async fn send_emulator_response(&mut self, response: EmulatorResponse) -> bool {
        let mut message = Message::new();
        message.set_emulator_response(response);
        self.send_emulator_message(message).await
    }

    async fn send_emulator_message(&mut self, message: Message) -> bool {
        if let Err(error) = self.stream.send(&message).await {
            self.on_close(&error.to_string(), false).await;
            return false;
        }
        true
    }

    fn suspend_emulator_desktop(&mut self) {
        if !self.emulator_desktop_services.is_empty() {
            return;
        }
        if let Some(server) = self.server.upgrade() {
            let mut server = server.write().unwrap();
            self.emulator_desktop_services = server
                .services
                .iter()
                .filter(|(_, service)| service.is_subed(self.inner.id()))
                .map(|(name, _)| name.clone())
                .collect();
            for name in &self.emulator_desktop_services {
                server.subscribe(name, self.inner.clone(), false);
            }
        }
    }

    pub(super) async fn enforce_guest_permissions(&mut self) {
        if self.peer_keyboard_enabled() {
            return;
        }
        if let Some(session) = self.emulator_session.as_ref() {
            session.cancel();
            let response = remote_windows::status_response(
                0,
                session.id,
                &session.target_id,
                EmulatorSessionState::EmulatorFailed,
                0,
                0,
                "Emulator control permission was revoked".to_owned(),
            );
            self.send_emulator_response(response).await;
        }
    }

    fn restore_emulator_desktop(&mut self) {
        let clipboard = self.can_sub_clipboard_service();
        let audio = self.audio_enabled();
        let cursor = self.peer_keyboard_enabled() || self.show_remote_cursor;
        if let Some(server) = self.server.upgrade() {
            let mut server = server.write().unwrap();
            for name in self.emulator_desktop_services.drain(..) {
                let allowed = match name.as_str() {
                    super::clipboard_service::NAME => clipboard,
                    super::audio_service::NAME => audio,
                    NAME_CURSOR => cursor,
                    _ => true,
                };
                server.subscribe(&name, self.inner.clone(), allowed);
            }
        }
        self.refresh_video_display(None);
    }
}
