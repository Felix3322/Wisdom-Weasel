use ndarray::Array1;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use tracing::warn;

const EPSILON: f32 = 1e-6;
const SNAPSHOT_VERSION_V1: u32 = 1;
const SNAPSHOT_VERSION_V2: u32 = 2;

#[derive(Debug, Clone)]
pub struct PreferenceConfig {
    pub enabled: bool,
    pub persistence_path: Option<PathBuf>,
    pub blend_weight: f32,
    pub negative_weight: f32,
    pub session_weight: f32,
    pub long_term_weight: f32,
    pub session_alpha: f32,
    pub long_term_alpha: f32,
    pub negative_session_alpha: f32,
    pub negative_long_term_alpha: f32,
    pub min_long_term_updates: usize,
    pub save_every_updates: usize,
}

impl PreferenceConfig {
    pub fn sanitize(mut self) -> Self {
        self.blend_weight = self.blend_weight.clamp(0.0, 1.0);
        self.negative_weight = self.negative_weight.clamp(0.0, 1.0);
        self.session_weight = self.session_weight.max(0.0);
        self.long_term_weight = self.long_term_weight.max(0.0);
        self.session_alpha = self.session_alpha.clamp(0.0, 1.0);
        self.long_term_alpha = self.long_term_alpha.clamp(0.0, 1.0);
        self.negative_session_alpha = self.negative_session_alpha.clamp(0.0, 1.0);
        self.negative_long_term_alpha = self.negative_long_term_alpha.clamp(0.0, 1.0);
        self.save_every_updates = self.save_every_updates.max(1);
        self
    }
}

#[derive(Debug, Clone)]
pub struct PreferenceScorer {
    config: PreferenceConfig,
    session_positive_vector: Option<Array1<f32>>,
    session_positive_updates: usize,
    long_term_positive_vector: Option<Array1<f32>>,
    long_term_positive_updates: usize,
    session_negative_vector: Option<Array1<f32>>,
    session_negative_updates: usize,
    long_term_negative_vector: Option<Array1<f32>>,
    long_term_negative_updates: usize,
}

impl PreferenceScorer {
    pub fn disabled(config: PreferenceConfig) -> Self {
        Self {
            config,
            session_positive_vector: None,
            session_positive_updates: 0,
            long_term_positive_vector: None,
            long_term_positive_updates: 0,
            session_negative_vector: None,
            session_negative_updates: 0,
            long_term_negative_vector: None,
            long_term_negative_updates: 0,
        }
    }

