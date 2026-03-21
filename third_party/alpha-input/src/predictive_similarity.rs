use ndarray::{Array1, Axis};
use crate::model::Model;
use crate::general::{General, GeneralError};
use crate::lmdb_manager::LmdbManager;
use std::marker::PhantomData;
use onnxruntime::TypeToTensorElementDataType;
use ort::tensor::TensorDataToType;
use num_traits::FromPrimitive;
use crate::lmdb_manager::DatabaseError;
use ndarray::ShapeError;
use thiserror::Error;
use tracing::{info, debug, instrument};

#[derive(Error, Debug)]
pub enum PredictiveError {
    #[error("Model error: {0}")]
    Model(GeneralError),
    #[error("Database error: {0}")]
    Database(DatabaseError),
    #[error("NDArray error: {0}")]
    NDArray(ShapeError),
}

pub struct PredictiveSimilarity<T> {
    model: Box<dyn Model<T, Error = GeneralError>>,
    lmdb: LmdbManager,
    _phantom: PhantomData<T>,
}

impl<T> PredictiveSimilarity<T>
where
    T: TypeToTensorElementDataType + Clone + Into<f32> + TensorDataToType + FromPrimitive + 'static,
{
    // Moved the new function out of nested impl
    pub fn new(
        model_path: &str,
        tokenizer_path: &str,
        lmdb_path: &str,
        optimization_level: i32,
        lmdb_map_size_mb: usize,
        lmdb_read_only: bool,
        max_input_length: usize,
        inference_hardware: &str,
    ) -> Result<Self, PredictiveError> {  // Changed error type to PredictiveError
        info!("Initializing PredictiveSimilarity with model_path: {}, tokenizer_path: {}, lmdb_path: {}", model_path, tokenizer_path, lmdb_path);
        let model = General::new(model_path, tokenizer_path, optimization_level, max_input_length, inference_hardware).map_err(PredictiveError::Model)?;
        info!("Model initialized successfully.");
        let lmdb_manager = LmdbManager::open(lmdb_path, lmdb_map_size_mb, lmdb_read_only).map_err(PredictiveError::Database)?;
        info!("LMDB manager initialized successfully.");

        Ok(Self {
            model: Box::new(model),
            lmdb: lmdb_manager,  // Fixed field name
            _phantom: PhantomData,
        })
    }

    #[instrument(skip(self, candidates), fields(input_text = input))]
    pub fn compute_similarities(
        &self,
        input: &str,
        candidates: &[String],
    ) -> Result<Vec<(String, f32)>, PredictiveError> {
        debug!("Computing similarities for input: {} with {} candidates.", input, candidates.len());
        let target_vec_t = self.model.get_predict_vector(input).map_err(PredictiveError::Model)?;
        let target_vec: Array1<f32> = target_vec_t.row(0).mapv(|x| x.into());
        let target_norm = target_vec.dot(&target_vec).sqrt();
        debug!("Target vector and norm computed.");

        let mut candidate_embs = Vec::with_capacity(candidates.len());
        for cand in candidates {
            debug!("Getting embedding for candidate: {}", cand);
            let emb = self.lmdb.get_word_embedding(cand, self.model.tokenizer()).map_err(PredictiveError::Database)?;
            candidate_embs.push(emb);
        }
        let stacked_embs = ndarray::stack(
            Axis(0),
            &candidate_embs.iter().map(|e| e.view()).collect::<Vec<_>>(),
        ).map_err(PredictiveError::NDArray)?;
        debug!("Candidate embeddings stacked.");

        let dots = stacked_embs.dot(&target_vec);
        debug!("Dot products computed.");

        let candidate_norms = stacked_embs.map_axis(Axis(1), |row| row.dot(&row).sqrt());
        debug!("Candidate norms computed.");

        let combined_norms = candidate_norms * target_norm;
        debug!("Combined norms computed.");

        let sims = dots / combined_norms;
        debug!("Similarities computed.");

        let mut similarities = Vec::with_capacity(candidates.len());
        for (i, cand) in candidates.iter().enumerate() {
            let sim = sims[i];
            similarities.push((cand.clone(), sim));
            debug!("Candidate: {}, Similarity: {}", cand, sim);
        }

        Ok(similarities)
    }
}
