use lmdb_zero as lmdb;
use lmdb_zero::{Database, Environment as LmdbEnv};
use ndarray::Array1;
use std::sync::Arc;
use thiserror::Error;
use tracing::{debug, info};

/// Simple LMDB embedding database manager
///
/// Focused on core functionality: reading vector dimensions and data

// ===== CORE DATA STRUCTURES =====

/// Simple metadata for embedding dimensions
#[derive(Debug, Clone, Copy)]
pub struct EmbeddingInfo {
    pub vocab_size: u32,
    pub embedding_dim: u32,
}

impl EmbeddingInfo {
    /// Parse metadata from raw bytes (expects 8-byte legacy format: [u32 vocab_size][u32 embedding_dim])
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, DatabaseError> {
        match bytes.len() {
            8 => {
                let vocab_size = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                let embedding_dim = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
                Ok(Self {
                    vocab_size,
                    embedding_dim,
                })
            }
            other => Err(DatabaseError::InvalidMetadataSize(other)),
        }
    }
}

// ===== ERROR TYPES =====

#[derive(Error, Debug)]
pub enum DatabaseError {
    #[error("LMDB path not found: {0}")]
    PathNotFound(String),
    #[error("LMDB environment error: {0}")]
    EnvironmentError(String),
    #[error("LMDB database error: {0}")]
    DatabaseError(String),
    #[error("Metadata not found in database")]
    MetadataNotFound,
    #[error("Invalid metadata size: {0} (expected 8 bytes)")]
    InvalidMetadataSize(usize),
    #[error("Metadata parse error: {0}")]
    MetadataParseError(String),
    #[error("Token {0} not found")]
    TokenNotFound(u32),
    #[error(
        "Invalid embedding size for token {token_id}: expected {expected} bytes, found {found}"
    )]
    InvalidEmbeddingSize {
        token_id: u32,
        expected: usize,
        found: usize,
    },
    #[error("Transaction error: {0}")]
    TransactionError(String),
    #[error("Unsupported quantization type: {0}")]
    UnsupportedQuantization(String),
    #[error("Tokenization error: {0}")]
    Tokenization(String),
    #[error("No tokens found")]
    NoTokensFound,
}

// ===== DATABASE MANAGER =====

/// Simple LMDB embedding database manager
pub struct LmdbManager {
    env: Arc<LmdbEnv>,
    db: Database<'static>,
    info: EmbeddingInfo,
    quantize_type: Option<String>,
}

impl LmdbManager {
    /// Open LMDB database and read embedding info
    pub fn open(db_path: &str, map_size_mb: usize, read_only: bool) -> Result<Self, DatabaseError> {
        info!("Attempting to open LMDB database at: {}", db_path);

        let path = std::path::Path::new(db_path);
        if !path.exists() {
            info!("LMDB path not found: {}", db_path);
            return Err(DatabaseError::PathNotFound(db_path.to_string()));
        }

        let flags = if read_only {
            lmdb::open::RDONLY
        } else {
            lmdb::open::Flags::empty()
        };
        let map_size = map_size_mb * 1024 * 1024;

        debug!(
            "LMDB environment flags: {:?}, map_size: {} bytes",
            flags, map_size
        );
        let env: Arc<LmdbEnv> = Arc::new(unsafe {
            let mut builder = lmdb::EnvBuilder::new()
                .map_err(|e| DatabaseError::EnvironmentError(e.to_string()))?;
            builder
                .set_maxdbs(1)
                .map_err(|e| DatabaseError::EnvironmentError(e.to_string()))?;
            builder
                .set_mapsize(map_size)
                .map_err(|e| DatabaseError::EnvironmentError(e.to_string()))?;
            builder
                .open(db_path, flags, 0o600)
                .map_err(|e| DatabaseError::EnvironmentError(e.to_string()))?
        });
        info!("LMDB environment opened successfully.");

        let db = lmdb::Database::open(env.clone(), None, &lmdb::DatabaseOptions::defaults())
            .map_err(|e| DatabaseError::DatabaseError(e.to_string()))?;
        info!("LMDB database opened successfully.");

        let info = Self::read_metadata(&env, &db)?;
        let quantize_type = Self::read_quantize_type(&env, &db)?;

        info!(
            "Database loaded - vocab_size: {}, embedding_dim: {}, quantize: {:?}",
            info.vocab_size, info.embedding_dim, quantize_type
        );

        Ok(Self {
            env,
            db,
            info,
            quantize_type,
        })
    }

