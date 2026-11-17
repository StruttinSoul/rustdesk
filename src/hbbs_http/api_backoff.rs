//! Pauses the host's background posts (heartbeat, sysinfo, audit) to an API
//! server that cannot be reached, instead of retrying and logging every few
//! seconds. Only transport failures count: any HTTP answer, even an error
//! status, means the server is reachable and resets the pause.

use hbb_common::{bail, log, ResultType};
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

/// Consecutive failures before requests are paused.
const PAUSE_AFTER: u32 = 2;
const FIRST_PAUSE: Duration = Duration::from_secs(10);
const MAX_PAUSE: Duration = Duration::from_secs(300);
/// Start of the error returned for a paused request.
pub(crate) const PAUSED: &str = "API server unreachable; request paused";

#[derive(Debug, Default)]
struct Target {
    failures: u32,
    retry_at: Option<Instant>,
}

#[derive(Debug, Default)]
struct Targets(HashMap<String, Target>);

impl Targets {
    /// How long requests to `key` stay paused, if they are.
    fn paused(&self, key: &str, now: Instant) -> Option<Duration> {
        let retry_at = self.0.get(key)?.retry_at?;
        let left = retry_at.saturating_duration_since(now);
        (!left.is_zero()).then_some(left)
    }

    /// Records the outcome of a request that was sent; returns the line to log
    /// when a pause starts or grows, or when the server is reachable again.
    fn record(&mut self, key: &str, reachable: bool, now: Instant) -> Option<String> {
        if reachable {
            let target = self.0.remove(key)?;
            return (target.failures >= PAUSE_AFTER)
                .then(|| format!("API server {key} is reachable again"));
        }
        let target = self.0.entry(key.to_owned()).or_default();
        target.failures = target.failures.saturating_add(1);
        if target.failures < PAUSE_AFTER {
            return None;
        }
        let doublings = (target.failures - PAUSE_AFTER).min(16);
        let pause = FIRST_PAUSE.saturating_mul(1 << doublings).min(MAX_PAUSE);
        target.retry_at = Some(now + pause);
        Some(format!(
            "API server {key} unreachable ({} failed attempts); pausing its requests for {} s",
            target.failures,
            pause.as_secs()
        ))
    }
}

/// `scheme://host:port` of `url`, the unit that is paused.
fn target_key(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    let port = parsed.port_or_known_default()?;
    Some(format!("{}://{host}:{port}", parsed.scheme()))
}

fn targets() -> std::sync::MutexGuard<'static, Targets> {
    static TARGETS: OnceLock<Mutex<Targets>> = OnceLock::new();
    // Plain counters: a panicking holder leaves nothing half-updated.
    TARGETS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Fails at once while the host's posts to `url`'s server are paused.
/// Other processes (the UI) are never paused: a person is waiting there.
pub(crate) fn check(url: &str) -> ResultType<()> {
    if !crate::is_server() {
        return Ok(());
    }
    let Some(key) = target_key(url) else {
        return Ok(());
    };
    if let Some(left) = targets().paused(&key, Instant::now()) {
        bail!("{PAUSED} for {} s more ({key})", left.as_secs().max(1))
    }
    Ok(())
}

/// Records whether a post to `url` reached its server.
pub(crate) fn record(url: &str, reachable: bool) {
    if !crate::is_server() {
        return;
    }
    let Some(key) = target_key(url) else {
        return;
    };
    let line = targets().record(&key, reachable, Instant::now());
    match line {
        Some(line) if reachable => log::info!("{line}"),
        Some(line) => log::warn!("{line}"),
        None => {}
    }
}

pub(crate) fn is_paused_error(error: &str) -> bool {
    error.starts_with(PAUSED)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "http://10.0.4.93:21114";

    #[test]
    fn keys_are_scheme_host_and_port() {
        assert_eq!(
            target_key("http://10.0.4.93:21114/api/heartbeat").as_deref(),
            Some(KEY)
        );
        assert_eq!(target_key("http://10.0.4.93:21114/api/audit/conn").as_deref(), Some(KEY));
        assert_eq!(
            target_key("https://api.example.com/api/sysinfo").as_deref(),
            Some("https://api.example.com:443")
        );
        assert_eq!(target_key("not a url"), None);
    }

    #[test]
    fn one_failure_does_not_pause() {
        let mut targets = Targets::default();
        let now = Instant::now();
        assert_eq!(targets.record(KEY, false, now), None);
        assert_eq!(targets.paused(KEY, now), None);
    }

    #[test]
    fn repeated_failures_pause_with_a_doubling_capped_window() {
        let mut targets = Targets::default();
        let mut now = Instant::now();
        targets.record(KEY, false, now);
        let mut expected = FIRST_PAUSE;
        for _ in 0..8 {
            let line = targets.record(KEY, false, now).expect("one line per pause");
            assert!(line.contains(KEY), "{line}");
            assert!(line.contains(&format!("{} s", expected.as_secs())), "{line}");
            assert_eq!(targets.paused(KEY, now), Some(expected));
            assert!(targets.paused(KEY, now + expected).is_none());
            now += expected;
            expected = (expected * 2).min(MAX_PAUSE);
        }
        assert_eq!(targets.paused(KEY, now - MAX_PAUSE), Some(MAX_PAUSE));
    }

    #[test]
    fn a_reachable_server_resets_the_pause_and_says_so_once() {
        let mut targets = Targets::default();
        let now = Instant::now();
        targets.record(KEY, false, now);
        targets.record(KEY, false, now);
        let line = targets.record(KEY, true, now + FIRST_PAUSE).expect("recovery line");
        assert!(line.contains("reachable again"), "{line}");
        assert_eq!(targets.paused(KEY, now + FIRST_PAUSE), None);
        assert_eq!(targets.record(KEY, true, now + FIRST_PAUSE), None);
        // After recovery a single failure does not pause again.
        assert_eq!(targets.record(KEY, false, now + FIRST_PAUSE), None);
        assert_eq!(targets.paused(KEY, now + FIRST_PAUSE), None);
    }

    #[test]
    fn a_reachable_server_is_never_paused_or_logged() {
        let mut targets = Targets::default();
        let now = Instant::now();
        for _ in 0..10 {
            assert_eq!(targets.record(KEY, true, now), None);
        }
        assert_eq!(targets.paused(KEY, now), None);
    }

    #[test]
    fn servers_are_paused_independently() {
        let mut targets = Targets::default();
        let now = Instant::now();
        targets.record(KEY, false, now);
        targets.record(KEY, false, now);
        assert!(targets.paused(KEY, now).is_some());
        assert_eq!(targets.paused("http://10.0.4.93:21115", now), None);
    }

    #[test]
    fn paused_errors_are_recognised() {
        assert!(is_paused_error(&format!("{PAUSED} for 9 s more ({KEY})")));
        assert!(!is_paused_error("tcp connect error"));
    }
}
