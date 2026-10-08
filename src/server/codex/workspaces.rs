use super::rpc::RpcCallError;
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CodexWorkspace {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) path: String,
    pub(crate) accessible: bool,
    pub(crate) status: String,
}

#[derive(Clone, Debug)]
struct WorkspaceRecord {
    display_path: PathBuf,
    approved_canonical_path: Option<PathBuf>,
}

#[derive(Default)]
pub(crate) struct CodexWorkspaceRegistry {
    id_by_path: HashMap<PathBuf, String>,
    records: HashMap<String, WorkspaceRecord>,
}

impl CodexWorkspaceRegistry {
    pub(crate) fn refresh<I>(&mut self, paths: I) -> Vec<CodexWorkspace>
    where
        I: IntoIterator<Item = String>,
    {
        let mut seen = HashSet::new();
        let mut listed = Vec::new();
        let mut active_records = HashMap::new();

        for raw in paths {
            let raw = raw.trim();
            if raw.is_empty() {
                continue;
            }
            let source = PathBuf::from(raw);
            let inspection = inspect_workspace(&source);
            let identity_path = inspection
                .canonical_path
                .clone()
                .unwrap_or_else(|| source.clone());
            if !seen.insert(identity_path.clone()) {
                continue;
            }

            let id = self
                .id_by_path
                .entry(identity_path.clone())
                .or_insert_with(|| format!("codex-workspace-{}", Uuid::new_v4()))
                .clone();
            active_records.insert(
                id.clone(),
                WorkspaceRecord {
                    display_path: identity_path.clone(),
                    approved_canonical_path: inspection.canonical_path.clone(),
                },
            );
            listed.push(CodexWorkspace {
                id,
                name: workspace_name(&identity_path),
                path: identity_path.to_string_lossy().into_owned(),
                accessible: inspection.canonical_path.is_some(),
                status: inspection.status,
            });
        }

        // Only workspaces present in the host's current approved thread inventory
        // remain valid start targets. Keep id_by_path so a workspace that later
        // reappears gets the same opaque id without letting a stale mobile list
        // start a root that has disappeared from the current inventory.
        self.records = active_records;

        listed.sort_by(|left, right| {
            left.name
                .to_ascii_lowercase()
                .cmp(&right.name.to_ascii_lowercase())
                .then_with(|| left.path.cmp(&right.path))
        });
        listed
    }

    pub(crate) fn resolve_for_start(&self, workspace_id: &str) -> Result<String, RpcCallError> {
        let record = self.records.get(workspace_id).ok_or_else(|| {
            RpcCallError::Protocol("Unknown Codex workspace id; refresh workspaces first".into())
        })?;
        let approved = record.approved_canonical_path.as_ref().ok_or_else(|| {
            RpcCallError::Protocol("Codex workspace is not currently accessible".into())
        })?;
        let current = fs::canonicalize(&record.display_path)
            .map_err(|_| RpcCallError::Protocol("Codex workspace is no longer available".into()))?;
        let metadata = fs::metadata(&current)
            .map_err(|_| RpcCallError::Protocol("Codex workspace is no longer available".into()))?;
        if !metadata.is_dir() {
            return Err(RpcCallError::Protocol(
                "Codex workspace is no longer a directory".into(),
            ));
        }
        if &current != approved {
            return Err(RpcCallError::Protocol(
                "Codex workspace identity changed; refresh workspaces before starting a task"
                    .into(),
            ));
        }
        Ok(current.to_string_lossy().into_owned())
    }

    pub(crate) fn resolve_approved_root(&self, raw_path: &str) -> Result<PathBuf, RpcCallError> {
        let current = fs::canonicalize(raw_path).map_err(|_| {
            RpcCallError::Protocol("Codex task workspace is no longer available".into())
        })?;
        let metadata = fs::metadata(&current).map_err(|_| {
            RpcCallError::Protocol("Codex task workspace is no longer available".into())
        })?;
        if !metadata.is_dir() {
            return Err(RpcCallError::Protocol(
                "Codex task workspace is not a directory".into(),
            ));
        }
        if self.records.values().any(|record| {
            record
                .approved_canonical_path
                .as_ref()
                .is_some_and(|approved| approved == &current)
        }) {
            return Ok(current);
        }
        Err(RpcCallError::Protocol(
            "Codex task workspace is outside the current approved inventory".into(),
        ))
    }
}

struct WorkspaceInspection {
    canonical_path: Option<PathBuf>,
    status: String,
}

fn inspect_workspace(path: &Path) -> WorkspaceInspection {
    if !path.is_absolute() {
        return WorkspaceInspection {
            canonical_path: None,
            status: "Not an absolute host workspace path".into(),
        };
    }
    let Ok(canonical_path) = fs::canonicalize(path) else {
        return WorkspaceInspection {
            canonical_path: None,
            status: "Workspace is unavailable on this host".into(),
        };
    };
    match fs::metadata(&canonical_path) {
        Ok(metadata) if metadata.is_dir() => WorkspaceInspection {
            canonical_path: Some(canonical_path),
            status: "Available".into(),
        },
        Ok(_) => WorkspaceInspection {
            canonical_path: None,
            status: "Workspace path is not a directory".into(),
        },
        Err(_) => WorkspaceInspection {
            canonical_path: None,
            status: "Workspace is unavailable on this host".into(),
        },
    }
}

fn workspace_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn deleted_workspace_blocks_creation() {
        let root =
            std::env::temp_dir().join(format!("mirpg-codex-workspace-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("test workspace should be created");

        let mut registry = CodexWorkspaceRegistry::default();
        let listed = registry.refresh([root.to_string_lossy().into_owned()]);
        assert_eq!(listed.len(), 1);
        assert!(listed[0].accessible);
        assert_ne!(listed[0].id, listed[0].path);

        fs::remove_dir_all(&root).expect("test workspace should be removable");
        let error = registry
            .resolve_for_start(&listed[0].id)
            .expect_err("deleted workspace must not be started");
        assert!(error.to_string().contains("no longer available"));
    }

    #[test]
    fn arbitrary_path_is_not_a_workspace_id() {
        let root =
            std::env::temp_dir().join(format!("mirpg-codex-workspace-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("test workspace should be created");

        let mut registry = CodexWorkspaceRegistry::default();
        let listed = registry.refresh([root.to_string_lossy().into_owned()]);
        let raw_path = listed[0].path.clone();

        let error = registry
            .resolve_for_start(&raw_path)
            .expect_err("host path must never be accepted as an opaque workspace id");
        assert!(error.to_string().contains("Unknown Codex workspace"));

        fs::remove_dir_all(root).expect("test workspace should be removable");
    }

    #[test]
    fn workspace_removed_from_inventory_invalidates_old_id() {
        let root =
            std::env::temp_dir().join(format!("mirpg-codex-workspace-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("test workspace should be created");

        let mut registry = CodexWorkspaceRegistry::default();
        let listed = registry.refresh([root.to_string_lossy().into_owned()]);
        let workspace_id = listed[0].id.clone();
        assert!(registry.resolve_for_start(&workspace_id).is_ok());

        let empty: Vec<String> = Vec::new();
        registry.refresh(empty);
        let error = registry
            .resolve_for_start(&workspace_id)
            .expect_err("workspace omitted from current inventory must be invalidated");
        assert!(error.to_string().contains("Unknown Codex workspace"));

        fs::remove_dir_all(root).expect("test workspace should be removable");
    }
}
