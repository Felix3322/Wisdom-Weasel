use crate::general::{General, GeneralError};
use crate::lmdb_manager::DatabaseError;
use crate::lmdb_manager::LmdbManager;
use crate::model::Model;
use crate::preference::{PreferenceConfig, PreferenceScorer, UserPreferenceStore};
use crate::user_frequency::{UserFrequencyConfig, UserFrequencyScorer, UserFrequencyStore};
use ndarray::Array1;
use num_traits::FromPrimitive;
use onnxruntime::TypeToTensorElementDataType;
use ort::tensor::TensorDataToType;
use std::collections::{HashMap, VecDeque};
use std::marker::PhantomData;
use std::sync::Mutex;
use thiserror::Error;
use tracing::{debug, info};

const EPSILON: f32 = 1e-6;

#[derive(Error, Debug)]
pub enum PredictiveError {
    #[error("Model error: {0}")]
    Model(GeneralError),
    #[error("Database error: {0}")]
    Database(DatabaseError),
}

#[derive(Debug, Clone, Copy)]
pub struct PerformanceConfig {
    pub query_cache_capacity: usize,
    pub candidate_cache_capacity: usize,
}

#[derive(Debug, Clone, Copy)]
pub struct SemanticRefinementConfig {
    pub enabled: bool,
    pub encoder_candidate_blend_weight: f32,
    pub ambiguity_margin_threshold: f32,
    pub max_refine_candidates: usize,
}

impl SemanticRefinementConfig {
    fn sanitize(mut self) -> Self {
        self.encoder_candidate_blend_weight = self.encoder_candidate_blend_weight.clamp(0.0, 1.0);
        self.ambiguity_margin_threshold = self.ambiguity_margin_threshold.max(0.0);
        self
    }
}

#[derive(Debug, Clone)]
pub struct CandidateScoreBreakdown {
    pub candidate: String,
    pub semantic_score: f32,
    pub preference_score: f32,
    pub user_frequency_score: f32,
    pub final_score: f32,
    pub dynamic_preference_factor: f32,
}

#[derive(Clone)]
struct CachedEmbedding {
    vector: Array1<f32>,
    norm: f32,
}

impl CachedEmbedding {
    fn new(vector: Array1<f32>) -> Self {
        let norm = vector.dot(&vector).sqrt();
        Self { vector, norm }
    }

    fn cosine_similarity(&self, other: &Self) -> f32 {
        if self.norm <= EPSILON || other.norm <= EPSILON {
            return 0.0;
        }
        self.vector.dot(&other.vector) / (self.norm * other.norm)
    }
}

struct EmbeddingCache {
    capacity: usize,
    order: VecDeque<String>,
    entries: HashMap<String, CachedEmbedding>,
}

impl EmbeddingCache {
    fn new(capacity: usize) -> Self {
        Self {
            capacity,
            order: VecDeque::new(),
            entries: HashMap::new(),
        }
    }

    fn get(&self, key: &str) -> Option<CachedEmbedding> {
        self.entries.get(key).cloned()
    }

    fn insert(&mut self, key: String, value: CachedEmbedding) {
        if self.capacity == 0 {
            return;
        }
        if self.entries.contains_key(&key) {
            return;
        }

        self.order.push_back(key.clone());
        self.entries.insert(key, value);

        while self.entries.len() > self.capacity {
            if let Some(oldest_key) = self.order.pop_front() {
                self.entries.remove(&oldest_key);
            } else {
                break;
            }
        }
    }
}

pub struct PredictiveSimilarity<T> {
    model: Box<dyn Model<T, Error = GeneralError>>,
    lmdb: LmdbManager,
    query_cache: Mutex<EmbeddingCache>,
    candidate_cache: Mutex<EmbeddingCache>,
    encoder_candidate_cache: Mutex<EmbeddingCache>,
    preference: Mutex<UserPreferenceStore>,
    user_frequency: Mutex<UserFrequencyStore>,
    semantic_refinement: SemanticRefinementConfig,
    _phantom: PhantomData<T>,
}

