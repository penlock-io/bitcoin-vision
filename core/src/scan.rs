//! How a caller follows a scan: an ordered log of what the scan has done, the
//! state that log folds to, and a way to ask it to stop.
//!
//! A scan is split in two. The pipeline runs it on whatever thread the caller
//! gives it and records its progress through an [`Emitter`]; any number of
//! [`ScanState`] handles, on any thread, read that record while it runs and
//! after it ends. Nothing is pushed to the caller: a caller that looks late
//! gets everything it missed, and one that never looks costs the scan nothing
//! but the record.
//!
//! The protocol is the same for every pipeline. What a phase, a region and a
//! result are is the pipeline's, through [`Pipeline`].

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

/// A region's identity: stable for one scan, never reused within it.
pub type RegionId = u32;

/// What one pipeline's scan reports.
pub trait Pipeline: 'static {
    /// A stage of the work, for progress display.
    type Phase: Clone + std::fmt::Debug + PartialEq + Send + Sync;
    /// Everything known about one region at a moment: where it is and how far
    /// its reading has got.
    type Region: Clone + std::fmt::Debug + PartialEq + Send + Sync;
    /// A successful scan's result.
    type Output: std::fmt::Debug + Send + Sync;
    /// Why a scan failed.
    type Error: Clone + std::fmt::Debug + Send + Sync;
}

/// One thing a scan did, in the order it did it.
#[derive(Debug)]
pub enum Delta<P: Pipeline> {
    /// The photo's canonical dimensions.
    Photo {
        /// Pixels across.
        width: u32,
        /// Pixels down.
        height: u32,
    },
    /// Progress through a phase. `total` is `None` when the amount of work is
    /// not known yet, never a guess.
    Work {
        /// The phase.
        phase: P::Phase,
        /// Units done in this phase.
        completed: u32,
        /// Units in this phase, once fixed.
        total: Option<u32>,
    },
    /// Insert a region, or replace everything known about it.
    Region {
        /// Its identity.
        id: RegionId,
        /// Its complete current state.
        region: P::Region,
    },
    /// Retire `parents` and insert `id` in their place, as one step.
    Replaced {
        /// The new identity.
        id: RegionId,
        /// Its complete state.
        region: P::Region,
        /// The identities it replaces.
        parents: Vec<RegionId>,
    },
    /// Retire a region with nothing in its place.
    Removed {
        /// The retired identity.
        id: RegionId,
    },
    /// The scan succeeded. Nothing follows.
    Finished(Arc<P::Output>),
    /// The scan failed. Nothing follows.
    Failed(P::Error),
    /// The scan stopped because it was asked to. Nothing follows.
    Cancelled,
}

impl<P: Pipeline> Clone for Delta<P> {
    fn clone(&self) -> Self {
        match self {
            Self::Photo { width, height } => Self::Photo {
                width: *width,
                height: *height,
            },
            Self::Work {
                phase,
                completed,
                total,
            } => Self::Work {
                phase: phase.clone(),
                completed: *completed,
                total: *total,
            },
            Self::Region { id, region } => Self::Region {
                id: *id,
                region: region.clone(),
            },
            Self::Replaced {
                id,
                region,
                parents,
            } => Self::Replaced {
                id: *id,
                region: region.clone(),
                parents: parents.clone(),
            },
            Self::Removed { id } => Self::Removed { id: *id },
            Self::Finished(output) => Self::Finished(output.clone()),
            Self::Failed(error) => Self::Failed(error.clone()),
            Self::Cancelled => Self::Cancelled,
        }
    }
}

impl<P: Pipeline> Delta<P> {
    /// Whether this ends the scan.
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Finished(_) | Self::Failed(_) | Self::Cancelled)
    }
}

/// A position in a scan's log: every delta before it has been seen.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct Cursor(usize);

/// How a scan ended.
#[derive(Debug)]
pub enum Outcome<P: Pipeline> {
    /// It succeeded.
    Finished(Arc<P::Output>),
    /// It failed.
    Failed(P::Error),
    /// It was asked to stop, and did.
    Cancelled,
}

