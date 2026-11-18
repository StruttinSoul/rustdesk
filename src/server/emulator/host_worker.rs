use super::{
    remote::{GuestEvent, HostOperationReplay},
    remote_windows,
};
use base::message_proto::{EmulatorHostRequest, EmulatorResponse};
use hbb_common::tokio::{
    sync::mpsc::{self, error::TrySendError},
    task::JoinHandle,
};
use std::sync::Arc;

pub const HOST_JOB_QUEUE_SIZE: usize = 32;
const HOST_BUSY: &str = "Host is busy; retry shortly";

pub enum HostJobKind {
    List,
    Host(EmulatorHostRequest),
}

pub struct HostJob {
    pub request_id: u64,
    pub kind: HostJobKind,
    pub operation_identity: String,
    pub generation: u64,
}

// Dropping the handle cancels jobs that have not started, so nothing queued before a
// connection close or login reset runs afterwards. A job already inside spawn_blocking
// finishes, but its result is not delivered.
pub struct HostWorker {
    jobs: mpsc::Sender<HostJob>,
    task: JoinHandle<()>,
}

impl HostWorker {
    fn spawn<E>(events: mpsc::Sender<GuestEvent>, execute: E) -> Self
    where
        E: Fn(HostJob) -> EmulatorResponse + Send + Sync + 'static,
    {
        let (jobs, receiver) = mpsc::channel(HOST_JOB_QUEUE_SIZE);
        let task = hbb_common::tokio::spawn(run(receiver, events, Arc::new(execute)));
        Self { jobs, task }
    }
}

