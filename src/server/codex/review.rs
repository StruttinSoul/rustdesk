use super::{
    protocol::{CodexMethod, CodexProtocol},
    rpc::RpcCallError,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    fs::{self, File},
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    time::{Duration, SystemTime},
};
use uuid::Uuid;

const DEFAULT_PAGE_SIZE: u32 = 25;
const MAX_PAGE_SIZE: u32 = 100;
const MAX_TEXT_PAGE_BYTES: usize = 32 * 1024;
const LARGE_DIFF_BYTES: usize = 64 * 1024;
const MAX_DIFF_BYTES: usize = 4 * 1024 * 1024;
const MAX_CACHED_DIFF_BYTES: usize = MAX_DIFF_BYTES * 4;
const MAX_ARTIFACT_PREVIEW_BYTES: u64 = 1024 * 1024;
const BINARY_SNIFF_BYTES: usize = 8 * 1024;
const MAX_REGISTRY_RECORDS: usize = 1024;
const MAX_REVIEW_CURSORS: usize = 128;
const MAX_RAW_CHANGES_PER_REQUEST: usize = 1000;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CodexTaskChange {
    pub(crate) id: String,
    pub(crate) artifact_id: String,
    pub(crate) path: String,
    pub(crate) kind: String,
    pub(crate) binary: bool,
    pub(crate) large: bool,
    pub(crate) size_bytes: u64,
    pub(crate) diff_available: bool,
    pub(crate) fallback_reason: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CodexArtifact {
    pub(crate) id: String,
    pub(crate) path: String,
    pub(crate) size_bytes: u64,
    pub(crate) binary: bool,
    pub(crate) large: bool,
    pub(crate) readable: bool,
    pub(crate) fallback_reason: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CodexReviewPage<T> {
    pub(crate) items: Vec<T>,
    pub(crate) next_cursor: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CodexTextPage {
    pub(crate) id: String,
    pub(crate) text: String,
    pub(crate) offset: u64,
    pub(crate) next_offset: u64,
    pub(crate) complete: bool,
    pub(crate) fallback_reason: String,
}

#[derive(Clone, Debug)]
struct ChangeRecord {
    thread_id: String,
    diff: Option<String>,
    fallback_reason: String,
}

#[derive(Clone, Debug)]
struct ArtifactRecord {
    thread_id: String,
    workspace_root: PathBuf,
    relative_path: PathBuf,
    snapshot: Option<ArtifactSnapshot>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ArtifactSnapshot {
    len: u64,
    modified: Option<SystemTime>,
    content_hash: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReviewCursorKind {
    Changes,
    Artifacts,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ReviewItemMarker {
    turn_id: String,
    item_id: String,
    fingerprint: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ReviewCursorState {
    thread_id: String,
    workspace_root: PathBuf,
    kind: ReviewCursorKind,
    native_cursor: Option<String>,
    marker: Option<ReviewItemMarker>,
    change_index: usize,
}

#[derive(Clone, Debug)]
enum ReviewRecordKey {
    Change(String),
    Artifact(String),
}

#[derive(Default)]
pub(crate) struct CodexReviewRegistry {
    change_ids_by_key: HashMap<String, String>,
    changes: HashMap<String, ChangeRecord>,
    artifact_ids_by_key: HashMap<String, String>,
    artifacts: HashMap<String, ArtifactRecord>,
    cached_diff_bytes: usize,
    record_order: VecDeque<ReviewRecordKey>,
    review_cursors: HashMap<String, ReviewCursorState>,
    review_cursor_order: VecDeque<String>,
}

impl CodexReviewRegistry {
    pub(crate) fn clear_thread(&mut self, thread_id: &str) {
        let change_ids = self
            .changes
            .iter()
            .filter_map(|(id, record)| (record.thread_id == thread_id).then(|| id.clone()))
            .collect::<std::collections::HashSet<_>>();
        let artifact_ids = self
            .artifacts
            .iter()
            .filter_map(|(id, record)| (record.thread_id == thread_id).then(|| id.clone()))
            .collect::<std::collections::HashSet<_>>();
        self.changes.retain(|id, _| !change_ids.contains(id));
        self.artifacts.retain(|id, _| !artifact_ids.contains(id));
        self.change_ids_by_key
            .retain(|_, id| !change_ids.contains(id));
        self.artifact_ids_by_key
            .retain(|_, id| !artifact_ids.contains(id));
        self.record_order.retain(|entry| match entry {
            ReviewRecordKey::Change(id) => !change_ids.contains(id),
            ReviewRecordKey::Artifact(id) => !artifact_ids.contains(id),
        });
        let cursor_ids = self
            .review_cursors
            .iter()
            .filter_map(|(id, state)| (state.thread_id == thread_id).then(|| id.clone()))
            .collect::<std::collections::HashSet<_>>();
        self.review_cursors.retain(|id, _| !cursor_ids.contains(id));
        self.review_cursor_order
            .retain(|id| !cursor_ids.contains(id));
        self.cached_diff_bytes = self
            .changes
            .values()
            .filter_map(|record| record.diff.as_ref())
            .map(String::len)
            .sum();
    }

    pub(crate) fn list_changes<W: Write>(
        &mut self,
        protocol: &mut CodexProtocol<W>,
        thread_id: &str,
        workspace_root: &Path,
        cursor: Option<&str>,
        limit: u32,
        timeout: Duration,
    ) -> Result<CodexReviewPage<CodexTaskChange>, RpcCallError> {
        let limit = bounded_page_limit(limit);
        let state =
            self.review_cursor(cursor, thread_id, workspace_root, ReviewCursorKind::Changes)?;
        let page = raw_item_page(
            protocol,
            thread_id,
            state.native_cursor.as_deref(),
            MAX_PAGE_SIZE,
            timeout,
        )?;
        let (mut entry_index, mut change_index) =
            review_start_position(&page.entries, state.marker.as_ref(), state.change_index)?;
        self.ensure_capacity_for(limit.saturating_mul(2));
        let mut changes = Vec::new();
        let mut processed_raw = 0usize;
        let mut next_state = None;
        'entries: while entry_index < page.entries.len() {
            let entry = &page.entries[entry_index];
            let turn_id = entry
                .get("turnId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let Some(item) = entry.get("item") else {
                entry_index += 1;
                change_index = 0;
                continue;
            };
            if item.get("type").and_then(Value::as_str) != Some("fileChange") {
                entry_index += 1;
                change_index = 0;
                continue;
            }
            let item_id = item.get("id").and_then(Value::as_str).unwrap_or_default();
            let Some(raw_changes) = item.get("changes").and_then(Value::as_array) else {
                entry_index += 1;
                change_index = 0;
                continue;
            };
            if change_index > raw_changes.len() {
                return Err(RpcCallError::Protocol(
                    "Codex review cursor is stale; refresh review data".into(),
                ));
            }
            while change_index < raw_changes.len() {
                if changes.len() >= limit || processed_raw >= MAX_RAW_CHANGES_PER_REQUEST {
                    next_state = Some(review_cursor_for_position(
                        thread_id,
                        workspace_root,
                        ReviewCursorKind::Changes,
                        state.native_cursor.clone(),
                        entry,
                        change_index,
                    )?);
                    break 'entries;
                }
                let index = change_index;
                let raw_change = &raw_changes[index];
                change_index += 1;
                processed_raw += 1;
                let Some(change) = self.register_change(
                    thread_id,
                    turn_id,
                    item_id,
                    index,
                    workspace_root,
                    raw_change,
                )?
                else {
                    continue;
                };
                changes.push(change);
            }
            entry_index += 1;
            change_index = 0;
        }
        if next_state.is_none() {
            next_state = page
                .next_cursor
                .clone()
                .map(|native_cursor| ReviewCursorState {
                    thread_id: thread_id.to_owned(),
                    workspace_root: workspace_root.to_path_buf(),
                    kind: ReviewCursorKind::Changes,
                    native_cursor: Some(native_cursor),
                    marker: None,
                    change_index: 0,
                });
        }
        self.touch_review_cursor(cursor);
        let next_cursor = next_state.map(|state| self.store_review_cursor(state));
        Ok(CodexReviewPage {
            items: changes,
            next_cursor,
        })
    }

    pub(crate) fn list_artifacts<W: Write>(
        &mut self,
        protocol: &mut CodexProtocol<W>,
        thread_id: &str,
        workspace_root: &Path,
        cursor: Option<&str>,
        limit: u32,
        timeout: Duration,
    ) -> Result<CodexReviewPage<CodexArtifact>, RpcCallError> {
        let limit = bounded_page_limit(limit);
        let state = self.review_cursor(
            cursor,
            thread_id,
            workspace_root,
            ReviewCursorKind::Artifacts,
        )?;
        let page = raw_item_page(
            protocol,
            thread_id,
            state.native_cursor.as_deref(),
            MAX_PAGE_SIZE,
            timeout,
        )?;
        let (mut entry_index, mut change_index) =
            review_start_position(&page.entries, state.marker.as_ref(), state.change_index)?;
        self.ensure_capacity_for(limit);
        let mut artifacts = Vec::new();
        let mut processed_raw = 0usize;
        let mut next_state = None;
        'entries: while entry_index < page.entries.len() {
            let entry = &page.entries[entry_index];
            let Some(item) = entry.get("item") else {
                entry_index += 1;
                change_index = 0;
                continue;
            };
            if item.get("type").and_then(Value::as_str) != Some("fileChange") {
                entry_index += 1;
                change_index = 0;
                continue;
            }
            let Some(raw_changes) = item.get("changes").and_then(Value::as_array) else {
                entry_index += 1;
                change_index = 0;
                continue;
            };
            if change_index > raw_changes.len() {
                return Err(RpcCallError::Protocol(
                    "Codex review cursor is stale; refresh review data".into(),
                ));
            }
            while change_index < raw_changes.len() {
                if artifacts.len() >= limit || processed_raw >= MAX_RAW_CHANGES_PER_REQUEST {
                    next_state = Some(review_cursor_for_position(
                        thread_id,
                        workspace_root,
                        ReviewCursorKind::Artifacts,
                        state.native_cursor.clone(),
                        entry,
                        change_index,
                    )?);
                    break 'entries;
                }
                let raw_change = &raw_changes[change_index];
                change_index += 1;
                processed_raw += 1;
                let Some(raw_path) = raw_change.get("path").and_then(Value::as_str) else {
                    continue;
                };
                let Ok(relative_path) =
                    workspace_relative_path(workspace_root, Path::new(raw_path))
                else {
                    continue;
                };
                let id = self.register_artifact(thread_id, workspace_root, &relative_path);
                let artifact = inspect_artifact(&id, workspace_root, &relative_path);
                if !artifacts
                    .iter()
                    .any(|existing: &CodexArtifact| existing.id == id)
                {
                    artifacts.push(artifact);
                }
            }
            entry_index += 1;
            change_index = 0;
        }
        if next_state.is_none() {
            next_state = page
                .next_cursor
                .clone()
                .map(|native_cursor| ReviewCursorState {
                    thread_id: thread_id.to_owned(),
                    workspace_root: workspace_root.to_path_buf(),
                    kind: ReviewCursorKind::Artifacts,
                    native_cursor: Some(native_cursor),
                    marker: None,
                    change_index: 0,
                });
        }
        self.touch_review_cursor(cursor);
        let next_cursor = next_state.map(|state| self.store_review_cursor(state));
        Ok(CodexReviewPage {
            items: artifacts,
            next_cursor,
        })
    }

    pub(crate) fn read_diff(
        &self,
        thread_id: &str,
        change_id: &str,
        offset: u64,
        limit: u32,
    ) -> Result<CodexTextPage, RpcCallError> {
        let record = self.changes.get(change_id).ok_or_else(|| {
            RpcCallError::Protocol("Unknown Codex change id; refresh review data first".into())
        })?;
        if record.thread_id != thread_id {
            return Err(RpcCallError::Protocol(
                "Codex change id belongs to a different task".into(),
            ));
        }
        let Some(diff) = record.diff.as_deref() else {
            return Ok(CodexTextPage {
                id: change_id.to_owned(),
                text: String::new(),
                offset,
                next_offset: offset,
                complete: true,
                fallback_reason: record.fallback_reason.clone(),
            });
        };
        text_page(change_id, diff, offset, limit)
    }

    pub(crate) fn read_artifact(
        &self,
        thread_id: &str,
        artifact_id: &str,
        offset: u64,
        limit: u32,
    ) -> Result<CodexTextPage, RpcCallError> {
        let record = self.artifacts.get(artifact_id).ok_or_else(|| {
            RpcCallError::Protocol("Unknown Codex artifact id; refresh artifacts first".into())
        })?;
        if record.thread_id != thread_id {
            return Err(RpcCallError::Protocol(
                "Codex artifact id belongs to a different task".into(),
            ));
        }
        if record.snapshot.is_none() {
            return Err(RpcCallError::Protocol(
                "Codex artifact was unavailable when listed; refresh artifacts before continuing"
                    .into(),
            ));
        }
        read_artifact_page(
            artifact_id,
            &record.workspace_root,
            &record.relative_path,
            record.snapshot.as_ref(),
            offset,
            limit,
        )
    }

    fn register_change(
        &mut self,
        thread_id: &str,
        turn_id: &str,
        item_id: &str,
        index: usize,
        workspace_root: &Path,
        raw_change: &Value,
    ) -> Result<Option<CodexTaskChange>, RpcCallError> {
        let Some(raw_path) = raw_change.get("path").and_then(Value::as_str) else {
            return Ok(None);
        };
        let relative_path = match workspace_relative_path(workspace_root, Path::new(raw_path)) {
            Ok(path) => path,
            Err(_) => return Ok(None),
        };
        self.ensure_capacity_for(2);
        let display_path = relative_path.to_string_lossy().into_owned();
        let artifact_id =
            self.register_artifact_unchecked(thread_id, workspace_root, &relative_path);
        let artifact = inspect_artifact(&artifact_id, workspace_root, &relative_path);
        let raw_diff = raw_change
            .get("diff")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let diff_binary = raw_diff.as_bytes().contains(&0);
        let diff_too_large = raw_diff.len() > MAX_DIFF_BYTES;
        let mut diff = if raw_diff.is_empty() || diff_binary || diff_too_large {
            None
        } else {
            Some(raw_diff.to_owned())
        };
        let mut fallback_reason = if diff_binary {
            "Binary diff preview is unavailable".to_owned()
        } else if diff_too_large {
            "Diff is too large to preview safely".to_owned()
        } else if raw_diff.is_empty() {
            "No text diff was provided by Codex".to_owned()
        } else {
            String::new()
        };
        let kind = normalized_change_kind(raw_change.get("kind"));
        let mut hasher = Sha256::new();
        hasher.update(kind.as_bytes());
        hasher.update([0]);
        hasher.update(raw_diff.as_bytes());
        let snapshot_hash = format!("{:x}", hasher.finalize());
        let key = format!(
            "{thread_id}\u{1f}{turn_id}\u{1f}{item_id}\u{1f}{index}\u{1f}{display_path}\u{1f}{snapshot_hash}"
        );
        let change_id = self
            .change_ids_by_key
            .entry(key)
            .or_insert_with(|| format!("codex-change-{}", Uuid::new_v4()))
            .clone();
        if let Some(existing) = self.changes.get(&change_id) {
            diff = existing.diff.clone();
            fallback_reason = existing.fallback_reason.clone();
        } else {
            if let Some(text) = diff.as_ref() {
                if self.cached_diff_bytes.saturating_add(text.len()) > MAX_CACHED_DIFF_BYTES {
                    diff = None;
                    fallback_reason =
                        "Diff preview is unavailable because the review cache limit was reached"
                            .to_owned();
                } else {
                    self.cached_diff_bytes += text.len();
                }
            }
            self.changes.insert(
                change_id.clone(),
                ChangeRecord {
                    thread_id: thread_id.to_owned(),
                    diff: diff.clone(),
                    fallback_reason: fallback_reason.clone(),
                },
            );
            self.record_order
                .push_back(ReviewRecordKey::Change(change_id.clone()));
        }
        Ok(Some(CodexTaskChange {
            id: change_id,
            artifact_id,
            path: display_path,
            kind,
            binary: diff_binary || artifact.binary,
            large: raw_diff.len() > LARGE_DIFF_BYTES || artifact.large,
            size_bytes: artifact.size_bytes.max(raw_diff.len() as u64),
            diff_available: diff.is_some(),
            fallback_reason,
        }))
    }

    fn register_artifact(
        &mut self,
        thread_id: &str,
        workspace_root: &Path,
        relative_path: &Path,
    ) -> String {
        self.ensure_capacity_for(1);
        self.register_artifact_unchecked(thread_id, workspace_root, relative_path)
    }

    fn register_artifact_unchecked(
        &mut self,
        thread_id: &str,
        workspace_root: &Path,
        relative_path: &Path,
    ) -> String {
        let snapshot = capture_artifact_snapshot(workspace_root, relative_path).ok();
        let snapshot_key = snapshot
            .as_ref()
            .map(artifact_snapshot_key)
            .unwrap_or_else(|| "unavailable".into());
        let key = format!(
            "{thread_id}\u{1f}{}\u{1f}{snapshot_key}",
            relative_path.to_string_lossy().to_ascii_lowercase(),
        );
        let id = self
            .artifact_ids_by_key
            .entry(key)
            .or_insert_with(|| format!("codex-artifact-{}", Uuid::new_v4()))
            .clone();
        if !self.artifacts.contains_key(&id) {
            self.artifacts.insert(
                id.clone(),
                ArtifactRecord {
                    thread_id: thread_id.to_owned(),
                    workspace_root: workspace_root.to_path_buf(),
                    relative_path: relative_path.to_path_buf(),
                    snapshot,
                },
            );
            self.record_order
                .push_back(ReviewRecordKey::Artifact(id.clone()));
        }
        id
    }

    fn ensure_capacity_for(&mut self, additional: usize) {
        let target = MAX_REGISTRY_RECORDS.saturating_sub(additional.min(MAX_REGISTRY_RECORDS));
        while self.changes.len() + self.artifacts.len() > target {
            let Some(oldest) = self.record_order.pop_front() else {
                break;
            };
            match oldest {
                ReviewRecordKey::Change(id) => {
                    if let Some(record) = self.changes.remove(&id) {
                        if let Some(diff) = record.diff {
                            self.cached_diff_bytes =
                                self.cached_diff_bytes.saturating_sub(diff.len());
                        }
                    }
                    self.change_ids_by_key.retain(|_, existing| existing != &id);
                }
                ReviewRecordKey::Artifact(id) => {
                    self.artifacts.remove(&id);
                    self.artifact_ids_by_key
                        .retain(|_, existing| existing != &id);
                }
            }
        }
    }

    fn review_cursor(
        &self,
        cursor: Option<&str>,
        thread_id: &str,
        workspace_root: &Path,
        kind: ReviewCursorKind,
    ) -> Result<ReviewCursorState, RpcCallError> {
        let Some(cursor) = cursor.filter(|cursor| !cursor.is_empty()) else {
            return Ok(ReviewCursorState {
                thread_id: thread_id.to_owned(),
                workspace_root: workspace_root.to_path_buf(),
                kind,
                native_cursor: None,
                marker: None,
                change_index: 0,
            });
        };
        let state = self.review_cursors.get(cursor).cloned().ok_or_else(|| {
            RpcCallError::Protocol(
                "Codex review cursor is invalid or stale; refresh review data".into(),
            )
        })?;
        if state.thread_id != thread_id
            || state.workspace_root != workspace_root
            || state.kind != kind
        {
            return Err(RpcCallError::Protocol(
                "Codex review cursor belongs to a different task or review view".into(),
            ));
        }
        Ok(state)
    }

    fn store_review_cursor(&mut self, state: ReviewCursorState) -> String {
        if let Some(existing_id) = self
            .review_cursors
            .iter()
            .find_map(|(id, existing)| (existing == &state).then(|| id.clone()))
        {
            self.review_cursor_order.retain(|id| id != &existing_id);
            self.review_cursor_order.push_back(existing_id.clone());
            return existing_id;
        }
        while self.review_cursors.len() >= MAX_REVIEW_CURSORS {
            let Some(oldest) = self.review_cursor_order.pop_front() else {
                break;
            };
            self.review_cursors.remove(&oldest);
        }
        let id = format!("codex-review-cursor-{}", Uuid::new_v4());
        self.review_cursor_order.push_back(id.clone());
        self.review_cursors.insert(id.clone(), state);
        id
    }

    fn touch_review_cursor(&mut self, cursor: Option<&str>) {
        let Some(cursor) = cursor.filter(|cursor| !cursor.is_empty()) else {
            return;
        };
        if self.review_cursors.contains_key(cursor) {
            self.review_cursor_order.retain(|id| id != cursor);
            self.review_cursor_order.push_back(cursor.to_owned());
        }
    }
}

struct RawItemPage {
    entries: Vec<Value>,
    next_cursor: Option<String>,
}

fn bounded_page_limit(limit: u32) -> usize {
    if limit == 0 {
        DEFAULT_PAGE_SIZE as usize
    } else {
        limit.min(MAX_PAGE_SIZE) as usize
    }
}

fn review_start_position(
    entries: &[Value],
    marker: Option<&ReviewItemMarker>,
    change_index: usize,
) -> Result<(usize, usize), RpcCallError> {
    let Some(marker) = marker else {
        return Ok((0, 0));
    };
    let mut identity_seen = false;
    for (entry_index, entry) in entries.iter().enumerate() {
        let turn_id = entry
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let Some(item) = entry.get("item") else {
            continue;
        };
        if item.get("type").and_then(Value::as_str) != Some("fileChange") {
            continue;
        }
        let item_id = item.get("id").and_then(Value::as_str).unwrap_or_default();
        if turn_id != marker.turn_id || item_id != marker.item_id {
            continue;
        }
        identity_seen = true;
        let current = review_item_marker(entry)?;
        if current.fingerprint == marker.fingerprint {
            return Ok((entry_index, change_index));
        }
    }
    let reason = if identity_seen {
        "Codex review data changed while paging; refresh review data"
    } else {
        "Codex review cursor is stale; refresh review data"
    };
    Err(RpcCallError::Protocol(reason.into()))
}

fn review_cursor_for_position(
    thread_id: &str,
    workspace_root: &Path,
    kind: ReviewCursorKind,
    native_cursor: Option<String>,
    entry: &Value,
    change_index: usize,
) -> Result<ReviewCursorState, RpcCallError> {
    Ok(ReviewCursorState {
        thread_id: thread_id.to_owned(),
        workspace_root: workspace_root.to_path_buf(),
        kind,
        native_cursor,
        marker: Some(review_item_marker(entry)?),
        change_index,
    })
}

fn review_item_marker(entry: &Value) -> Result<ReviewItemMarker, RpcCallError> {
    let turn_id = entry
        .get("turnId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let item = entry
        .get("item")
        .ok_or_else(|| RpcCallError::Protocol("Codex review item is missing its payload".into()))?;
    if item.get("type").and_then(Value::as_str) != Some("fileChange") {
        return Err(RpcCallError::Protocol(
            "Codex review cursor does not reference a file-change item".into(),
        ));
    }
    let item_id = item
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let mut hasher = Sha256::new();
    hasher.update(turn_id.as_bytes());
    hasher.update([0]);
    hasher.update(item_id.as_bytes());
    if let Some(changes) = item.get("changes").and_then(Value::as_array) {
        for change in changes {
            hasher.update([0xff]);
            if let Some(path) = change.get("path").and_then(Value::as_str) {
                hasher.update(path.as_bytes());
            }
            hasher.update([0]);
            if let Some(kind) = change.get("kind") {
                hasher.update(kind.to_string().as_bytes());
            }
            hasher.update([0]);
            if let Some(diff) = change.get("diff").and_then(Value::as_str) {
                hasher.update(diff.as_bytes());
            }
        }
    }
    Ok(ReviewItemMarker {
        turn_id,
        item_id,
        fingerprint: format!("{:x}", hasher.finalize()),
    })
}

fn raw_item_page<W: Write>(
    protocol: &mut CodexProtocol<W>,
    thread_id: &str,
    cursor: Option<&str>,
    limit: u32,
    timeout: Duration,
) -> Result<RawItemPage, RpcCallError> {
    if thread_id.trim().is_empty() {
        return Err(RpcCallError::Protocol("thread id must not be empty".into()));
    }
    let limit = if limit == 0 {
        DEFAULT_PAGE_SIZE
    } else {
        limit.min(MAX_PAGE_SIZE)
    };
    let mut params = json!({
        "threadId": thread_id,
        "limit": limit,
        "sortDirection": "desc"
    });
    if let Some(cursor) = cursor.filter(|cursor| !cursor.is_empty()) {
        params["cursor"] = Value::String(cursor.to_owned());
    }
    let page = protocol.request(CodexMethod::ThreadItemsList, params, timeout)?;
    let entries = page
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| RpcCallError::Protocol("thread/items/list response is missing data".into()))?
        .clone();
    Ok(RawItemPage {
        entries,
        next_cursor: page
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    })
}

fn workspace_relative_path(
    workspace_root: &Path,
    raw_path: &Path,
) -> Result<PathBuf, RpcCallError> {
    let relative = if raw_path.is_absolute() {
        let raw_text = raw_path.to_string_lossy();
        if raw_text
            .split(['\\', '/'])
            .any(|component| component == "..")
        {
            return Err(RpcCallError::Protocol(
                "Codex file change contains parent traversal in the task workspace".into(),
            ));
        }
        absolute_path_relative_to_workspace(workspace_root, raw_path)?
    } else {
        raw_path.to_path_buf()
    };
    validate_relative_path(&relative)?;
    Ok(relative)
}

#[cfg(target_os = "windows")]
fn absolute_path_relative_to_workspace(
    workspace_root: &Path,
    raw_path: &Path,
) -> Result<PathBuf, RpcCallError> {
    let root = normalize_windows_path_text(workspace_root);
    let candidate = normalize_windows_path_text(raw_path);
    if candidate.eq_ignore_ascii_case(&root) {
        return Ok(PathBuf::new());
    }
    let prefix = if root.ends_with('\\') {
        root.clone()
    } else {
        format!("{root}\\")
    };
    let prefix_matches = candidate
        .get(..prefix.len())
        .is_some_and(|value| value.eq_ignore_ascii_case(&prefix));
    if candidate.len() <= prefix.len() || !prefix_matches {
        return Err(RpcCallError::Protocol(
            "Codex file change is outside the task workspace".into(),
        ));
    }
    let suffix = candidate.get(prefix.len()..).ok_or_else(|| {
        RpcCallError::Protocol("Codex file change is outside the task workspace".into())
    })?;
    Ok(PathBuf::from(suffix))
}

#[cfg(target_os = "windows")]
fn normalize_windows_path_text(path: &Path) -> String {
    let mut value = path.to_string_lossy().replace('/', "\\");
    if let Some(rest) = value.strip_prefix(r"\\?\UNC\") {
        value = format!(r"\\{rest}");
    } else if let Some(rest) = value.strip_prefix(r"\\?\") {
        value = rest.to_owned();
    }
    while value.len() > 3 && value.ends_with('\\') {
        value.pop();
    }
    value
}

#[cfg(not(target_os = "windows"))]
fn absolute_path_relative_to_workspace(
    workspace_root: &Path,
    raw_path: &Path,
) -> Result<PathBuf, RpcCallError> {
    raw_path
        .strip_prefix(workspace_root)
        .map(Path::to_path_buf)
        .map_err(|_| {
            RpcCallError::Protocol("Codex file change is outside the task workspace".into())
        })
}

fn validate_relative_path(path: &Path) -> Result<(), RpcCallError> {
    if path.as_os_str().is_empty() {
        return Err(RpcCallError::Protocol(
            "Codex artifact path must not be empty".into(),
        ));
    }
    for component in path.components() {
        match component {
            Component::Normal(_) | Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(RpcCallError::Protocol(
                    "Codex artifact path escapes the task workspace".into(),
                ));
            }
        }
    }
    Ok(())
}

fn secure_existing_file(
    workspace_root: &Path,
    relative_path: &Path,
) -> Result<(PathBuf, fs::Metadata), RpcCallError> {
    validate_relative_path(relative_path)?;
    let mut ancestors = workspace_root.ancestors().collect::<Vec<_>>();
    ancestors.reverse();
    for ancestor in ancestors {
        reject_reparse(ancestor)?;
    }
    let mut current = workspace_root.to_path_buf();
    for component in relative_path.components() {
        if let Component::Normal(part) = component {
            current.push(part);
            reject_reparse(&current)?;
        }
    }
    let canonical = fs::canonicalize(&current)
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    if !canonical.starts_with(workspace_root) {
        return Err(RpcCallError::Protocol(
            "Codex artifact resolved outside the task workspace".into(),
        ));
    }
    let metadata = fs::metadata(&canonical)
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    if !metadata.is_file() {
        return Err(RpcCallError::Protocol(
            "Codex artifact is not a regular file".into(),
        ));
    }
    Ok((canonical, metadata))
}

fn open_verified_artifact(
    workspace_root: &Path,
    relative_path: &Path,
    expected_snapshot: Option<&ArtifactSnapshot>,
) -> Result<(File, fs::Metadata, ArtifactSnapshot), RpcCallError> {
    let (path, _) = secure_existing_file(workspace_root, relative_path)?;
    let mut file = File::open(&path)
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    verify_open_file_path(workspace_root, &file)?;
    let metadata = file
        .metadata()
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    if !metadata.is_file() {
        return Err(RpcCallError::Protocol(
            "Codex artifact is not a regular file".into(),
        ));
    }
    let snapshot = artifact_snapshot(&mut file, &metadata)?;
    if expected_snapshot.is_some() && expected_snapshot != Some(&snapshot) {
        return Err(RpcCallError::Protocol(
            "Codex artifact changed; refresh artifacts before continuing".into(),
        ));
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| RpcCallError::Protocol("Unable to seek Codex artifact".into()))?;
    Ok((file, metadata, snapshot))
}

#[cfg(target_os = "windows")]
fn verify_open_file_path(workspace_root: &Path, file: &File) -> Result<(), RpcCallError> {
    use std::{
        ffi::OsString,
        os::windows::{ffi::OsStringExt, io::AsRawHandle},
    };
    use winapi::um::fileapi::GetFinalPathNameByHandleW;

    let mut buffer = vec![0u16; 32 * 1024];
    let len = unsafe {
        GetFinalPathNameByHandleW(
            file.as_raw_handle() as _,
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            0,
        )
    };
    if len == 0 || len as usize >= buffer.len() {
        return Err(RpcCallError::Protocol(
            "Unable to verify Codex artifact file handle".into(),
        ));
    }
    let final_path = PathBuf::from(OsString::from_wide(&buffer[..len as usize]));
    let root = normalize_windows_path_text(workspace_root);
    let candidate = normalize_windows_path_text(&final_path);
    if candidate.eq_ignore_ascii_case(&root) {
        return Err(RpcCallError::Protocol(
            "Codex artifact is not a regular file inside the task workspace".into(),
        ));
    }
    let prefix = if root.ends_with('\\') {
        root.clone()
    } else {
        format!("{root}\\")
    };
    let prefix_matches = candidate
        .get(..prefix.len())
        .is_some_and(|value| value.eq_ignore_ascii_case(&prefix));
    if candidate.len() <= prefix.len() || !prefix_matches {
        return Err(RpcCallError::Protocol(
            "Codex artifact resolved outside the task workspace".into(),
        ));
    }
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn verify_open_file_path(_workspace_root: &Path, _file: &File) -> Result<(), RpcCallError> {
    Ok(())
}

fn reject_reparse(path: &Path) -> Result<(), RpcCallError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    if metadata.file_type().is_symlink() || is_windows_reparse_point(&metadata) {
        return Err(RpcCallError::Protocol(
            "Codex artifact uses a symlink or reparse point".into(),
        ));
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn is_windows_reparse_point(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(target_os = "windows"))]
fn is_windows_reparse_point(_metadata: &fs::Metadata) -> bool {
    false
}

fn inspect_artifact(
    artifact_id: &str,
    workspace_root: &Path,
    relative_path: &Path,
) -> CodexArtifact {
    let path = relative_path.to_string_lossy().into_owned();
    let Ok((mut file, metadata, _)) = open_verified_artifact(workspace_root, relative_path, None)
    else {
        return CodexArtifact {
            id: artifact_id.to_owned(),
            path,
            size_bytes: 0,
            binary: false,
            large: false,
            readable: false,
            fallback_reason: "Artifact is unavailable or cannot be safely resolved".into(),
        };
    };
    let size_bytes = metadata.len();
    if size_bytes > MAX_ARTIFACT_PREVIEW_BYTES {
        return CodexArtifact {
            id: artifact_id.to_owned(),
            path,
            size_bytes,
            binary: false,
            large: true,
            readable: false,
            fallback_reason: "Artifact is too large for remote text preview".into(),
        };
    }
    let binary = sniff_binary_file(&mut file).unwrap_or(true);
    CodexArtifact {
        id: artifact_id.to_owned(),
        path,
        size_bytes,
        binary,
        large: false,
        readable: !binary,
        fallback_reason: if binary {
            "Binary artifact preview is unavailable".into()
        } else {
            String::new()
        },
    }
}

fn sniff_binary(path: &Path) -> Result<bool, RpcCallError> {
    let mut file = File::open(path)
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    sniff_binary_file(&mut file)
}

fn sniff_binary_file(file: &mut File) -> Result<bool, RpcCallError> {
    file.seek(SeekFrom::Start(0))
        .map_err(|_| RpcCallError::Protocol("Unable to inspect Codex artifact".into()))?;
    let probe_limit = BINARY_SNIFF_BYTES.saturating_add(4);
    let mut bytes = Vec::with_capacity(probe_limit.saturating_add(1));
    (&mut *file)
        .take(probe_limit.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| RpcCallError::Protocol("Unable to inspect Codex artifact".into()))?;
    let has_more = bytes.len() > probe_limit;
    bytes.truncate(probe_limit);
    if bytes.contains(&0) {
        return Ok(true);
    }
    Ok(match std::str::from_utf8(&bytes) {
        Ok(_) => false,
        Err(error) if error.error_len().is_none() => !has_more,
        Err(_) => true,
    })
}

fn capture_artifact_snapshot(
    workspace_root: &Path,
    relative_path: &Path,
) -> Result<ArtifactSnapshot, RpcCallError> {
    let (_, _, snapshot) = open_verified_artifact(workspace_root, relative_path, None)?;
    Ok(snapshot)
}

fn artifact_snapshot(
    file: &mut File,
    metadata: &fs::Metadata,
) -> Result<ArtifactSnapshot, RpcCallError> {
    let content_hash = if metadata.len() <= MAX_ARTIFACT_PREVIEW_BYTES {
        file.seek(SeekFrom::Start(0))
            .map_err(|_| RpcCallError::Protocol("Unable to inspect Codex artifact".into()))?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 32 * 1024];
        let expected_len = metadata.len();
        let mut total = 0u64;
        let mut bounded = (&mut *file).take(expected_len.saturating_add(1));
        loop {
            let read = bounded
                .read(&mut buffer)
                .map_err(|_| RpcCallError::Protocol("Unable to inspect Codex artifact".into()))?;
            if read == 0 {
                break;
            }
            total = total.saturating_add(read as u64);
            if total > expected_len {
                return Err(RpcCallError::Protocol(
                    "Codex artifact changed while it was being inspected".into(),
                ));
            }
            hasher.update(&buffer[..read]);
        }
        if total != expected_len {
            return Err(RpcCallError::Protocol(
                "Codex artifact changed while it was being inspected".into(),
            ));
        }
        Some(format!("{:x}", hasher.finalize()))
    } else {
        None
    };
    let after = file
        .metadata()
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    if after.len() != metadata.len() || after.modified().ok() != metadata.modified().ok() {
        return Err(RpcCallError::Protocol(
            "Codex artifact changed while it was being inspected".into(),
        ));
    }
    Ok(ArtifactSnapshot {
        len: metadata.len(),
        modified: metadata.modified().ok(),
        content_hash,
    })
}

fn artifact_snapshot_key(snapshot: &ArtifactSnapshot) -> String {
    let modified = snapshot
        .modified
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|value| value.as_nanos().to_string())
        .unwrap_or_else(|| "unknown-time".into());
    format!(
        "{}:{modified}:{}",
        snapshot.len,
        snapshot
            .content_hash
            .as_deref()
            .unwrap_or("no-content-hash")
    )
}

fn read_artifact_page(
    artifact_id: &str,
    workspace_root: &Path,
    relative_path: &Path,
    expected_snapshot: Option<&ArtifactSnapshot>,
    offset: u64,
    limit: u32,
) -> Result<CodexTextPage, RpcCallError> {
    let (mut file, metadata, opened_snapshot) =
        open_verified_artifact(workspace_root, relative_path, expected_snapshot)?;
    if metadata.len() > MAX_ARTIFACT_PREVIEW_BYTES {
        return Ok(CodexTextPage {
            id: artifact_id.to_owned(),
            text: String::new(),
            offset,
            next_offset: offset,
            complete: true,
            fallback_reason: "Artifact is too large for remote text preview".into(),
        });
    }
    if sniff_binary_file(&mut file)? {
        return Ok(CodexTextPage {
            id: artifact_id.to_owned(),
            text: String::new(),
            offset,
            next_offset: offset,
            complete: true,
            fallback_reason: "Binary artifact preview is unavailable".into(),
        });
    }
    if offset > metadata.len() {
        return Err(RpcCallError::Protocol(
            "Codex artifact offset is outside the file".into(),
        ));
    }
    let limit = bounded_text_limit(limit);
    file.seek(SeekFrom::Start(offset))
        .map_err(|_| RpcCallError::Protocol("Unable to seek Codex artifact".into()))?;
    let remaining = metadata.len().saturating_sub(offset) as usize;
    let to_read = remaining.min(limit.saturating_add(4));
    let mut bytes = Vec::with_capacity(to_read);
    (&mut file)
        .take(to_read as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| RpcCallError::Protocol("Unable to read Codex artifact".into()))?;
    let take = utf8_prefix_len(&bytes, limit)?;
    let text = std::str::from_utf8(&bytes[..take])
        .map_err(|_| RpcCallError::Protocol("Codex artifact is not valid UTF-8 text".into()))?
        .to_owned();
    let next_offset = offset + take as u64;
    let after_metadata = file
        .metadata()
        .map_err(|_| RpcCallError::Protocol("Codex artifact is no longer available".into()))?;
    let after_snapshot = artifact_snapshot(&mut file, &after_metadata)?;
    if after_snapshot != opened_snapshot {
        return Err(RpcCallError::Protocol(
            "Codex artifact changed while it was being read; refresh artifacts before continuing"
                .into(),
        ));
    }
    Ok(CodexTextPage {
        id: artifact_id.to_owned(),
        text,
        offset,
        next_offset,
        complete: next_offset >= metadata.len(),
        fallback_reason: String::new(),
    })
}

fn utf8_prefix_len(bytes: &[u8], limit: usize) -> Result<usize, RpcCallError> {
    let cap = bytes.len().min(limit);
    match std::str::from_utf8(&bytes[..cap]) {
        Ok(_) => Ok(cap),
        Err(error) if error.error_len().is_none() && error.valid_up_to() > 0 => {
            Ok(error.valid_up_to())
        }
        Err(error) if error.error_len().is_none() => {
            let text = std::str::from_utf8(bytes).map_err(|_| {
                RpcCallError::Protocol("Codex artifact is not valid UTF-8 text".into())
            })?;
            Ok(text.chars().next().map(char::len_utf8).unwrap_or(0))
        }
        Err(_) => Err(RpcCallError::Protocol(
            "Codex artifact is not valid UTF-8 text".into(),
        )),
    }
}

fn normalized_change_kind(kind: Option<&Value>) -> String {
    let value = kind
        .and_then(|kind| {
            kind.as_str().or_else(|| {
                kind.as_object().and_then(|object| {
                    ["type", "kind", "value"]
                        .into_iter()
                        .find_map(|key| object.get(key).and_then(Value::as_str))
                })
            })
        })
        .filter(|kind| !kind.trim().is_empty())
        .unwrap_or("update");
    value.chars().take(64).collect()
}

fn text_page(id: &str, text: &str, offset: u64, limit: u32) -> Result<CodexTextPage, RpcCallError> {
    let offset = usize::try_from(offset)
        .map_err(|_| RpcCallError::Protocol("Codex diff offset is too large".into()))?;
    if offset > text.len() || !text.is_char_boundary(offset) {
        return Err(RpcCallError::Protocol(
            "Codex diff offset is outside a text boundary".into(),
        ));
    }
    let limit = bounded_text_limit(limit);
    let mut end = text.len().min(offset.saturating_add(limit));
    while end > offset && !text.is_char_boundary(end) {
        end -= 1;
    }
    if end == offset && offset < text.len() {
        end = text[offset..]
            .char_indices()
            .nth(1)
            .map(|(index, _)| offset + index)
            .unwrap_or(text.len());
    }
    Ok(CodexTextPage {
        id: id.to_owned(),
        text: text[offset..end].to_owned(),
        offset: offset as u64,
        next_offset: end as u64,
        complete: end >= text.len(),
        fallback_reason: String::new(),
    })
}

fn bounded_text_limit(limit: u32) -> usize {
    if limit == 0 {
        MAX_TEXT_PAGE_BYTES
    } else {
        (limit as usize).min(MAX_TEXT_PAGE_BYTES)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::codex::rpc::JsonRpcClient;
    use std::io::Cursor;

    fn temp_workspace() -> PathBuf {
        let root = std::env::temp_dir().join(format!("mirpg-codex-review-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        fs::canonicalize(root).unwrap()
    }

    fn protocol_with_input(input: String) -> CodexProtocol<Vec<u8>> {
        CodexProtocol::new(JsonRpcClient::from_streams(
            Cursor::new(input.into_bytes()),
            Vec::new(),
        ))
    }

    fn file_change_page_response(id: u64, changes: Value) -> String {
        format!(
            "{}\n",
            json!({
                "id": id,
                "result": {
                    "data": [{
                        "turnId": "turn_1",
                        "item": {
                            "type": "fileChange",
                            "id": "item_1",
                            "changes": changes,
                        }
                    }],
                    "nextCursor": null
                }
            })
        )
    }

    #[test]
    fn large_diff_is_paginated_with_host_issued_id() {
        let root = temp_workspace();
        fs::write(root.join("large.txt"), "current").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let diff = "x".repeat(LARGE_DIFF_BYTES + 4096);
        let change = registry
            .register_change(
                "thr_1",
                "turn_1",
                "item_1",
                0,
                &root,
                &json!({"path":"large.txt","kind":"update","diff":diff}),
            )
            .unwrap()
            .unwrap();

        assert!(change.large);
        assert!(change.diff_available);
        assert_ne!(change.id, change.path);
        let first = registry.read_diff("thr_1", &change.id, 0, 4096).unwrap();
        assert_eq!(first.text.len(), 4096);
        assert!(!first.complete);
        let second = registry
            .read_diff("thr_1", &change.id, first.next_offset, 4096)
            .unwrap();
        assert_eq!(second.offset, first.next_offset);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn change_list_uses_host_cursor_inside_one_large_file_change_item() {
        let root = temp_workspace();
        for name in ["a.txt", "b.txt", "c.txt"] {
            fs::write(root.join(name), name).unwrap();
        }
        let changes = json!([
            {"path":"a.txt","kind":"update","diff":"a"},
            {"path":"b.txt","kind":"update","diff":"b"},
            {"path":"c.txt","kind":"update","diff":"c"}
        ]);
        let input = format!(
            "{}{}",
            file_change_page_response(1, changes.clone()),
            file_change_page_response(2, changes),
        );
        let mut protocol = protocol_with_input(input);
        let mut registry = CodexReviewRegistry::default();

        let first = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                None,
                2,
                Duration::from_secs(1),
            )
            .unwrap();
        assert_eq!(first.items.len(), 2);
        let cursor = first.next_cursor.clone().expect("continuation cursor");
        assert!(cursor.starts_with("codex-review-cursor-"));

        let second = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                Some(&cursor),
                2,
                Duration::from_secs(1),
            )
            .unwrap();
        assert_eq!(second.items.len(), 1);
        assert_eq!(second.items[0].path, "c.txt");
        assert!(second.next_cursor.is_none());
        assert_eq!(
            registry
                .read_diff("thr_1", &first.items[0].id, 0, 16)
                .unwrap()
                .text,
            "a"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn review_cursor_can_be_replayed_after_response_loss() {
        let root = temp_workspace();
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] {
            fs::write(root.join(name), name).unwrap();
        }
        let changes = json!([
            {"path":"a.txt","kind":"update","diff":"a"},
            {"path":"b.txt","kind":"update","diff":"b"},
            {"path":"c.txt","kind":"update","diff":"c"},
            {"path":"d.txt","kind":"update","diff":"d"},
            {"path":"e.txt","kind":"update","diff":"e"}
        ]);
        let input = format!(
            "{}{}{}",
            file_change_page_response(1, changes.clone()),
            file_change_page_response(2, changes.clone()),
            file_change_page_response(3, changes),
        );
        let mut protocol = protocol_with_input(input);
        let mut registry = CodexReviewRegistry::default();

        let first = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                None,
                2,
                Duration::from_secs(1),
            )
            .unwrap();
        let cursor = first.next_cursor.expect("continuation cursor");

        let delivered = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                Some(&cursor),
                2,
                Duration::from_secs(1),
            )
            .unwrap();
        assert_eq!(
            delivered
                .items
                .iter()
                .map(|item| item.path.as_str())
                .collect::<Vec<_>>(),
            vec!["c.txt", "d.txt"]
        );
        let delivered_next = delivered.next_cursor.clone().expect("next cursor");

        let replayed = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                Some(&cursor),
                2,
                Duration::from_secs(1),
            )
            .expect("a lost response must be retryable with the same opaque cursor");
        assert_eq!(replayed.items, delivered.items);
        assert_eq!(
            replayed.next_cursor.as_deref(),
            Some(delivered_next.as_str())
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn active_review_cursor_survives_capacity_pressure_for_response_retry() {
        let root = temp_workspace();
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] {
            fs::write(root.join(name), name).unwrap();
        }
        let changes = json!([
            {"path":"a.txt","kind":"update","diff":"a"},
            {"path":"b.txt","kind":"update","diff":"b"},
            {"path":"c.txt","kind":"update","diff":"c"},
            {"path":"d.txt","kind":"update","diff":"d"},
            {"path":"e.txt","kind":"update","diff":"e"}
        ]);
        let input = format!(
            "{}{}{}",
            file_change_page_response(1, changes.clone()),
            file_change_page_response(2, changes.clone()),
            file_change_page_response(3, changes),
        );
        let mut protocol = protocol_with_input(input);
        let mut registry = CodexReviewRegistry::default();

        let first = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                None,
                2,
                Duration::from_secs(1),
            )
            .unwrap();
        let cursor = first.next_cursor.expect("continuation cursor");

        for index in 0..(MAX_REVIEW_CURSORS - 1) {
            registry.store_review_cursor(ReviewCursorState {
                thread_id: "thr_1".into(),
                workspace_root: root.clone(),
                kind: ReviewCursorKind::Changes,
                native_cursor: Some(format!("filler-{index}")),
                marker: None,
                change_index: index,
            });
        }
        assert_eq!(registry.review_cursors.len(), MAX_REVIEW_CURSORS);

        let delivered = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                Some(&cursor),
                2,
                Duration::from_secs(1),
            )
            .unwrap();
        let replayed = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                Some(&cursor),
                2,
                Duration::from_secs(1),
            )
            .expect("the cursor used by a delivered page must remain retryable");

        assert_eq!(replayed.items, delivered.items);
        assert_eq!(replayed.next_cursor, delivered.next_cursor);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn review_cursor_rejects_item_mutation_between_pages() {
        let root = temp_workspace();
        for name in ["a.txt", "b.txt", "c.txt"] {
            fs::write(root.join(name), name).unwrap();
        }
        let first_changes = json!([
            {"path":"a.txt","kind":"update","diff":"a"},
            {"path":"b.txt","kind":"update","diff":"b"},
            {"path":"c.txt","kind":"update","diff":"c"}
        ]);
        let changed = json!([
            {"path":"a.txt","kind":"update","diff":"a"},
            {"path":"b.txt","kind":"update","diff":"changed"},
            {"path":"c.txt","kind":"update","diff":"c"}
        ]);
        let input = format!(
            "{}{}",
            file_change_page_response(1, first_changes),
            file_change_page_response(2, changed),
        );
        let mut protocol = protocol_with_input(input);
        let mut registry = CodexReviewRegistry::default();
        let first = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                None,
                2,
                Duration::from_secs(1),
            )
            .unwrap();
        let cursor = first.next_cursor.expect("continuation cursor");

        let error = registry
            .list_changes(
                &mut protocol,
                "thr_1",
                &root,
                Some(&cursor),
                2,
                Duration::from_secs(1),
            )
            .expect_err("mutated review item must invalidate its continuation cursor");
        assert!(error.to_string().contains("changed"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn binary_diff_uses_safe_fallback() {
        let root = temp_workspace();
        fs::write(root.join("binary.bin"), [0u8, 1, 2]).unwrap();
        let mut registry = CodexReviewRegistry::default();
        let change = registry
            .register_change(
                "thr_1",
                "turn_1",
                "item_1",
                0,
                &root,
                &json!({"path":"binary.bin","kind":"update","diff":"a\0b"}),
            )
            .unwrap()
            .unwrap();

        assert!(change.binary);
        assert!(!change.diff_available);
        let preview = registry.read_diff("thr_1", &change.id, 0, 4096).unwrap();
        assert!(preview.text.is_empty());
        assert!(preview.fallback_reason.contains("Binary"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn artifact_outside_workspace_is_never_registered() {
        let root = temp_workspace();
        let outside = std::env::temp_dir().join(format!("outside-{}.txt", Uuid::new_v4()));
        fs::write(&outside, "private").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let result = registry
            .register_change(
                "thr_1",
                "turn_1",
                "item_1",
                0,
                &root,
                &json!({"path":outside.to_string_lossy(),"kind":"update","diff":"secret"}),
            )
            .unwrap();

        assert!(result.is_none());
        assert!(registry.artifacts.is_empty());
        fs::remove_file(outside).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn artifact_read_rechecks_workspace_and_reparse_safety() {
        let root = temp_workspace();
        fs::write(root.join("safe.txt"), "hello world").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let id = registry.register_artifact("thr_1", &root, Path::new("safe.txt"));
        let preview = registry.read_artifact("thr_1", &id, 0, 5).unwrap();
        assert_eq!(preview.text, "hello");

        let wrong_thread = registry.read_artifact("thr_2", &id, 0, 5).unwrap_err();
        assert!(wrong_thread.to_string().contains("different task"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn absolute_change_path_with_parent_component_is_rejected() {
        let root = temp_workspace();
        fs::create_dir_all(root.join("nested")).unwrap();
        fs::write(root.join("safe.txt"), "safe").unwrap();
        let disguised = PathBuf::from(format!(r"{}\nested\..\safe.txt", root.display()));

        let error = workspace_relative_path(&root, &disguised)
            .expect_err("absolute paths with parent traversal must not be normalized into scope");

        assert!(error.to_string().contains("workspace"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn utf8_sniff_accepts_character_split_at_probe_boundary() {
        let root = temp_workspace();
        let path = root.join("utf8.txt");
        let mut text = "a".repeat(BINARY_SNIFF_BYTES - 1);
        text.push('é');
        text.push_str("tail");
        fs::write(&path, text).unwrap();

        assert!(!sniff_binary(&path).unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn utf8_sniff_rejects_truncated_character_at_end_of_file() {
        let root = temp_workspace();
        let path = root.join("truncated.txt");
        fs::write(&path, [b'a', 0xc3]).unwrap();

        assert!(sniff_binary(&path).unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unavailable_artifact_id_cannot_become_readable_later() {
        let root = temp_workspace();
        let mut registry = CodexReviewRegistry::default();
        let id = registry.register_artifact("thr_1", &root, Path::new("later.txt"));
        fs::write(root.join("later.txt"), "created later").unwrap();

        let error = registry
            .read_artifact("thr_1", &id, 0, 16)
            .expect_err("an unavailable snapshot id must stay unavailable");
        assert!(error.to_string().contains("unavailable when listed"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn artifact_pages_are_bound_to_registered_file_snapshot() {
        let root = temp_workspace();
        let path = root.join("changing.txt");
        fs::write(&path, "hello world").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let id = registry.register_artifact("thr_1", &root, Path::new("changing.txt"));
        let first = registry.read_artifact("thr_1", &id, 0, 5).unwrap();
        assert_eq!(first.text, "hello");

        fs::write(&path, "hello changed content").unwrap();
        let error = registry
            .read_artifact("thr_1", &id, first.next_offset, 5)
            .expect_err("paging must stop when the artifact changes after registration");

        assert!(error.to_string().contains("changed"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn refreshing_artifact_after_content_change_issues_new_snapshot_id() {
        let root = temp_workspace();
        let path = root.join("snapshot.txt");
        fs::write(&path, "first").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let first_id = registry.register_artifact("thr_1", &root, Path::new("snapshot.txt"));

        fs::write(&path, "other").unwrap();
        let refreshed_id = registry.register_artifact("thr_1", &root, Path::new("snapshot.txt"));

        assert_ne!(first_id, refreshed_id);
        let old = registry
            .read_artifact("thr_1", &first_id, 0, 16)
            .expect_err("the old id must stay bound to the original file snapshot");
        assert!(old.to_string().contains("changed"));
        let refreshed = registry
            .read_artifact("thr_1", &refreshed_id, 0, 16)
            .unwrap();
        assert_eq!(refreshed.text, "other");
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn normal_absolute_deleted_path_is_kept_relative_to_verbatim_workspace_root() {
        let root = temp_workspace();
        let root_text = root.to_string_lossy();
        let normal_root = root_text.strip_prefix(r"\\?\").unwrap_or(&root_text);
        let deleted = PathBuf::from(normal_root).join("deleted.txt");

        let relative = workspace_relative_path(&root, &deleted)
            .expect("normal and verbatim Windows prefixes should identify the same workspace");

        assert_eq!(relative, PathBuf::from("deleted.txt"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn refreshing_same_change_key_keeps_prior_diff_snapshot_stable() {
        let root = temp_workspace();
        fs::write(root.join("stable.txt"), "current").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let first = registry
            .register_change(
                "thr_1",
                "turn_1",
                "item_1",
                0,
                &root,
                &json!({"path":"stable.txt","kind":"update","diff":"old diff"}),
            )
            .unwrap()
            .unwrap();
        let refreshed = registry
            .register_change(
                "thr_1",
                "turn_1",
                "item_1",
                0,
                &root,
                &json!({"path":"stable.txt","kind":"update","diff":"new diff"}),
            )
            .unwrap()
            .unwrap();

        assert_ne!(first.id, refreshed.id);
        let old = registry.read_diff("thr_1", &first.id, 0, 64).unwrap();
        let new = registry.read_diff("thr_1", &refreshed.id, 0, 64).unwrap();
        assert_eq!(old.text, "old diff");
        assert_eq!(new.text, "new diff");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn structured_change_kind_is_preserved() {
        let root = temp_workspace();
        fs::write(root.join("removed.txt"), "current").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let change = registry
            .register_change(
                "thr_1",
                "turn_1",
                "item_1",
                0,
                &root,
                &json!({
                    "path":"removed.txt",
                    "kind":{"type":"delete"},
                    "diff":"-removed"
                }),
            )
            .unwrap()
            .unwrap();

        assert_eq!(change.kind, "delete");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn review_registry_stays_bounded_during_large_change_sets() {
        let root = temp_workspace();
        let mut registry = CodexReviewRegistry::default();
        for index in 0..(MAX_REGISTRY_RECORDS + 64) {
            let name = format!("file-{index}.txt");
            fs::write(root.join(&name), "current").unwrap();
            registry
                .register_change(
                    "thr_1",
                    "turn_1",
                    "item_1",
                    index,
                    &root,
                    &json!({"path":name,"kind":"update","diff":"small"}),
                )
                .unwrap();
            assert!(registry.changes.len() + registry.artifacts.len() <= MAX_REGISTRY_RECORDS);
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn review_registry_caps_total_cached_diff_bytes() {
        let root = temp_workspace();
        fs::write(root.join("large.txt"), "current").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let diff = "x".repeat(MAX_DIFF_BYTES);
        let mut last = None;
        for index in 0..5 {
            last = registry
                .register_change(
                    "thr_1",
                    "turn_1",
                    "item_1",
                    index,
                    &root,
                    &json!({"path":"large.txt","kind":"update","diff":diff}),
                )
                .unwrap();
        }

        let cached_bytes: usize = registry
            .changes
            .values()
            .filter_map(|record| record.diff.as_ref())
            .map(String::len)
            .sum();
        assert!(cached_bytes <= MAX_DIFF_BYTES * 4);
        let last = last.unwrap();
        assert!(!last.diff_available);
        assert!(last.fallback_reason.contains("cache"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn clearing_thread_invalidates_only_that_threads_review_ids() {
        let root = temp_workspace();
        fs::write(root.join("one.txt"), "one").unwrap();
        fs::write(root.join("two.txt"), "two").unwrap();
        let mut registry = CodexReviewRegistry::default();
        let one = registry
            .register_change(
                "thr_1",
                "turn_1",
                "item_1",
                0,
                &root,
                &json!({"path":"one.txt","kind":"update","diff":"one"}),
            )
            .unwrap()
            .unwrap();
        let two = registry
            .register_change(
                "thr_2",
                "turn_2",
                "item_2",
                0,
                &root,
                &json!({"path":"two.txt","kind":"update","diff":"two"}),
            )
            .unwrap()
            .unwrap();

        registry.clear_thread("thr_1");

        assert!(registry.read_diff("thr_1", &one.id, 0, 16).is_err());
        assert_eq!(
            registry.read_diff("thr_2", &two.id, 0, 16).unwrap().text,
            "two"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