impl<P: Pipeline> Clone for Outcome<P> {
    fn clone(&self) -> Self {
        match self {
            Self::Finished(output) => Self::Finished(output.clone()),
            Self::Failed(error) => Self::Failed(error.clone()),
            Self::Cancelled => Self::Cancelled,
        }
    }
}

/// Everything the log says, folded, as of `cursor`.
#[derive(Debug)]
pub struct Snapshot<P: Pipeline> {
    /// The deltas this snapshot folds are exactly those before this cursor.
    pub cursor: Cursor,
    /// The photo's canonical dimensions, once known.
    pub photo: Option<(u32, u32)>,
    /// The latest progress report.
    pub work: Option<(P::Phase, u32, Option<u32>)>,
    /// Every live region by identity.
    pub regions: BTreeMap<RegionId, P::Region>,
    /// Every identity retired so far, in the order it was retired.
    pub retired: Vec<RegionId>,
    /// How the scan ended, once it has.
    pub outcome: Option<Outcome<P>>,
}

impl<P: Pipeline> Clone for Snapshot<P> {
    fn clone(&self) -> Self {
        Self {
            cursor: self.cursor,
            photo: self.photo,
            work: self.work.clone(),
            regions: self.regions.clone(),
            retired: self.retired.clone(),
            outcome: self.outcome.clone(),
        }
    }
}

impl<P: Pipeline> Default for Snapshot<P> {
    fn default() -> Self {
        Self {
            cursor: Cursor::default(),
            photo: None,
            work: None,
            regions: BTreeMap::new(),
            retired: Vec::new(),
            outcome: None,
        }
    }
}

impl<P: Pipeline> Snapshot<P> {
    /// This snapshot with `delta` applied: the fold a caller can run itself
    /// over the deltas it polled, and arrive where [`ScanState::snapshot`] is.
    pub fn apply(&mut self, delta: &Delta<P>) {
        match delta {
            Delta::Photo { width, height } => self.photo = Some((*width, *height)),
            Delta::Work {
                phase,
                completed,
                total,
            } => self.work = Some((phase.clone(), *completed, *total)),
            Delta::Region { id, region } => {
                self.regions.insert(*id, region.clone());
            }
            Delta::Replaced {
                id,
                region,
                parents,
            } => {
                for parent in parents {
                    self.retire(*parent);
                }
                self.regions.insert(*id, region.clone());
            }
            Delta::Removed { id } => self.retire(*id),
            Delta::Finished(output) => self.outcome = Some(Outcome::Finished(output.clone())),
            Delta::Failed(error) => self.outcome = Some(Outcome::Failed(error.clone())),
            Delta::Cancelled => self.outcome = Some(Outcome::Cancelled),
        }
        self.cursor.0 += 1;
    }

    fn retire(&mut self, id: RegionId) {
        if self.regions.remove(&id).is_some() {
            self.retired.push(id);
        }
    }
}

struct Record<P: Pipeline> {
    deltas: Vec<Delta<P>>,
    folded: Snapshot<P>,
}

struct Shared<P: Pipeline> {
    record: Mutex<Record<P>>,
    grew: Condvar,
    cancel: AtomicBool,
}

impl<P: Pipeline> Shared<P> {
    // A panic while holding the lock leaves the record as it was before the
    // push that panicked, which is still a consistent log.
    fn lock(&self) -> MutexGuard<'_, Record<P>> {
        self.record.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The producer's end: the only way a scan's record grows.
pub struct Emitter<P: Pipeline> {
    shared: Arc<Shared<P>>,
}

/// A caller's view of one scan. Clone it freely; every clone reads the same
/// record.
pub struct ScanState<P: Pipeline> {
    shared: Arc<Shared<P>>,
}

impl<P: Pipeline> Clone for ScanState<P> {
    fn clone(&self) -> Self {
        Self {
            shared: self.shared.clone(),
        }
    }
}

/// The record already ended; nothing more may be added to it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ended;

/// A fresh scan record: the producer's end and a caller's view of it.
pub fn record<P: Pipeline>() -> (Emitter<P>, ScanState<P>) {
    let shared = Arc::new(Shared {
        record: Mutex::new(Record {
            deltas: Vec::new(),
            folded: Snapshot::default(),
        }),
        grew: Condvar::new(),
        cancel: AtomicBool::new(false),
    });
    (
        Emitter {
            shared: shared.clone(),
        },
        ScanState { shared },
    )
}

impl<P: Pipeline> Emitter<P> {
    /// Appends `delta`. Refused once a terminal delta is in the record, so a
    /// scan cannot report anything after it ended.
    pub fn push(&self, delta: Delta<P>) -> Result<(), Ended> {
        let mut record = self.shared.lock();
        if record.folded.outcome.is_some() {
            return Err(Ended);
        }
        record.folded.apply(&delta);
        record.deltas.push(delta);
        drop(record);
        self.shared.grew.notify_all();
        Ok(())
    }