    pub fn score(&self, candidate: &Array1<f32>, candidate_norm: f32) -> f32 {
        if !self.config.enabled || candidate_norm <= EPSILON {
            return 0.0;
        }

        let positive_score = self.config.blend_weight
            * weighted_preference_score(
                candidate,
                candidate_norm,
                self.config.session_weight,
                self.session_positive_updates,
                self.session_positive_vector.as_ref(),
                self.config.long_term_weight,
                self.long_term_positive_updates,
                self.long_term_positive_vector.as_ref(),
                self.config.min_long_term_updates,
            );

        let negative_score = self.config.negative_weight
            * weighted_preference_score(
                candidate,
                candidate_norm,
                self.config.session_weight,
                self.session_negative_updates,
                self.session_negative_vector.as_ref(),
                self.config.long_term_weight,
                self.long_term_negative_updates,
                self.long_term_negative_vector.as_ref(),
                self.config.min_long_term_updates,
            );

        positive_score - negative_score
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct PreferenceSnapshotV1 {
    version: u32,
    embedding_dim: usize,
    update_count: usize,
    vector: Vec<f32>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PreferenceSnapshotV2 {
    version: u32,
    embedding_dim: usize,
    positive_update_count: usize,
    negative_update_count: usize,
    positive_vector: Vec<f32>,
    negative_vector: Vec<f32>,
}

pub struct UserPreferenceStore {
    config: PreferenceConfig,
    embedding_dim: usize,
    session_positive_vector: Option<Array1<f32>>,
    session_positive_updates: usize,
    long_term_positive_vector: Option<Array1<f32>>,
    long_term_positive_updates: usize,
    session_negative_vector: Option<Array1<f32>>,
    session_negative_updates: usize,
    long_term_negative_vector: Option<Array1<f32>>,
    long_term_negative_updates: usize,
    dirty_updates: usize,
}

impl UserPreferenceStore {
    pub fn load(config: PreferenceConfig, embedding_dim: usize) -> Self {
        let config = config.sanitize();
        let mut store = Self {
            config,
            embedding_dim,
            session_positive_vector: None,
            session_positive_updates: 0,
            long_term_positive_vector: None,
            long_term_positive_updates: 0,
            session_negative_vector: None,
            session_negative_updates: 0,
            long_term_negative_vector: None,
            long_term_negative_updates: 0,
            dirty_updates: 0,
        };
        store.try_load_snapshot();
        store
    }

    pub fn scorer(&self) -> PreferenceScorer {
        if !self.config.enabled {
            return PreferenceScorer::disabled(self.config.clone());
        }

        PreferenceScorer {
            config: self.config.clone(),
            session_positive_vector: self.session_positive_vector.clone(),
            session_positive_updates: self.session_positive_updates,
            long_term_positive_vector: self.long_term_positive_vector.clone(),
            long_term_positive_updates: self.long_term_positive_updates,
            session_negative_vector: self.session_negative_vector.clone(),
            session_negative_updates: self.session_negative_updates,
            long_term_negative_vector: self.long_term_negative_vector.clone(),
            long_term_negative_updates: self.long_term_negative_updates,
        }
    }

    pub fn update_positive(&mut self, embedding: &Array1<f32>) {
        if !self.config.enabled || embedding.len() != self.embedding_dim {
            return;
        }

        apply_ema(
            &mut self.session_positive_vector,
            embedding,
            self.config.session_alpha,
        );
        apply_ema(
            &mut self.long_term_positive_vector,
            embedding,
            self.config.long_term_alpha,
        );
        self.session_positive_updates += 1;
        self.long_term_positive_updates += 1;
        self.dirty_updates += 1;
        self.persist_if_needed(false);
    }

    pub fn apply_feedback(&mut self, positive: Option<&Array1<f32>>, negatives: &[Array1<f32>]) {
        if !self.config.enabled {
            return;
        }

        if let Some(positive) = positive {
            self.update_positive(positive);
        }

        if negatives.is_empty() {
            return;
        }

        if let Some(negative_centroid) = average_embeddings(negatives, self.embedding_dim) {
            apply_ema(
                &mut self.session_negative_vector,
                &negative_centroid,
                self.config.negative_session_alpha,
            );
            apply_ema(
                &mut self.long_term_negative_vector,
                &negative_centroid,
                self.config.negative_long_term_alpha,
            );
            self.session_negative_updates += 1;
            self.long_term_negative_updates += 1;
            self.dirty_updates += 1;
            self.persist_if_needed(false);
        }
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
                    "failed to read preference snapshot from {}: {}",
                    path.display(),
                    err
                );
                return;
            }
        };

        let value: Value = match serde_json::from_slice(&content) {
            Ok(value) => value,
            Err(err) => {
                warn!(
                    "failed to parse preference snapshot from {}: {}",
                    path.display(),
                    err
                );
                return;
            }
        };

        let version = value
            .get("version")
            .and_then(Value::as_u64)
            .unwrap_or(SNAPSHOT_VERSION_V1 as u64) as u32;

        match version {
            SNAPSHOT_VERSION_V1 => self.load_snapshot_v1(value, &path),
            SNAPSHOT_VERSION_V2 => self.load_snapshot_v2(value, &path),
            other => {
                warn!(
                    "ignored preference snapshot from {} due to unsupported version {}",
                    path.display(),
                    other
                );
            }
        }
    }

    fn load_snapshot_v1(&mut self, value: Value, path: &PathBuf) {
        let snapshot: PreferenceSnapshotV1 = match serde_json::from_value(value) {
            Ok(snapshot) => snapshot,
            Err(err) => {
                warn!(
                    "failed to decode v1 preference snapshot from {}: {}",
                    path.display(),
                    err
                );
                return;
            }
        };

        if snapshot.embedding_dim != self.embedding_dim
            || snapshot.vector.len() != self.embedding_dim
        {
            warn!(
                "ignored v1 preference snapshot from {} due to embedding size mismatch",
                path.display()
            );
            return;
        }

        self.long_term_positive_updates = snapshot.update_count;
        self.long_term_positive_vector = Some(Array1::from(snapshot.vector));
        self.dirty_updates = 0;
    }

