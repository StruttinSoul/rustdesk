//! Lightweight timing for the emulator video path: per-stage samples summarised
//! into one log line per interval, and tap-to-frame latency.

use std::{
    collections::BTreeMap,
    sync::Mutex,
    time::{Duration, Instant},
};

/// A tap older than this is not matched to a frame (the screen did not change).
const TAP_MATCH_LIMIT: Duration = Duration::from_secs(2);

pub struct TimingWindow {
    name: &'static str,
    interval: Duration,
    started: Instant,
    samples: BTreeMap<&'static str, Vec<f64>>,
    counts: BTreeMap<&'static str, u64>,
}

impl TimingWindow {
    pub fn new(name: &'static str, interval: Duration, now: Instant) -> Self {
        Self {
            name,
            interval,
            started: now,
            samples: BTreeMap::new(),
            counts: BTreeMap::new(),
        }
    }

    pub fn sample(&mut self, stage: &'static str, ms: f64) {
        self.samples.entry(stage).or_default().push(ms);
    }

    pub fn count(&mut self, name: &'static str) {
        *self.counts.entry(name).or_default() += 1;
    }

    /// One summary line once `interval` has passed and something was recorded;
    /// the window then starts over.
    pub fn take_due(&mut self, now: Instant) -> Option<String> {
        let elapsed = now.saturating_duration_since(self.started);
        if elapsed < self.interval {
            return None;
        }
        let empty = self.samples.is_empty() && self.counts.is_empty();
        let mut line = format!("{} {:.1}s:", self.name, elapsed.as_secs_f64());
        for (stage, values) in &mut self.samples {
            values.sort_by(|a, b| a.total_cmp(b));
            let rank = |p: f64| values[((values.len() as f64 * p).ceil() as usize).max(1) - 1];
            line += &format!(
                " | {stage} n={} p50={:.1} p90={:.1} max={:.1}",
                values.len(),
                rank(0.5),
                rank(0.9),
                values[values.len() - 1]
            );
        }
        for (name, count) in &self.counts {
            line += &format!(" | {name}={count}");
        }
        self.started = now;
        self.samples.clear();
        self.counts.clear();
        (!empty).then_some(line)
    }
}

/// The last touch-down, matched to the first frame that follows it.
pub struct TapTracker(Mutex<Option<Instant>>);

impl TapTracker {
    pub const fn new() -> Self {
        Self(Mutex::new(None))
    }

    pub fn touch_down(&self, at: Instant) {
        if let Ok(mut pending) = self.0.lock() {
            *pending = Some(at);
        }
    }

    /// Latency from the pending tap to `frame_at`, reported once per tap.
    pub fn take_latency(&self, frame_at: Instant) -> Option<Duration> {
        let tap = self.0.lock().ok()?.take()?;
        let latency = frame_at.saturating_duration_since(tap);
        (latency <= TAP_MATCH_LIMIT).then_some(latency)
    }
}

/// Phone side: touch-down sent to the PC -> first guest frame received.
pub static CLIENT_TAPS: TapTracker = TapTracker::new();
/// PC side: touch-down written to the guest -> first guest frame read.
pub static HOST_TAPS: TapTracker = TapTracker::new();

pub fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summarises_each_stage_once_per_interval() {
        let start = Instant::now();
        let mut window = TimingWindow::new("guest video", Duration::from_secs(5), start);
        for value in [10.0, 20.0, 30.0, 40.0, 100.0] {
            window.sample("decode", value);
        }
        window.count("refresh");
        assert_eq!(window.take_due(start + Duration::from_secs(4)), None);
        let line = window.take_due(start + Duration::from_secs(5)).unwrap();
        assert!(line.starts_with("guest video 5.0s"), "{line}");
        assert!(line.contains("decode n=5 p50=30.0 p90=100.0 max=100.0"), "{line}");
        assert!(line.contains("refresh=1"), "{line}");
        // Starts over.
        assert_eq!(window.take_due(start + Duration::from_secs(11)), None);
    }

    #[test]
    fn a_tap_is_matched_to_the_next_frame_once() {
        let tracker = TapTracker::new();
        let tap = Instant::now();
        assert_eq!(tracker.take_latency(tap), None);
        tracker.touch_down(tap);
        assert_eq!(
            tracker.take_latency(tap + Duration::from_millis(80)),
            Some(Duration::from_millis(80))
        );
        assert_eq!(tracker.take_latency(tap + Duration::from_millis(90)), None);
    }

    #[test]
    fn a_stale_tap_is_not_matched() {
        let tracker = TapTracker::new();
        let tap = Instant::now();
        tracker.touch_down(tap);
        assert_eq!(tracker.take_latency(tap + Duration::from_secs(3)), None);
        assert_eq!(tracker.take_latency(tap + Duration::from_secs(3)), None);
    }
}
