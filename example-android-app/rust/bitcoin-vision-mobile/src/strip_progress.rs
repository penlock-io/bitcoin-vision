//! Phone projection of the strip scan record. Cell probabilities and text stay
//! in the native result; only work and geometry cross the callback.

use penlock_scan::scan::{Cursor, Delta, ScanState};
use penlock_scan::{Phase, Strips};

use crate::progress::ProgressDeliveryError;

/// A stage of strip recognition.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum StripWorkPhase {
    /// Validate the canonical photo.
    Admitting,
    /// Locate strips.
    Locating,
    /// Report their printed identities.
    Identifying,
    /// Read their cells.
    Reading,
    /// Assemble the result.
    Packing,
}

impl From<Phase> for StripWorkPhase {
    fn from(value: Phase) -> Self {
        match value {
            Phase::Admitting => Self::Admitting,
            Phase::Locating => Self::Locating,
            Phase::Identifying => Self::Identifying,
            Phase::Reading => Self::Reading,
            Phase::Packing => Self::Packing,
        }
    }
}

/// One compact strip progress update, with no cell readings or photo bytes.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum StripProgressUpdate {
    /// Canonical photo dimensions.
    Photo {
        /// Pixels across.
        width: u32,
        /// Pixels down.
        height: u32,
    },
    /// Work in a stage.
    Work {
        /// Current stage.
        phase: StripWorkPhase,
        /// Units completed.
        completed: u32,
        /// Known units, or none while locating.
        total: Option<u32>,
    },
    /// A located strip, later updated when its cells are read.
    Region {
        /// Stable ID in this attempt.
        id: u32,
        /// Four x/y pairs in canonical photo pixels.
        corners: Vec<f64>,
        /// Whether the native result has this strip's cell readings.
        read: bool,
    },
    /// A new region replaces previous region identities.
    Replaced {
        /// New stable identity.
        id: u32,
        /// Four x/y pairs in canonical photo pixels.
        corners: Vec<f64>,
        /// Whether the replacement has cell readings.
        read: bool,
        /// Identities retired by this replacement.
        parents: Vec<u32>,
    },
    /// A region was retired without replacement.
    Removed {
        /// Its stable identity.
        id: u32,
    },
    /// The native result is ready and will be returned by the method.
    Finished,
    /// The native scan failed; its ordinary result carries the reason.
    Failed,
    /// The native scan was cancelled.
    Cancelled,
}

/// A numbered update, so the app can detect a missing callback.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct StripProgressEvent {
    /// Starts at one for each call.
    pub sequence: u64,
    /// Stage, geometry or terminal status.
    pub update: StripProgressUpdate,
}

/// Receives strip progress during `Scanner::read_oriented_with_progress`.
#[uniffi::export(callback_interface)]
pub trait StripProgressObserver: Send + Sync {
    /// Called in sequence before the scan method returns.
    fn on_progress(&self, event: StripProgressEvent) -> Result<(), ProgressDeliveryError>;
}

fn project(delta: Delta<Strips>) -> StripProgressUpdate {
    match delta {
        Delta::Photo { width, height } => StripProgressUpdate::Photo { width, height },
        Delta::Work {
            phase,
            completed,
            total,
        } => StripProgressUpdate::Work {
            phase: phase.into(),
            completed,
            total,
        },
        Delta::Region { id, region } => StripProgressUpdate::Region {
            id,
            corners: region.quad.iter().flat_map(|(x, y)| [*x, *y]).collect(),
            read: region.reading.is_some(),
        },
        Delta::Replaced {
            id,
            region,
            parents,
        } => StripProgressUpdate::Replaced {
            id,
            corners: region.quad.iter().flat_map(|(x, y)| [*x, *y]).collect(),
            read: region.reading.is_some(),
            parents,
        },
        Delta::Removed { id } => StripProgressUpdate::Removed { id },
        Delta::Finished(_) => StripProgressUpdate::Finished,
        Delta::Failed(_) | Delta::Abandoned => StripProgressUpdate::Failed,
        Delta::Cancelled => StripProgressUpdate::Cancelled,
    }
}

/// Drain every native delta through the supplied callback. The scan keeps
/// running if a foreign callback detaches; only observation ends.
pub(crate) fn forward(state: &ScanState<Strips>, callback: &dyn StripProgressObserver) {
    let mut cursor = Cursor::default();
    let mut sequence = 1;
    loop {
        let (events, next) = state.wait(cursor, std::time::Duration::from_millis(50));
        cursor = next;
        for event in events {
            let terminal = event.is_terminal();
            if callback
                .on_progress(StripProgressEvent {
                    sequence,
                    update: project(event),
                })
                .is_err()
            {
                return;
            }
            sequence += 1;
            if terminal {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use penlock_scan::{Identity, StripRegion};

    #[derive(Default)]
    struct Collector(std::sync::Mutex<Vec<StripProgressEvent>>);

    impl StripProgressObserver for Collector {
        fn on_progress(&self, event: StripProgressEvent) -> Result<(), ProgressDeliveryError> {
            self.0.lock().unwrap().push(event);
            Ok(())
        }
    }

    #[test]
    fn phone_region_projects_geometry_without_native_cell_evidence() {
        let update = project(Delta::Region {
            id: 7,
            region: StripRegion {
                quad: [(1., 2.), (3., 4.), (5., 6.), (7., 8.)],
                identity: Identity::Unknown,
                reading: None,
            },
        });
        assert_eq!(
            update,
            StripProgressUpdate::Region {
                id: 7,
                corners: vec![1., 2., 3., 4., 5., 6., 7., 8.],
                read: false,
            }
        );
    }

    #[test]
    fn phone_receives_every_delta_in_order_and_hides_native_error_detail() {
        let (emitter, state) = penlock_scan::scan::record::<Strips>();
        let sink = Collector::default();
        std::thread::scope(|threads| {
            let forwarding = threads.spawn(|| forward(&state, &sink));
            emitter
                .push(Delta::Work {
                    phase: Phase::Locating,
                    completed: 0,
                    total: None,
                })
                .unwrap();
            emitter
                .push(Delta::Photo {
                    width: 100,
                    height: 200,
                })
                .unwrap();
            emitter
                .push(Delta::Region {
                    id: 2,
                    region: StripRegion {
                        quad: [(1., 2.), (3., 4.), (5., 6.), (7., 8.)],
                        identity: Identity::Unknown,
                        reading: None,
                    },
                })
                .unwrap();
            emitter
                .push(Delta::Failed(penlock_scan::ScanError::Image(
                    "secret diagnostic".into(),
                )))
                .unwrap();
            forwarding.join().unwrap();
        });
        let events = sink.0.lock().unwrap();
        assert_eq!(
            events.iter().map(|e| e.sequence).collect::<Vec<_>>(),
            [1, 2, 3, 4]
        );
        assert_eq!(
            events[0].update,
            StripProgressUpdate::Work {
                phase: StripWorkPhase::Locating,
                completed: 0,
                total: None,
            }
        );
        assert_eq!(events[3].update, StripProgressUpdate::Failed);
        assert!(!format!("{events:?}").contains("secret diagnostic"));
    }
}
