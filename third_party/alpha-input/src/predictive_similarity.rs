use crate::general::{General, GeneralError};
use crate::lmdb_manager::DatabaseError;
use crate::lmdb_manager::LmdbManager;
use crate::model::Model;
use crate::preference::{PreferenceConfig, PreferenceScorer, UserPreferenceStore};
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
    preference: Mutex<UserPreferenceStore>,
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

        Ok(Self {
            model: Box::new(model),
            lmdb: lmdb_manager,
            query_cache: Mutex::new(EmbeddingCache::new(performance_config.query_cache_capacity)),
            candidate_cache: Mutex::new(EmbeddingCache::new(
                performance_config.candidate_cache_capacity,
            )),
            preference: Mutex::new(preference),
            _phantom: PhantomData,
        })
    }

    pub fn compute_similarities(
        &self,
        input: &str,
        candidates: &[String],
    ) -> Result<Vec<(String, f32)>, PredictiveError> {
        debug!(
            "Computing similarities for input: {} with {} candidates.",
            input,
            candidates.len()
        );

        let target = self.get_query_embedding(input)?;
        let preference_scorer = self.preference_scorer();
        let mut candidate_infos = Vec::with_capacity(candidates.len());
        let mut semantic_scores = Vec::with_capacity(candidates.len());

        for candidate in candidates {
            let embedding = self.get_candidate_embedding(candidate)?;
            let semantic_score = embedding.cosine_similarity(&target);
            semantic_scores.push(semantic_score);
            candidate_infos.push((candidate.clone(), embedding, semantic_score));
        }

        let dynamic_preference_factor = preference_scorer.dynamic_weight_factor(&semantic_scores);

        let mut similarities = Vec::with_capacity(candidates.len());
        for (candidate, embedding, semantic_score) in candidate_infos {
            let preference_score = preference_scorer.score(
                &embedding.vector,
                embedding.norm,
                dynamic_preference_factor,
            );
            similarities.push((candidate, semantic_score + preference_score));
        }

        Ok(similarities)
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
        Ok(())
    }

    fn preference_scorer(&self) -> PreferenceScorer {
        let preference = self.preference.lock().unwrap();
        preference.scorer()
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
}