    /// Whether a caller has asked the scan to stop. The scan checks this at
    /// its own boundaries and ends with [`Delta::Cancelled`] when it stops.
    pub fn cancel_requested(&self) -> bool {
        self.shared.cancel.load(Ordering::Acquire)
    }
}

impl<P: Pipeline> ScanState<P> {
    /// Every delta after `since`, and the cursor after the last of them.
    /// Never blocks on the scan's work, only on the record's lock.
    pub fn poll(&self, since: Cursor) -> (Vec<Delta<P>>, Cursor) {
        let record = self.shared.lock();
        let from = since.0.min(record.deltas.len());
        (record.deltas[from..].to_vec(), Cursor(record.deltas.len()))
    }

    /// [`ScanState::poll`], waiting up to `timeout` for there to be something
    /// after `since` unless the record has already ended.
    pub fn wait(&self, since: Cursor, timeout: Duration) -> (Vec<Delta<P>>, Cursor) {
        let record = self.shared.lock();
        let record = self
            .shared
            .grew
            .wait_timeout_while(record, timeout, |r| {
                r.deltas.len() <= since.0 && r.folded.outcome.is_none()
            })
            .map(|(guard, _)| guard)
            .unwrap_or_else(|e| e.into_inner().0);
        let from = since.0.min(record.deltas.len());
        (record.deltas[from..].to_vec(), Cursor(record.deltas.len()))
    }

    /// The whole record folded, with the cursor it is folded to, taken as one
    /// read: polling from `snapshot().cursor` misses nothing and repeats
    /// nothing.
    pub fn snapshot(&self) -> Snapshot<P> {
        self.shared.lock().folded.clone()
    }

    /// Asks the scan to stop. A scan that has already ended keeps its outcome.
    pub fn cancel(&self) {
        self.shared.cancel.store(true, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug)]
    struct Test;
    impl Pipeline for Test {
        type Phase = &'static str;
        type Region = u32;
        type Output = String;
        type Error = String;
    }

    fn region(id: RegionId, value: u32) -> Delta<Test> {
        Delta::Region { id, region: value }
    }

    #[test]
    fn a_late_poll_gets_everything_since_its_cursor_once() {
        let (emit, state) = record::<Test>();
        let (none, start) = state.poll(Cursor::default());
        assert!(none.is_empty());
        for id in 0..5 {
            emit.push(region(id, id * 10)).unwrap();
        }
        let (first, at) = state.poll(start);
        assert_eq!(first.len(), 5);
        let (again, same) = state.poll(at);
        assert!(again.is_empty());
        assert_eq!(same, at);
        emit.push(Delta::Removed { id: 2 }).unwrap();
        let (next, _) = state.poll(at);
        assert!(matches!(next.as_slice(), [Delta::Removed { id: 2 }]));
    }

