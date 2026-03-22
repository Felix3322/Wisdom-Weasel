use crate::model::Model;
use ndarray::{Array, Array2, Axis, CowArray, s};
use num_traits::FromPrimitive;
use onnxruntime::TypeToTensorElementDataType;
use ort::{Environment, OrtError, Session, SessionBuilder, Value, tensor::TensorDataToType};
use std::marker::PhantomData;
use std::sync::Arc;
use thiserror::Error;
use tokenizers::Tokenizer;
use tracing::{debug, info, instrument, trace};

/// General model implementation using ONNX Runtime
pub struct General<T> {
    session: Session,
    tokenizer: Tokenizer,
    max_input_length: usize,
    _phantom: PhantomData<T>,
}

#[derive(Error, Debug)]
pub enum GeneralError {
    #[error("Tokenization error: {0}")]
    Tokenization(String),
    #[error("Empty sequence")]
    EmptySequence,
    #[error("Array creation error: {0}")]
    ArrayCreation(String),
    #[error("Value creation error: {0}")]
    ValueCreation(OrtError),
    #[error("Inference error: {0}")]
    Inference(OrtError),
    #[error("Tensor extraction error: {0}")]
    TensorExtraction(OrtError),
    #[error("Unexpected output shape: {0:?}")]
    UnexpectedShape(Vec<usize>),
    #[error("Reshape error: {0}")]
    Reshape(String),
    #[error("Model file does not exist: {0}")]
    ModelFileNotFound(String),
    #[error("Environment creation error: {0}")]
    EnvironmentCreation(OrtError),
    #[error("Session builder error: {0}")]
    SessionBuilder(OrtError),
    #[error("Model loading error: {0}")]
    ModelLoading(OrtError),
    #[error("Tokenizer file does not exist: {0}")]
    TokenizerFileNotFound(String),
    #[error("Tokenizer loading error: {0}")]
    TokenizerLoading(String),
    #[error("Invalid optimization level: {0}")]
    InvalidOptimizationLevel(i32),
    #[error("Input exceeds maximum length: {0} tokens (max: {1})")]
    InputTooLong(usize, usize),
}

impl<T: TypeToTensorElementDataType + Clone + TensorDataToType + FromPrimitive> Model<T>
    for General<T>
{
    type Error = GeneralError;
    #[instrument(skip(self), fields(input_text = input))]
    fn get_predict_vector(&self, input: &str) -> Result<Array2<T>, Self::Error> {
        debug!("Getting prediction vector for input: '{}'", input);
        // Prepare input
        let encoding = self.tokenizer.encode(input, true).map_err(|e| {
            debug!("Tokenization error for input '{}': {}", input, e);
            GeneralError::Tokenization(e.to_string())
        })?;
        trace!("Input tokenized. IDs: {:?}", encoding.get_ids());

        let token_count = encoding.get_ids().len();
        debug!(
            "Token count: {}. Max input length: {}.",
            token_count, self.max_input_length
        );
        if token_count > self.max_input_length {
            info!(
                "Input too long: {} tokens (max: {}).",
                token_count, self.max_input_length
            );
            return Err(GeneralError::InputTooLong(
                token_count,
                self.max_input_length,
            ));
        }

        let pad_token_id = self
            .tokenizer
            .get_padding()
            .map(|padding| padding.pad_id as i64)
            .unwrap_or(0);
        let mut input_ids: Vec<i64> = encoding.get_ids().iter().map(|&x| x as i64).collect();
        let mut attention_mask: Vec<i64> = encoding
            .get_attention_mask()
            .iter()
            .map(|&x| x as i64)
            .collect();

        let seq_length = attention_mask.iter().filter(|&&x| x == 1).count();
        debug!("Sequence length: {}.", seq_length);
        if seq_length == 0 {
            info!("Empty sequence after tokenization.");
            return Err(GeneralError::EmptySequence);
        }

        if input_ids.len() < self.max_input_length {
            input_ids.resize(self.max_input_length, pad_token_id);
        }
        if attention_mask.len() < self.max_input_length {
            attention_mask.resize(self.max_input_length, 0);
        }

        let input_ids_len = input_ids.len();
        let attention_mask_len = attention_mask.len();

        let input_ids_array = CowArray::from(
            Array::from_shape_vec((1, input_ids_len), input_ids)
                .map_err(|e| GeneralError::ArrayCreation(e.to_string()))?
                .into_dyn(),
        );
        let attention_mask_array = CowArray::from(
            Array::from_shape_vec((1, attention_mask_len), attention_mask)
                .map_err(|e| GeneralError::ArrayCreation(e.to_string()))?
                .into_dyn(),
        );
        let inputs = vec![
            Value::from_array(self.session.allocator(), &input_ids_array)
                .map_err(GeneralError::ValueCreation)?,
            Value::from_array(self.session.allocator(), &attention_mask_array)
                .map_err(GeneralError::ValueCreation)?,
        ];
        debug!("Input tensors created.");

        // Run inference and obtain a view of the output tensor without copying.
        debug!("Running ONNX inference...");
        let outputs = self.session.run(inputs).map_err(GeneralError::Inference)?;
        debug!("Inference completed.");
        let last_hidden_state = outputs[0]
            .try_extract::<f32>()
            .map_err(GeneralError::TensorExtraction)?;
        let last_hidden_state_view = last_hidden_state.view();
        trace!(
            "Last hidden state extracted. Shape: {:?}",
            last_hidden_state_view.shape()
        );

        // The shape is typically (batch_size, sequence_length, hidden_size).
        let shape = last_hidden_state_view.shape();
        debug!("Output tensor shape: {:?}", shape);
        if shape.len() != 3 || shape[0] == 0 || shape[2] == 0 {
            info!("Unexpected output shape: {:?}", shape);
            return Err(GeneralError::UnexpectedShape(shape.to_vec()));
        }

        let valid_seq_length = seq_length.min(shape[1]);
        if valid_seq_length == 0 {
            info!("Empty valid token span after masking.");
            return Err(GeneralError::EmptySequence);
        }
        if valid_seq_length != seq_length {
            debug!(
                "Clamped valid sequence length from {} to {} based on output shape.",
                seq_length, valid_seq_length
            );
        }

        let batch_hidden_state = last_hidden_state_view.index_axis(Axis(0), 0);
        let mean_pooled = batch_hidden_state
            .slice(s![0..valid_seq_length, ..])
            .mean_axis(Axis(0))
            .ok_or(GeneralError::EmptySequence)?;
        let mean_pooled_vec = mean_pooled
            .mapv(|val| T::from_f32(val).unwrap())
            .insert_axis(Axis(0));
        debug!(
            "Extracted mean pooled vector across {} tokens. Shape: {:?}",
            valid_seq_length,
            mean_pooled_vec.shape()
        );

        Ok(mean_pooled_vec)
    }

    fn tokenizer(&self) -> &Tokenizer {
        &self.tokenizer
    }
}

