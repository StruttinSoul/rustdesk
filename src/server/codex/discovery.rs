use hbb_common::{bail, ResultType};
use std::{
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const ENV_EXECUTABLE: &str = "RUSTDESK_CODEX_EXECUTABLE";
const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(25);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexInstallation {
    pub executable: PathBuf,
    pub version: String,
    pub codex_home: PathBuf,
}

pub fn discover_installation() -> ResultType<Option<CodexInstallation>> {
    let candidates = installation_candidates();
    let Some(executable) = select_existing_candidate(candidates, Path::is_file) else {
        return Ok(None);
    };

    let version_output = run_version_command(&executable)?;
    let version = parse_version(&version_output).ok_or_else(|| {
        hbb_common::anyhow::anyhow!(
            "Unsupported Codex version output from '{}': '{}'",
            executable.display(),
            version_output.trim()
        )
    })?;
    let codex_home = codex_home_candidate()?;

    Ok(Some(CodexInstallation {
        executable,
        version,
        codex_home,
    }))
}

pub(crate) fn installation_present() -> bool {
    select_existing_candidate(installation_candidates(), Path::is_file).is_some()
        && codex_home_candidate().is_ok()
}

fn parse_version(output: &str) -> Option<String> {
    let mut parts = output.split_whitespace();
    let product = parts.next()?;
    if product != "codex-cli" && product != "codex" {
        return None;
    }
    let version = parts.next()?;
    if version.is_empty() || parts.next().is_some() {
        return None;
    }
    Some(version.to_owned())
}

fn select_existing_candidate<F>(candidates: Vec<PathBuf>, mut exists: F) -> Option<PathBuf>
where
    F: FnMut(&Path) -> bool,
{
    candidates.into_iter().find(|path| exists(path))
}

fn installation_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Some(override_path) = std::env::var_os(ENV_EXECUTABLE) {
        if !override_path.is_empty() {
            candidates.push(PathBuf::from(override_path));
        }
    }

    if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
        let local_app_data = PathBuf::from(local_app_data);
        candidates.push(
            local_app_data
                .join("Programs")
                .join("OpenAI")
                .join("Codex")
                .join("bin")
                .join("codex.exe"),
        );

        let desktop_bin = local_app_data.join("OpenAI").join("Codex").join("bin");
        candidates.push(desktop_bin.join("codex.exe"));
        if let Ok(entries) = std::fs::read_dir(&desktop_bin) {
            let mut bundled = entries
                .flatten()
                .map(|entry| entry.path().join("codex.exe"))
                .collect::<Vec<_>>();
            bundled.sort();
            candidates.extend(bundled);
        }
    }

    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|dir| dir.join("codex.exe")));
    }

    dedupe_paths(candidates)
}

fn codex_home_candidate() -> ResultType<PathBuf> {
    if let Some(codex_home) = std::env::var_os("CODEX_HOME") {
        if !codex_home.is_empty() {
            return Ok(PathBuf::from(codex_home));
        }
    }
    if let Some(user_profile) = std::env::var_os("USERPROFILE") {
        if !user_profile.is_empty() {
            return Ok(PathBuf::from(user_profile).join(".codex"));
        }
    }
    bail!("Unable to determine Codex home: CODEX_HOME and USERPROFILE are unset")
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut unique = Vec::new();
    for path in paths {
        let duplicate = unique.iter().any(|existing: &PathBuf| {
            existing
                .to_string_lossy()
                .eq_ignore_ascii_case(&path.to_string_lossy())
        });
        if !duplicate {
            unique.push(path);
        }
    }
    unique
}

fn run_version_command(executable: &Path) -> ResultType<String> {
    let mut child = Command::new(executable)
        .arg("--version")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let started_at = Instant::now();

    loop {
        if let Some(status) = child.try_wait()? {
            let mut stdout = String::new();
            let mut stderr = String::new();
            if let Some(mut pipe) = child.stdout.take() {
                pipe.read_to_string(&mut stdout)?;
            }
            if let Some(mut pipe) = child.stderr.take() {
                pipe.read_to_string(&mut stderr)?;
            }
            if !status.success() {
                bail!(
                    "Codex version command failed for '{}': {}",
                    executable.display(),
                    stderr.trim()
                );
            }
            return Ok(stdout);
        }

        if started_at.elapsed() >= COMMAND_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            bail!(
                "Codex version command timed out for '{}'",
                executable.display()
            );
        }

        thread::sleep(COMMAND_POLL_INTERVAL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn parses_codex_cli_version_output() {
        assert_eq!(
            parse_version("codex-cli 0.155.1\r\n").as_deref(),
            Some("0.155.1")
        );
        assert_eq!(parse_version("codex 1.2.3").as_deref(), Some("1.2.3"));
        assert_eq!(parse_version("unexpected").as_deref(), None);
    }

    #[test]
    fn selects_first_existing_candidate_in_priority_order() {
        let candidates = vec![
            PathBuf::from(r"C:\override\codex.exe"),
            PathBuf::from(r"C:\primary\codex.exe"),
            PathBuf::from(r"C:\desktop\codex.exe"),
        ];

        let selected = select_existing_candidate(candidates, |path| {
            path == std::path::Path::new(r"C:\primary\codex.exe")
                || path == std::path::Path::new(r"C:\desktop\codex.exe")
        });

        assert_eq!(selected, Some(PathBuf::from(r"C:\primary\codex.exe")));
    }

    #[test]
    fn missing_candidates_return_none() {
        let selected =
            select_existing_candidate(vec![PathBuf::from(r"C:\missing\codex.exe")], |_| false);

        assert_eq!(selected, None);
    }

    #[test]
    fn installation_presence_probe_does_not_require_version_execution() {
        let selected =
            select_existing_candidate(vec![PathBuf::from(r"C:\present\codex.exe")], |path| {
                path == std::path::Path::new(r"C:\present\codex.exe")
            });

        assert!(selected.is_some());
    }
}