impl Drop for HostWorker {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub fn queue(
    worker: &mut Option<HostWorker>,
    events: &mpsc::Sender<GuestEvent>,
    job: HostJob,
) -> Result<(), EmulatorResponse> {
    queue_with(worker, job, || {
        HostWorker::spawn(events.clone(), run_host_job)
    })
}

fn queue_with(
    worker: &mut Option<HostWorker>,
    job: HostJob,
    spawn: impl FnOnce() -> HostWorker,
) -> Result<(), EmulatorResponse> {
    let id = job.request_id;
    match worker.get_or_insert_with(spawn).jobs.try_send(job) {
        Ok(()) => Ok(()),
        Err(error) => {
            if matches!(error, TrySendError::Closed(_)) {
                *worker = None;
            }
            Err(remote_windows::error_response(id, HOST_BUSY))
        }
    }
}

pub fn is_current(result_generation: u64, connection_generation: u64) -> bool {
    result_generation == connection_generation
}

async fn run<E>(
    mut jobs: mpsc::Receiver<HostJob>,
    events: mpsc::Sender<GuestEvent>,
    execute: Arc<E>,
) where
    E: Fn(HostJob) -> EmulatorResponse + Send + Sync + 'static,
{
    let mut replay = HostOperationReplay::default();
    while let Some(job) = jobs.recv().await {
        let id = job.request_id;
        let generation = job.generation;
        let mutation = match &job.kind {
            HostJobKind::Host(host) if !is_read_only(&host.action) => Some(host.clone()),
            _ => None,
        };
        let response = match mutation {
            Some(host) => {
                let execute = execute.clone();
                replay
                    .apply(&host, id, || execute_blocking(execute, job))
                    .await
            }
            None => execute_blocking(execute.clone(), job).await,
        };
        if events
            .send(GuestEvent::Host {
                generation,
                response,
            })
            .await
            .is_err()
        {
            break;
        }
    }
}

fn is_read_only(action: &str) -> bool {
    matches!(
        action,
        "status" | "windows_list" | "phone_workspace_support" | "gateway_status" | "avd_settings_get"
    )
}

async fn execute_blocking<E>(execute: Arc<E>, job: HostJob) -> EmulatorResponse
where
    E: Fn(HostJob) -> EmulatorResponse + Send + Sync + 'static,
{
    let id = job.request_id;
    match hbb_common::tokio::task::spawn_blocking(move || execute(job)).await {
        Ok(response) => response,
        Err(error) => remote_windows::error_response(id, error.to_string()),
    }
}

fn run_host_job(job: HostJob) -> EmulatorResponse {
    match job.kind {
        HostJobKind::List => {
            remote_windows::inventory(job.request_id, &job.operation_identity, job.generation)
        }
        HostJobKind::Host(host) if host.action == "status" => {
            super::host_management::handle_request(job.request_id, &host)
        }
        HostJobKind::Host(host) => super::host_management::handle_request_scoped(
            job.request_id,
            &host,
            &job.operation_identity,
            job.generation,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{emulator_response, EmulatorVideoFrame};
    use std::{
        sync::{
            atomic::{AtomicUsize, Ordering},
            mpsc as std_mpsc, Mutex,
        },
        time::Duration,
    };

    struct Gate {
        started: mpsc::UnboundedReceiver<u64>,
        release: std_mpsc::Sender<()>,
        runs: Arc<AtomicUsize>,
    }

    // Every executed job reports that it started, then blocks until released once.
    fn gated_worker(events: &mpsc::Sender<GuestEvent>) -> (Option<HostWorker>, Gate) {
        let (started_tx, started) = mpsc::unbounded_channel();
        let (release, gate) = std_mpsc::channel::<()>();
        let gate = Mutex::new(gate);
        let runs = Arc::new(AtomicUsize::new(0));
        let counter = runs.clone();
        let worker = HostWorker::spawn(events.clone(), move |job: HostJob| {
            counter.fetch_add(1, Ordering::SeqCst);
            let _ = started_tx.send(job.request_id);
            let _ = gate.lock().unwrap().recv();
            remote_windows::error_response(job.request_id, format!("ran {}", job.request_id))
        });
        (
            Some(worker),
            Gate {
                started,
                release,
                runs,
            },
        )
    }

    fn push(worker: &mut Option<HostWorker>, job: HostJob) -> Result<(), EmulatorResponse> {
        queue_with(worker, job, || {
            panic!("The worker should already be running")
        })
    }

    fn job(request_id: u64, kind: HostJobKind) -> HostJob {
        HostJob {
            request_id,
            kind,
            operation_identity: "scope-a".to_owned(),
            generation: 4,
        }
    }

    fn host(action: &str, operation_id: &str, target_identity: &str) -> HostJobKind {
        HostJobKind::Host(EmulatorHostRequest {
            action: action.to_owned(),
            component: "bluestacks_adb".to_owned(),
            operation_id: operation_id.to_owned(),
            session_identity: "scope-a".to_owned(),
            target_identity: target_identity.to_owned(),
            session_generation: 4,
            ..Default::default()
        })
    }

    async fn next_host(events: &mut mpsc::Receiver<GuestEvent>) -> (u64, EmulatorResponse) {
        match hbb_common::tokio::time::timeout(Duration::from_secs(5), events.recv()).await {
            Ok(Some(GuestEvent::Host {
                generation,
                response,
            })) => (generation, response),
            _ => panic!("Expected a host job result"),
        }
    }

    fn error_text(response: &EmulatorResponse) -> &str {
        match response.union.as_ref() {
            Some(emulator_response::Union::Error(error)) => error,
            _ => panic!("Expected an error response"),
        }
    }

    #[hbb_common::tokio::test]
    async fn host_jobs_run_one_at_a_time_in_arrival_order() {
        let (events, mut results) = mpsc::channel(8);
        let (mut worker, mut gate) = gated_worker(&events);
        for id in 1..=3 {
            push(&mut worker, job(id, HostJobKind::List)).unwrap();
        }
        assert_eq!(gate.started.recv().await, Some(1));
        hbb_common::tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(
            gate.started.try_recv().is_err(),
            "A second host job must not start while the first is running"
        );
        for _ in 0..3 {
            gate.release.send(()).unwrap();
        }
        for id in 1..=3 {
            let (_, response) = next_host(&mut results).await;
            assert_eq!(response.request_id, id);
            assert_eq!(error_text(&response), format!("ran {id}"));
        }
    }

    #[hbb_common::tokio::test]
    async fn slow_host_job_does_not_hold_back_guest_events_and_waits_for_room() {
        let frame = |session_id| {
            GuestEvent::Frame(EmulatorVideoFrame {
                session_id,
                ..Default::default()
            })
        };
        let (events, mut results) = mpsc::channel(1);
        let (mut worker, mut gate) = gated_worker(&events);
        push(&mut worker, job(1, HostJobKind::List)).unwrap();
        assert_eq!(gate.started.recv().await, Some(1));
        events.send(frame(7)).await.unwrap();
        match hbb_common::tokio::time::timeout(Duration::from_secs(1), results.recv()).await {
            Ok(Some(GuestEvent::Frame(frame))) => assert_eq!(frame.session_id, 7),
            _ => panic!("A guest frame was held behind a running host job"),
        }
        events.send(frame(8)).await.unwrap();
        gate.release.send(()).unwrap();
        hbb_common::tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(matches!(results.recv().await, Some(GuestEvent::Frame(_))));
        assert_eq!(
            next_host(&mut results).await.1.request_id,
            1,
            "A full event queue delays the host result instead of dropping it"
        );
    }

    #[hbb_common::tokio::test]
    async fn duplicate_mutation_queued_while_running_is_applied_once_and_replayed() {
        let (events, mut results) = mpsc::channel(8);
        let (mut worker, mut gate) = gated_worker(&events);
        let target = "component:bluestacks_adb";
        push(&mut worker, job(1, host("recover", "op-1", target))).unwrap();
        assert_eq!(gate.started.recv().await, Some(1));
        push(&mut worker, job(2, host("recover", "op-1", target))).unwrap();
        push(&mut worker, job(3, host("status", "op-1", ""))).unwrap();
        push(&mut worker, job(4, host("status", "op-1", ""))).unwrap();
        for _ in 0..4 {
            gate.release.send(()).unwrap();
        }
        let (_, first) = next_host(&mut results).await;
        let (_, replayed) = next_host(&mut results).await;
        assert_eq!((first.request_id, error_text(&first)), (1, "ran 1"));
        assert_eq!(
            (replayed.request_id, error_text(&replayed)),
            (2, "ran 1"),
            "The retry must get the stored response under its own request id"
        );
        assert_eq!(error_text(&next_host(&mut results).await.1), "ran 3");
        assert_eq!(error_text(&next_host(&mut results).await.1), "ran 4");
        assert_eq!(
            gate.runs.load(Ordering::SeqCst),
            3,
            "The mutation runs once; read-only actions bypass replay"
        );
    }

    #[hbb_common::tokio::test]
    async fn reused_operation_id_with_another_target_is_rejected() {
        let (events, mut results) = mpsc::channel(8);
        let (mut worker, gate) = gated_worker(&events);
        gate.release.send(()).unwrap();
        push(
            &mut worker,
            job(1, host("recover", "op-1", "component:bluestacks_adb")),
        )
        .unwrap();
        push(
            &mut worker,
            job(2, host("recover", "op-1", "component:other")),
        )
        .unwrap();
        assert_eq!(next_host(&mut results).await.1.request_id, 1);
        let (_, rejected) = next_host(&mut results).await;
        assert_eq!(rejected.request_id, 2);
        assert!(error_text(&rejected).contains("different host operation"));
        assert_eq!(gate.runs.load(Ordering::SeqCst), 1);
    }

    #[hbb_common::tokio::test]
    async fn full_host_queue_answers_busy_without_dropping_the_worker() {
        let (events, _results) = mpsc::channel(8);
        let (mut worker, mut gate) = gated_worker(&events);
        push(&mut worker, job(0, HostJobKind::List)).unwrap();
        assert_eq!(gate.started.recv().await, Some(0));
        for id in 1..=HOST_JOB_QUEUE_SIZE as u64 {
            push(&mut worker, job(id, HostJobKind::List)).unwrap();
        }
        let busy = push(&mut worker, job(99, HostJobKind::List)).unwrap_err();
        assert_eq!(busy.request_id, 99);
        assert_eq!(error_text(&busy), "Host is busy; retry shortly");
        assert!(worker.is_some());
    }

    #[hbb_common::tokio::test]
    async fn gone_worker_answers_busy_and_the_next_job_starts_a_new_one() {
        let (events, mut results) = mpsc::channel(8);
        let (jobs, receiver) = mpsc::channel(1);
        drop(receiver);
        let mut worker = Some(HostWorker {
            jobs,
            task: hbb_common::tokio::spawn(async {}),
        });
        let busy = push(&mut worker, job(1, HostJobKind::List)).unwrap_err();
        assert_eq!(error_text(&busy), "Host is busy; retry shortly");
        assert!(worker.is_none());
        queue_with(&mut worker, job(2, HostJobKind::List), || {
            HostWorker::spawn(events.clone(), |job: HostJob| {
                remote_windows::response(job.request_id)
            })
        })
        .unwrap();
        assert_eq!(next_host(&mut results).await.1.request_id, 2);
    }

    #[hbb_common::tokio::test]
    async fn reset_cancels_queued_jobs_and_discards_stale_results() {
        let (events, mut results) = mpsc::channel(8);
        let (mut worker, mut gate) = gated_worker(&events);
        drop(events);
        gate.release.send(()).unwrap();
        push(&mut worker, job(1, HostJobKind::List)).unwrap();
        let (stale_generation, _) = next_host(&mut results).await;
        push(&mut worker, job(2, HostJobKind::List)).unwrap();
        push(&mut worker, job(3, HostJobKind::List)).unwrap();
        assert_eq!(gate.started.recv().await, Some(1));
        assert_eq!(gate.started.recv().await, Some(2));
        drop(worker);
        let connection_generation = 5;
        assert!(!is_current(stale_generation, connection_generation));
        assert!(is_current(connection_generation, connection_generation));
        gate.release.send(()).unwrap();
        let after_reset =
            hbb_common::tokio::time::timeout(Duration::from_secs(5), results.recv()).await;
        assert!(
            matches!(after_reset, Ok(None)),
            "A dropped worker must end without delivering further results"
        );
        assert_eq!(
            gate.runs.load(Ordering::SeqCst),
            2,
            "Jobs queued before the reset must not run"
        );
    }
}