impl<T: TypeToTensorElementDataType + Clone + TensorDataToType + FromPrimitive> General<T> {
    #[instrument(skip_all, fields(model_path = model_path, tokenizer_path = tokenizer_path))]
    pub fn new(
        model_path: &str,
        tokenizer_path: &str,
        optimization_level: i32,
        max_input_length: usize,
        inference_hardware: &str,
    ) -> Result<Self, GeneralError> {
        info!(
            "Initializing General model with optimization_level: {}, max_input_length: {}, inference_hardware: {}",
            optimization_level, max_input_length, inference_hardware
        );
        let session = Self::load_session(model_path, optimization_level, inference_hardware)?;
        info!("ONNX Runtime session loaded.");
        let tokenizer = Self::load_tokenizer(tokenizer_path)?;
        info!("Tokenizer loaded.");

        Ok(Self {
            session,
            tokenizer,
            max_input_length,
            _phantom: PhantomData,
        })
    }

    // Helper to load ONNX session
    #[instrument(skip_all, fields(model_path = model_path))]
    fn load_session(
        model_path: &str,
        optimization_level: i32,
        _inference_hardware: &str,
    ) -> Result<Session, GeneralError> {
        info!("Loading model from: {}", model_path);
        if !std::path::Path::new(model_path).exists() {
            info!("Model file not found: {}", model_path);
            return Err(GeneralError::ModelFileNotFound(model_path.to_string()));
        }

        // Create ONNX Runtime environment and build a session
        debug!("Creating ONNX Runtime environment.");
        let environment = Arc::new(
            Environment::builder()
                .with_name("test")
                .build()
                .map_err(GeneralError::EnvironmentCreation)?,
        );
        debug!("Environment created. Building session...");
        let mut builder =
            SessionBuilder::new(&environment).map_err(GeneralError::SessionBuilder)?;
        let opt_level = match optimization_level {
            0 => ort::GraphOptimizationLevel::Disable,
            1 => ort::GraphOptimizationLevel::Level1,
            2 => ort::GraphOptimizationLevel::Level2,
            3 => ort::GraphOptimizationLevel::Level3,
            _ => {
                info!("Invalid optimization level: {}", optimization_level);
                return Err(GeneralError::InvalidOptimizationLevel(optimization_level));
            }
        };
        debug!("Setting optimization level to: {:?}", opt_level);
        builder = builder
            .with_optimization_level(opt_level)
            .map_err(GeneralError::SessionBuilder)?;

        #[cfg(feature = "cuda")]
        if inference_hardware == "cuda" {
            builder = builder
                .with_execution_providers(vec![
                    ort::execution_providers::CUDAExecutionProvider::default(),
                ])
                .map_err(GeneralError::SessionBuilder)?;
        }

        let session = builder
            .with_model_from_file(model_path)
            .map_err(GeneralError::ModelLoading)?;
        debug!("Model loaded into session.");

        // Print model input names for debugging
        for input in session.inputs.iter() {
            debug!("Model input name: {:?}", input.name);
        }
        info!("Session loaded successfully.");
        Ok(session)
    }

    // Helper to load tokenizer
    #[instrument(skip_all, fields(tokenizer_path = tokenizer_path))]
    fn load_tokenizer(tokenizer_path: &str) -> Result<Tokenizer, GeneralError> {
        info!("Loading tokenizer from: {}", tokenizer_path);
        if !std::path::Path::new(tokenizer_path).exists() {
            info!("Tokenizer file not found: {}", tokenizer_path);
            return Err(GeneralError::TokenizerFileNotFound(
                tokenizer_path.to_string(),
            ));
        }
        let tokenizer = Tokenizer::from_file(tokenizer_path).map_err(|e| {
            info!("Tokenizer loading error: {}", e);
            GeneralError::TokenizerLoading(e.to_string())
        })?;
        info!("Tokenizer loaded successfully.");
        Ok(tokenizer)
    }
}
