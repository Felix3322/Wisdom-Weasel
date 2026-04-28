use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use tracing::warn;

const EPSILON: f32 = 1e-6;
const SNAPSHOT_VERSION_V1: u32 = 1;

#[derive(Debug, Clone)]
pub struct UserFrequencyConfig {
    pub enabled: bool,
    pub persistence_path: Option<PathBuf>,
    pub session_weight: f32,
    pub long_term_weight: f32,
    pub session_decay: f32,
    pub long_term_decay: f32,
    pub min_count_threshold: f32,
    pub saturation: f32,
    pub save_every_updates: usize,
}

impl UserFrequencyConfig {
    pub fn sanitize(mut self) -> Self {
        self.session_weight = self.session_weight.max(0.0);
        self.long_term_weight = self.long_term_weight.max(0.0);
        self.session_decay = self.session_decay.clamp(0.0, 1.0);
        self.long_term_decay = self.long_term_decay.clamp(0.0, 1.0);
        self.min_count_threshold = self.min_count_threshold.max(0.0);
        self.saturation = self.saturation.max(EPSILON);
        self.save_every_updates = self.save_every_updates.max(1);
        self
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct UserFrequencySnapshotV1 {
    version: u32,
    session_counts: HashMap<String, f32>,
    long_term_counts: HashMap<String, f32>,
}

#[derive(Debug, Clone)]
pub struct UserFrequencyScorer {
    config: UserFrequencyConfig,
    session_counts: HashMap<String, f32>,
    long_term_counts: HashMap<String, f32>,
}

impl UserFrequencyScorer {
    pub fn disabled(config: UserFrequencyConfig) -> Self {
        Self {
            config,
            session_counts: HashMap::new(),
            long_term_counts: HashMap::new(),
        }
    }

    pub fn score(&self, candidate: &str) -> f32 {
        if !self.config.enabled {
            return 0.0;
        }

        let key = normalize_key(candidate);
        if key.is_empty() {
            return 0.0;
        }

        let session_count = *self.session_counts.get(&key).unwrap_or(&0.0);
        let long_term_count = *self.long_term_counts.get(&key).unwrap_or(&0.0);
        let weighted = (self.config.session_weight * session_count)
            + (self.config.long_term_weight * long_term_count);
        if weighted <= self.config.min_count_threshold {
            return 0.0;
        }

        ((weighted - self.config.min_count_threshold + 1.0).ln() / self.config.saturation).clamp(0.0, 1.0)
    }
}

pub struct UserFrequencyStore {
    config: UserFrequencyConfig,
    session_counts: HashMap<String, f32>,
    long_term_counts: HashMap<String, f32>,
    dirty_updates: usize,
}

impl UserFrequencyStore {
    pub fn load(config: UserFrequencyConfig) -> Self {
        let config = config.sanitize();
        let mut store = Self {
            config,
            session_counts: HashMap::new(),
            long_term_counts: HashMap::new(),
            dirty_updates: 0,
        };
        store.try_load_snapshot();
        store
    }

    pub fn scorer(&self) -> UserFrequencyScorer {
        if !self.config.enabled {
            return UserFrequencyScorer::disabled(self.config.clone());
        }
        UserFrequencyScorer {
            config: self.config.clone(),
            session_counts: self.session_counts.clone(),
            long_term_counts: self.long_term_counts.clone(),
        }
    }

    pub fn record_committed_text(&mut self, committed_text: &str) {
        if !self.config.enabled {
            return;
        }

        let key = normalize_key(committed_text);
        if key.is_empty() {
            return;
        }

        self.apply_decay();
        *self.session_counts.entry(key.clone()).or_insert(0.0) += 1.0;
        *self.long_term_counts.entry(key).or_insert(0.0) += 1.0;
        self.dirty_updates += 1;
        self.persist_if_needed(false);
    }

    fn try_load_snapshot(&mut self) {
        let Some(path) = self.config.persistence_path.clone() else {
            return;
        };
        if !path.exists() {
            return;
        }

        let content = match fs::read(&path) {
            Ok(content) => content,
            Err(err) => {
                warn!(
                    "failed to read user frequency snapshot from {}: {}",
                    path.display(),
                    err
                );
                return;
            }
        };

        let snapshot: UserFrequencySnapshotV1 = match serde_json::from_slice(&content) {
            Ok(snapshot) => snapshot,
            Err(err) => {
                warn!(
                    "failed to parse user frequency snapshot from {}: {}",
                    path.display(),
                    err
                );
                return;
            }
        };

        if snapshot.version != SNAPSHOT_VERSION_V1 {
            warn!(
                "ignored user frequency snapshot from {} due to unsupported version {}",
                path.display(),
                snapshot.version
            );
            return;
        }

        self.session_counts = snapshot.session_counts;
        self.long_term_counts = snapshot.long_term_counts;
        self.prune_small_counts();
        self.dirty_updates = 0;
    }

    fn apply_decay(&mut self) {
        if self.config.session_decay > 0.0 {
            decay_counts(&mut self.session_counts, self.config.session_decay);
        }
        if self.config.long_term_decay > 0.0 {
            decay_counts(&mut self.long_term_counts, self.config.long_term_decay);
        }
        self.prune_small_counts();
    }

    fn prune_small_counts(&mut self) {
        prune_counts(&mut self.session_counts);
        prune_counts(&mut self.long_term_counts);
    }

    fn persist_if_needed(&mut self, force: bool) {
        if !self.config.enabled {
            return;
        }
        if !force && self.dirty_updates < self.config.save_every_updates {
            return;
        }
        let Some(path) = &self.config.persistence_path else {
            return;
        };

        if let Some(parent) = path.parent() {
            if let Err(err) = fs::create_dir_all(parent) {
                warn!(
                    "failed to create user frequency snapshot directory {}: {}",
                    parent.display(),
                    err
                );
                return;
            }
        }

        let snapshot = UserFrequencySnapshotV1 {
            version: SNAPSHOT_VERSION_V1,
            session_counts: self.session_counts.clone(),
            long_term_counts: self.long_term_counts.clone(),
        };

        match serde_json::to_vec(&snapshot) {
            Ok(serialized) => {
                if let Err(err) = fs::write(path, serialized) {
                    warn!(
                        "failed to persist user frequency snapshot to {}: {}",
                        path.display(),
                        err
                    );
                    return;
                }
                self.dirty_updates = 0;
            }
            Err(err) => {
                warn!(
                    "failed to serialize user frequency snapshot for {}: {}",
                    path.display(),
                    err
                );
            }
        }
    }
}

impl Drop for UserFrequencyStore {
    fn drop(&mut self) {
        self.persist_if_needed(true);
    }
}

fn normalize_key(text: &str) -> String {
    text.trim().to_string()
}

fn decay_counts(counts: &mut HashMap<String, f32>, decay: f32) {
    let keep = (1.0 - decay).clamp(0.0, 1.0);
    if keep >= 1.0 {
        return;
    }
    for value in counts.values_mut() {
        *value *= keep;
    }
}

fn prune_counts(counts: &mut HashMap<String, f32>) {
    counts.retain(|_, value| value.is_finite() && *value > EPSILON);
}