impl<T> PredictiveSimilarity<T>
where
    T: TypeToTensorElementDataType + Clone + Into<f32> + TensorDataToType + FromPrimitive + 'static,
{
    pub fn new(
        model_path: &str,
        tokenizer_path: &str,
        lmdb_path: &str,
        optimization_level: i32,
        lmdb_map_size_mb: usize,
        lmdb_read_only: bool,
        max_input_length: usize,
        inference_hardware: &str,
        performance_config: PerformanceConfig,
        preference_config: PreferenceConfig,
        user_frequency_config: UserFrequencyConfig,
        semantic_refinement_config: SemanticRefinementConfig,
    ) -> Result<Self, PredictiveError> {
        info!(
            "Initializing PredictiveSimilarity with model_path: {}, tokenizer_path: {}, lmdb_path: {}",
            model_path, tokenizer_path, lmdb_path
        );
        let model = General::new(
            model_path,
            tokenizer_path,
            optimization_level,
            max_input_length,
            inference_hardware,
        )
        .map_err(PredictiveError::Model)?;
        info!("Model initialized successfully.");

        let lmdb_manager = LmdbManager::open(lmdb_path, lmdb_map_size_mb, lmdb_read_only)
            .map_err(PredictiveError::Database)?;
        info!("LMDB manager initialized successfully.");

        let embedding_dim = lmdb_manager.embedding_dim();
        let preference = UserPreferenceStore::load(preference_config, embedding_dim);
        let user_frequency = UserFrequencyStore::load(user_frequency_config);
        let semantic_refinement = semantic_refinement_config.sanitize();

        Ok(Self {
            model: Box::new(model),
            lmdb: lmdb_manager,
            query_cache: Mutex::new(EmbeddingCache::new(performance_config.query_cache_capacity)),
            candidate_cache: Mutex::new(EmbeddingCache::new(
                performance_config.candidate_cache_capacity,
            )),
            encoder_candidate_cache: Mutex::new(EmbeddingCache::new(
                performance_config.candidate_cache_capacity,
            )),
            preference: Mutex::new(preference),
            user_frequency: Mutex::new(user_frequency),
            semantic_refinement,
            _phantom: PhantomData,
        })
    }

    pub fn compute_similarities(
        &self,
        input: &str,
        candidates: &[String],
    ) -> Result<Vec<(String, f32)>, PredictiveError> {
        Ok(self
            .compute_score_breakdowns(input, candidates)?
            .into_iter()
            .map(|item| (item.candidate, item.final_score))
            .collect())
    }

    pub fn compute_score_breakdowns(
        &self,
        input: &str,
        candidates: &[String],
    ) -> Result<Vec<CandidateScoreBreakdown>, PredictiveError> {
        debug!(
            "Computing similarities for input: {} with {} candidates.",
            input,
            candidates.len()
        );

        let target = self.get_query_embedding(input)?;
        let preference_scorer = self.preference_scorer();
        let user_frequency_scorer = self.user_frequency_scorer();
        let mut candidate_infos = Vec::with_capacity(candidates.len());
        let mut semantic_scores = Vec::with_capacity(candidates.len());

        for candidate in candidates {
            let embedding = self.get_candidate_embedding(candidate)?;
            let semantic_score = embedding.cosine_similarity(&target);
            semantic_scores.push(semantic_score);
            candidate_infos.push((candidate.clone(), embedding, semantic_score));
        }

        self.refine_semantic_scores(input, candidates, &target, &mut semantic_scores)?;
        for (index, info) in candidate_infos.iter_mut().enumerate() {
            info.2 = semantic_scores[index];
        }

        let dynamic_preference_factor = preference_scorer.dynamic_weight_factor(&semantic_scores);

        let mut breakdowns = Vec::with_capacity(candidates.len());
        for (candidate, embedding, semantic_score) in candidate_infos {
            let preference_score = preference_scorer.score(
                &embedding.vector,
                embedding.norm,
                dynamic_preference_factor,
            );
            let user_frequency_score = user_frequency_scorer.score(&candidate);
            breakdowns.push(CandidateScoreBreakdown {
                candidate,
                semantic_score,
                preference_score,
                user_frequency_score,
                final_score: semantic_score + preference_score + user_frequency_score,
                dynamic_preference_factor,
            });
        }

        Ok(breakdowns)
    }

    pub fn warm_query(&self, input: &str) -> Result<(), PredictiveError> {
        if input.trim().is_empty() {
            return Ok(());
        }

        let _ = self.get_query_embedding(input)?;
        Ok(())
    }

    pub fn update_user_preference(&self, committed_text: &str) -> Result<(), PredictiveError> {
        self.apply_user_feedback(committed_text, &[])
    }

    pub fn apply_user_feedback(
        &self,
        committed_text: &str,
        negative_candidates: &[String],
    ) -> Result<(), PredictiveError> {
        let committed_text = committed_text.trim();
        let positive_embedding = if committed_text.is_empty() {
            None
        } else {
            Some(self.get_candidate_embedding(committed_text)?)
        };

        let mut negative_embeddings = Vec::with_capacity(negative_candidates.len());
        for negative_candidate in negative_candidates {
            let negative_candidate = negative_candidate.trim();
            if negative_candidate.is_empty() || negative_candidate == committed_text {
                continue;
            }
            let embedding = self.get_candidate_embedding(negative_candidate)?;
            negative_embeddings.push(embedding.vector);
        }

        if positive_embedding.is_none() && negative_embeddings.is_empty() {
            return Ok(());
        }

        let mut preference = self.preference.lock().unwrap();
        preference.apply_feedback(
            positive_embedding
                .as_ref()
                .map(|embedding| &embedding.vector),
            &negative_embeddings,
        );
        if !committed_text.is_empty() {
            let mut user_frequency = self.user_frequency.lock().unwrap();
            user_frequency.record_committed_text(committed_text);
        }
        Ok(())
    }

    fn preference_scorer(&self) -> PreferenceScorer {
        let preference = self.preference.lock().unwrap();
        preference.scorer()
    }

    fn user_frequency_scorer(&self) -> UserFrequencyScorer {
        let user_frequency = self.user_frequency.lock().unwrap();
        user_frequency.scorer()
    }

    fn get_query_embedding(&self, input: &str) -> Result<CachedEmbedding, PredictiveError> {
        if let Some(cached) = self.query_cache.lock().unwrap().get(input) {
            return Ok(cached);
        }

        let target_vec_t = self
            .model
            .get_predict_vector(input)
            .map_err(PredictiveError::Model)?;
        let target_vec: Array1<f32> = target_vec_t.row(0).mapv(|x| x.into());
        let cached = CachedEmbedding::new(target_vec);
        self.query_cache
            .lock()
            .unwrap()
            .insert(input.to_string(), cached.clone());
        Ok(cached)
    }

    fn get_candidate_embedding(&self, candidate: &str) -> Result<CachedEmbedding, PredictiveError> {
        if let Some(cached) = self.candidate_cache.lock().unwrap().get(candidate) {
            return Ok(cached);
        }

        let embedding = self
            .lmdb
            .get_word_embedding(candidate, self.model.tokenizer())
            .map_err(PredictiveError::Database)?;
        let cached = CachedEmbedding::new(embedding);
        self.candidate_cache
            .lock()
            .unwrap()
            .insert(candidate.to_string(), cached.clone());
        Ok(cached)
    }

    fn refine_semantic_scores(
        &self,
        input: &str,
        candidates: &[String],
        target: &CachedEmbedding,
        semantic_scores: &mut [f32],
    ) -> Result<(), PredictiveError> {
        if !self.should_refine_semantics(input, semantic_scores) {
            return Ok(());
        }

        let refine_limit = if self.semantic_refinement.max_refine_candidates == 0 {
            candidates.len()
        } else {
            candidates
                .len()
                .min(self.semantic_refinement.max_refine_candidates)
        };
        if refine_limit == 0 {
            return Ok(());
        }

        let mut ranked_indices = (0..candidates.len()).collect::<Vec<_>>();
        ranked_indices.sort_by(|&lhs, &rhs| {
            semantic_scores[rhs]
                .partial_cmp(&semantic_scores[lhs])
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| lhs.cmp(&rhs))
        });
        ranked_indices.truncate(refine_limit);

        let encoder_embeddings = self.get_encoder_candidate_embeddings(candidates, &ranked_indices)?;
        let blend_weight = self.semantic_refinement.encoder_candidate_blend_weight;
        if blend_weight <= EPSILON {
            return Ok(());
        }

        for (relative_index, &candidate_index) in ranked_indices.iter().enumerate() {
            let encoder_score = encoder_embeddings[relative_index].cosine_similarity(target);
            let base_score = semantic_scores[candidate_index];
            semantic_scores[candidate_index] =
                ((1.0 - blend_weight) * base_score) + (blend_weight * encoder_score);
        }

        Ok(())
    }

    fn should_refine_semantics(&self, input: &str, semantic_scores: &[f32]) -> bool {
        if !self.semantic_refinement.enabled
            || semantic_scores.len() <= 1
            || input.trim().is_empty()
            || self.semantic_refinement.encoder_candidate_blend_weight <= EPSILON
        {
            return false;
        }

        let mut top_score = f32::NEG_INFINITY;
        let mut second_score = f32::NEG_INFINITY;
        for &score in semantic_scores {
            if score > top_score {
                second_score = top_score;
                top_score = score;
            } else if score > second_score {
                second_score = score;
            }
        }

        if !top_score.is_finite() || !second_score.is_finite() {
            return false;
        }

        (top_score - second_score) <= self.semantic_refinement.ambiguity_margin_threshold
    }

    fn get_encoder_candidate_embeddings(
        &self,
        candidates: &[String],
        indices: &[usize],
    ) -> Result<Vec<CachedEmbedding>, PredictiveError> {
        let mut resolved = vec![None; indices.len()];
        let mut uncached_texts = Vec::new();
        let mut uncached_positions = Vec::new();

        {
            let cache = self.encoder_candidate_cache.lock().unwrap();
            for (position, &candidate_index) in indices.iter().enumerate() {
                let candidate = &candidates[candidate_index];
                if let Some(cached) = cache.get(candidate) {
                    resolved[position] = Some(cached);
                } else {
                    uncached_positions.push(position);
                    uncached_texts.push(candidate.as_str());
                }
            }
        }

        if !uncached_positions.is_empty() {
            let batch = self
                .model
                .get_predict_vectors(&uncached_texts)
                .map_err(PredictiveError::Model)?;

            let mut cache = self.encoder_candidate_cache.lock().unwrap();
            for (batch_index, &position) in uncached_positions.iter().enumerate() {
                let candidate = &candidates[indices[position]];
                let embedding = CachedEmbedding::new(batch.row(batch_index).mapv(|value| value.into()));
                cache.insert(candidate.clone(), embedding.clone());
                resolved[position] = Some(embedding);
            }
        }

        resolved
            .into_iter()
            .map(|item| item.ok_or(PredictiveError::Model(GeneralError::EmptySequence)))
            .collect()
    }
}