    #[test]
    fn folding_what_was_polled_arrives_at_the_snapshot() {
        let (emit, state) = record::<Test>();
        let mut folded = Snapshot::<Test>::default();
        let mut cursor = Cursor::default();
        let script = [
            Delta::Photo {
                width: 4,
                height: 3,
            },
            Delta::Work {
                phase: "reading",
                completed: 0,
                total: Some(2),
            },
            region(0, 1),
            region(1, 2),
            Delta::Replaced {
                id: 2,
                region: 3,
                parents: vec![0, 1],
            },
            region(3, 4),
            Delta::Removed { id: 3 },
            Delta::Finished(Arc::new("done".into())),
        ];
        for delta in script {
            emit.push(delta).unwrap();
            let (new, at) = state.poll(cursor);
            for delta in &new {
                folded.apply(delta);
            }
            cursor = at;
            let snapshot = state.snapshot();
            assert_eq!(snapshot.cursor, cursor);
            assert_eq!(snapshot.regions, folded.regions);
            assert_eq!(snapshot.retired, folded.retired);
        }
        let snapshot = state.snapshot();
        assert_eq!(snapshot.photo, Some((4, 3)));
        assert_eq!(
            snapshot.regions.into_iter().collect::<Vec<_>>(),
            vec![(2, 3)]
        );
        assert_eq!(snapshot.retired, vec![0, 1, 3]);
        assert!(matches!(snapshot.outcome, Some(Outcome::Finished(ref o)) if o.as_str() == "done"));
    }

    #[test]
    fn nothing_is_recorded_after_the_scan_ends() {
        for end in [
            Delta::Finished(Arc::new(String::new())),
            Delta::Failed("broke".into()),
            Delta::Cancelled,
        ] {
            let (emit, state) = record::<Test>();
            emit.push(region(0, 0)).unwrap();
            emit.push(end).unwrap();
            let before = state.poll(Cursor::default()).1;
            assert_eq!(emit.push(region(1, 1)), Err(Ended));
            assert_eq!(emit.push(Delta::Cancelled), Err(Ended));
            assert_eq!(state.poll(Cursor::default()).1, before);
        }
    }

    #[test]
    fn a_cancel_after_the_scan_finished_leaves_it_finished() {
        let (emit, state) = record::<Test>();
        emit.push(Delta::Finished(Arc::new("done".into()))).unwrap();
        state.cancel();
        assert!(emit.cancel_requested());
        assert_eq!(emit.push(Delta::Cancelled), Err(Ended));
        assert!(matches!(
            state.snapshot().outcome,
            Some(Outcome::Finished(_))
        ));
    }

    #[test]
    fn a_cancel_is_seen_by_the_producer_which_ends_the_record() {
        let (emit, state) = record::<Test>();
        assert!(!emit.cancel_requested());
        state.clone().cancel();
        assert!(emit.cancel_requested());
        emit.push(Delta::Cancelled).unwrap();
        assert!(matches!(state.snapshot().outcome, Some(Outcome::Cancelled)));
    }

    #[test]
    fn deltas_pushed_from_several_threads_arrive_whole_and_in_one_order() {
        let (emit, state) = record::<Test>();
        let emit = Arc::new(emit);
        std::thread::scope(|scope| {
            for worker in 0..4u32 {
                let emit = emit.clone();
                scope.spawn(move || {
                    for k in 0..250 {
                        emit.push(region(worker * 1000 + k, k)).unwrap();
                    }
                });
            }
            let mut cursor = Cursor::default();
            let mut seen = 0;
            while seen < 1000 {
                let (new, at) = state.wait(cursor, Duration::from_millis(50));
                seen += new.len();
                cursor = at;
            }
        });
        let (all, _) = state.poll(Cursor::default());
        assert_eq!(all.len(), 1000);
        for worker in 0..4u32 {
            let order: Vec<u32> = all
                .iter()
                .filter_map(|d| match d {
                    Delta::Region { id, region } if id / 1000 == worker => Some(*region),
                    _ => None,
                })
                .collect();
            assert_eq!(order, (0..250).collect::<Vec<_>>());
        }
        assert_eq!(state.snapshot().regions.len(), 1000);
    }

    #[test]
    fn a_wait_returns_at_the_end_without_waiting_out_its_timeout() {
        let (emit, state) = record::<Test>();
        emit.push(Delta::Failed("broke".into())).unwrap();
        let (_, at) = state.poll(Cursor::default());
        let started = std::time::Instant::now();
        let (new, same) = state.wait(at, Duration::from_secs(10));
        assert!(new.is_empty());
        assert_eq!(same, at);
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