    fn read_metadata(
        env: &Arc<LmdbEnv>,
        db: &Database<'static>,
    ) -> Result<EmbeddingInfo, DatabaseError> {
        debug!("Reading metadata from LMDB.");
        let txn = lmdb::ReadTransaction::new(env.clone())
            .map_err(|e| DatabaseError::TransactionError(e.to_string()))?;
        let access = txn.access();
        let meta_bytes: &[u8] = access
            .get(db, b"__meta__")
            .map_err(|_| DatabaseError::MetadataNotFound)?;
        let info = EmbeddingInfo::from_bytes(meta_bytes);
        debug!("Metadata read: {:?}", info);
        info
    }

    fn read_quantize_type(
        env: &Arc<LmdbEnv>,
        db: &Database<'static>,
    ) -> Result<Option<String>, DatabaseError> {
        debug!("Reading quantization type from LMDB.");
        let txn = lmdb::ReadTransaction::new(env.clone())
            .map_err(|e| DatabaseError::TransactionError(e.to_string()))?;
        let access = txn.access();
        match access.get::<_, [u8]>(db, b"__quantize__") {
            Ok(bytes) => {
                let q_type = String::from_utf8(bytes.to_vec()).map_err(|_| {
                    DatabaseError::MetadataParseError("Invalid quantize type".to_string())
                })?;
                debug!("Quantization type read: {}", q_type);
                Ok(Some(q_type))
            }
            Err(lmdb::Error::Code(lmdb::error::NOTFOUND)) => {
                debug!("No quantization type found.");
                Ok(None)
            }
            Err(e) => Err(DatabaseError::DatabaseError(e.to_string())),
        }
    }

    pub fn embedding_dim(&self) -> usize {
        self.info.embedding_dim as usize
    }

    pub fn get_token_embedding(&self, token_id: u32) -> Result<Array1<f32>, DatabaseError> {
        debug!("Attempting to get embedding for token ID: {}", token_id);
        let txn = lmdb::ReadTransaction::new(self.env.clone())
            .map_err(|e| DatabaseError::TransactionError(e.to_string()))?;
        let access = txn.access();
        let key_bytes = token_id.to_le_bytes();
        let value_bytes: &[u8] = access.get(&self.db, &key_bytes).map_err(|e| {
            debug!("Token ID {} not found in DB: {}", token_id, e);
            DatabaseError::TokenNotFound(token_id)
        })?;

        self.decode_embedding_bytes(token_id, value_bytes)
    }