    fn load_snapshot_v2(&mut self, value: Value, path: &PathBuf) {
        let snapshot: PreferenceSnapshotV2 = match serde_json::from_value(value) {
            Ok(snapshot) => snapshot,
            Err(err) => {
                warn!(
                    "failed to decode v2 preference snapshot from {}: {}",
                    path.display(),
                    err
                );
                return;
            }
        };

        if snapshot.embedding_dim != self.embedding_dim {
            warn!(
                "ignored v2 preference snapshot from {} due to embedding size mismatch",
                path.display()
            );
            return;
        }

        if !vector_matches_dim(&snapshot.positive_vector, self.embedding_dim)
            || !vector_matches_dim(&snapshot.negative_vector, self.embedding_dim)
        {
            warn!(
                "ignored v2 preference snapshot from {} due to vector length mismatch",
                path.display()
            );
            return;
        }

        self.long_term_positive_updates = snapshot.positive_update_count;
        self.long_term_positive_vector = vec_to_array(snapshot.positive_vector);
        self.long_term_negative_updates = snapshot.negative_update_count;
        self.long_term_negative_vector = vec_to_array(snapshot.negative_vector);
        self.dirty_updates = 0;
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
                    "failed to create preference snapshot directory {}: {}",
                    parent.display(),
                    err
                );
                return;
            }
        }

        let snapshot = PreferenceSnapshotV2 {
            version: SNAPSHOT_VERSION_V2,
            embedding_dim: self.embedding_dim,
            positive_update_count: self.long_term_positive_updates,
            negative_update_count: self.long_term_negative_updates,
            positive_vector: array_to_vec(self.long_term_positive_vector.as_ref()),
            negative_vector: array_to_vec(self.long_term_negative_vector.as_ref()),
        };

        match serde_json::to_vec(&snapshot) {
            Ok(serialized) => {
                if let Err(err) = fs::write(path, serialized) {
                    warn!(
                        "failed to persist preference snapshot to {}: {}",
                        path.display(),
                        err
                    );
                    return;
                }
                self.dirty_updates = 0;
            }
            Err(err) => {
                warn!(
                    "failed to serialize preference snapshot for {}: {}",
                    path.display(),
                    err
                );
            }
        }
    }
}

impl Drop for UserPreferenceStore {
    fn drop(&mut self) {
        self.persist_if_needed(true);
    }
}

fn weighted_preference_score(
    candidate: &Array1<f32>,
    candidate_norm: f32,
    session_weight: f32,
    session_updates: usize,
    session_vector: Option<&Array1<f32>>,
    long_term_weight: f32,
    long_term_updates: usize,
    long_term_vector: Option<&Array1<f32>>,
    min_long_term_updates: usize,
) -> f32 {
    let mut weighted_score = 0.0;
    let mut active_weight = 0.0;

    if session_updates > 0 && session_weight > EPSILON {
        if let Some(vector) = session_vector {
            if let Some(score) = cosine_similarity(candidate, candidate_norm, vector) {
                weighted_score += session_weight * score;
                active_weight += session_weight;
            }
        }
    }

    if long_term_updates >= min_long_term_updates && long_term_weight > EPSILON {
        if let Some(vector) = long_term_vector {
            if let Some(score) = cosine_similarity(candidate, candidate_norm, vector) {
                weighted_score += long_term_weight * score;
                active_weight += long_term_weight;
            }
        }
    }

    if active_weight <= EPSILON {
        return 0.0;
    }

    weighted_score / active_weight
}

fn apply_ema(slot: &mut Option<Array1<f32>>, source: &Array1<f32>, alpha: f32) {
    if alpha <= EPSILON {
        return;
    }

    if let Some(current) = slot.as_mut() {
        let keep = 1.0 - alpha;
        for (current_value, source_value) in current.iter_mut().zip(source.iter()) {
            *current_value = *current_value * keep + *source_value * alpha;
        }
    } else {
        *slot = Some(source.clone());
    }
}

fn cosine_similarity(
    candidate: &Array1<f32>,
    candidate_norm: f32,
    reference: &Array1<f32>,
) -> Option<f32> {
    let reference_norm = reference.dot(reference).sqrt();
    if candidate_norm <= EPSILON || reference_norm <= EPSILON {
        return None;
    }

    Some(candidate.dot(reference) / (candidate_norm * reference_norm))
}

fn average_embeddings(embeddings: &[Array1<f32>], embedding_dim: usize) -> Option<Array1<f32>> {
    if embeddings.is_empty() {
        return None;
    }

    let mut sum_embedding = Array1::zeros(embedding_dim);
    let mut count = 0usize;
    for embedding in embeddings {
        if embedding.len() != embedding_dim {
            continue;
        }
        sum_embedding += embedding;
        count += 1;
    }

    if count == 0 {
        return None;
    }

    Some(sum_embedding / count as f32)
}

fn vector_matches_dim(vector: &[f32], embedding_dim: usize) -> bool {
    vector.is_empty() || vector.len() == embedding_dim
}

fn vec_to_array(vector: Vec<f32>) -> Option<Array1<f32>> {
    if vector.is_empty() {
        None
    } else {
        Some(Array1::from(vector))
    }
}

fn array_to_vec(vector: Option<&Array1<f32>>) -> Vec<f32> {
    vector.map(Array1::to_vec).unwrap_or_default()
}