    pub fn get_word_embedding(
        &self,
        word: &str,
        tokenizer: &tokenizers::Tokenizer,
    ) -> Result<Array1<f32>, DatabaseError> {
        debug!("Attempting to get embedding for word: '{}'", word);
        let encoding = tokenizer.encode(word, true).map_err(|e| {
            debug!("Tokenization error for word '{}': {}", word, e);
            DatabaseError::Tokenization(format!("Tokenization error: {}", e))
        })?;
        let token_ids: Vec<u32> = encoding.get_ids().iter().map(|&id| id).collect();

        if token_ids.is_empty() {
            debug!("No tokens found for word: '{}'", word);
            return Err(DatabaseError::NoTokensFound);
        }
        debug!("Tokens found for word '{}': {:?}", word, token_ids);

        let txn = lmdb::ReadTransaction::new(self.env.clone())
            .map_err(|e| DatabaseError::TransactionError(e.to_string()))?;
        let access = txn.access();

        let mut embeddings = Vec::with_capacity(token_ids.len());
        for &token_id in &token_ids {
            let key_bytes = token_id.to_le_bytes();
            let value_bytes: &[u8] = access.get(&self.db, &key_bytes).map_err(|e| {
                debug!(
                    "Token ID {} not found in DB for word '{}': {}",
                    token_id, word, e
                );
                DatabaseError::TokenNotFound(token_id)
            })?;
            embeddings.push(self.decode_embedding_bytes(token_id, value_bytes)?);
        }
        debug!(
            "Retrieved {} embeddings for word '{}'.",
            embeddings.len(),
            word
        );

        if embeddings.len() == 1 {
            debug!("Returning single embedding for word '{}'.", word);
            Ok(embeddings.into_iter().next().unwrap())
        } else {
            let mut sum_embedding = Array1::zeros(self.embedding_dim());
            for emb in &embeddings {
                sum_embedding += emb;
            }
            Ok(sum_embedding / embeddings.len() as f32)
        }
    }

    fn decode_embedding_bytes(
        &self,
        token_id: u32,
        value_bytes: &[u8],
    ) -> Result<Array1<f32>, DatabaseError> {
        if let Some(qtype) = &self.quantize_type {
            match qtype.as_str() {
                "int8" => {
                    let embedding_dim = self.embedding_dim();
                    let expected_len = embedding_dim + 4;
                    if value_bytes.len() != expected_len {
                        return Err(DatabaseError::InvalidEmbeddingSize {
                            token_id,
                            expected: expected_len,
                            found: value_bytes.len(),
                        });
                    }

                    let (quantized_bytes, scale_bytes) = value_bytes.split_at(embedding_dim);
                    let scale = f32::from_le_bytes(scale_bytes.try_into().unwrap());
                    let quantized_slice: &[i8] = bytemuck::cast_slice(quantized_bytes);

                    let dequantized_vec: Vec<f32> = quantized_slice
                        .iter()
                        .map(|&val| (val as f32 / 127.0) * scale)
                        .collect();

                    Ok(Array1::from(dequantized_vec))
                }
                "int4" => {
                    let embedding_dim = self.embedding_dim();
                    let packed_len = (embedding_dim + 1) / 2;
                    let expected_len = packed_len + 4;

                    if value_bytes.len() != expected_len {
                        return Err(DatabaseError::InvalidEmbeddingSize {
                            token_id,
                            expected: expected_len,
                            found: value_bytes.len(),
                        });
                    }

                    let (packed_bytes, scale_bytes) = value_bytes.split_at(packed_len);
                    let scale = f32::from_le_bytes(scale_bytes.try_into().unwrap());

                    let mut dequantized_vec: Vec<f32> = Vec::with_capacity(embedding_dim);
                    for &byte in packed_bytes {
                        let v1 = (byte >> 4) & 0x0F;
                        let v2 = byte & 0x0F;

                        let q1 = v1 as i8 - 8;
                        let q2 = v2 as i8 - 8;

                        dequantized_vec.push((q1 as f32 / 7.0) * scale);
                        if dequantized_vec.len() < embedding_dim {
                            dequantized_vec.push((q2 as f32 / 7.0) * scale);
                        }
                    }

                    Ok(Array1::from(dequantized_vec))
                }
                _ => Err(DatabaseError::UnsupportedQuantization(qtype.clone())),
            }
        } else {
            let expected_size = self.embedding_dim() * std::mem::size_of::<f32>();
            if value_bytes.len() != expected_size {
                return Err(DatabaseError::InvalidEmbeddingSize {
                    token_id,
                    expected: expected_size,
                    found: value_bytes.len(),
                });
            }

            let slice: &[f32] = bytemuck::cast_slice(value_bytes);
            Ok(Array1::from(slice.to_vec()))
        }
    }
}
