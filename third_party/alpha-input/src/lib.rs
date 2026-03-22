pub mod general;
pub mod lmdb_manager;
pub mod model;
pub mod predictive_similarity;
pub mod preference;

use config::Config;
use predictive_similarity::{PerformanceConfig, PredictiveError};
use preference::PreferenceConfig;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_float, c_int};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::Once;
use thiserror::Error;
use tracing::{Level, info};
use tracing_subscriber::FmtSubscriber;

#[derive(Error, Debug)]
pub enum AlphaError {
    #[error("Predictive error: {0}")]
    Predictive(PredictiveError),
    #[error("IO error: {0}")]
    Io(std::io::Error),
    #[error("Config error: {0}")]
    Config(config::ConfigError),
}

impl From<PredictiveError> for AlphaError {
    fn from(err: PredictiveError) -> Self {
        AlphaError::Predictive(err)
    }
}

impl From<std::io::Error> for AlphaError {
    fn from(err: std::io::Error) -> Self {
        AlphaError::Io(err)
    }
}

impl From<config::ConfigError> for AlphaError {
    fn from(err: config::ConfigError) -> Self {
        AlphaError::Config(err)
    }
}

pub struct AlphaPredictive {
    predictive: predictive_similarity::PredictiveSimilarity<i8>,
}

impl Drop for AlphaPredictive {
    fn drop(&mut self) {
        info!("AlphaPredictive instance dropped.");
    }
}

impl AlphaPredictive {
    pub fn new(config_path: &str) -> Result<Self, AlphaError> {
        initialize_tracing();

        info!("Application started.");
        info!("Loading configuration...");
        let config = Config::builder()
            .add_source(config::File::with_name(config_path))
            .build()
            .map_err(AlphaError::Config)?;
        info!("Configuration loaded successfully.");

        let model_path = config
            .get_string("model.path")
            .map_err(AlphaError::Config)?;
        let tokenizer_path = config
            .get_string("model.tokenizer")
            .map_err(AlphaError::Config)?;
        let lmdb_path = config
            .get_string("database.path")
            .map_err(AlphaError::Config)?;

        let optimization_level = config
            .get_int("model.optimization_level")
            .map_err(AlphaError::Config)? as i32;
        let max_input_length = config
            .get_int("model.max_input_length")
            .map_err(AlphaError::Config)? as usize;
        let inference_hardware = config
            .get_string("model.inference_hardware")
            .map_err(AlphaError::Config)?;
        let lmdb_map_size_mb = config
            .get_int("database.map_size_mb")
            .map_err(AlphaError::Config)? as usize;
        let lmdb_read_only = config
            .get_bool("database.read_only")
            .map_err(AlphaError::Config)?;

        let performance_config = PerformanceConfig {
            query_cache_capacity: config
                .get_int("performance.query_cache_capacity")
                .unwrap_or(128) as usize,
            candidate_cache_capacity: config
                .get_int("performance.candidate_cache_capacity")
                .unwrap_or(4096) as usize,
        };

        let preference_path = config
            .get_string("preference.persistence_path")
            .unwrap_or_else(|_| "user_preference.json".to_string());
        let preference_config = PreferenceConfig {
            enabled: config.get_bool("preference.enabled").unwrap_or(true),
            persistence_path: resolve_optional_path(config_path, &preference_path),
            blend_weight: config.get_float("preference.blend_weight").unwrap_or(0.12) as f32,
            negative_weight: config
                .get_float("preference.negative_weight")
                .unwrap_or(0.06) as f32,
            session_weight: config
                .get_float("preference.session_weight")
                .unwrap_or(0.45) as f32,
            long_term_weight: config
                .get_float("preference.long_term_weight")
                .unwrap_or(0.55) as f32,
            session_alpha: config.get_float("preference.session_alpha").unwrap_or(0.25) as f32,
            long_term_alpha: config
                .get_float("preference.long_term_alpha")
                .unwrap_or(0.08) as f32,
            negative_session_alpha: config
                .get_float("preference.negative_session_alpha")
                .unwrap_or(0.16) as f32,
            negative_long_term_alpha: config
                .get_float("preference.negative_long_term_alpha")
                .unwrap_or(0.05) as f32,
            min_long_term_updates: config
                .get_int("preference.min_long_term_updates")
                .unwrap_or(3) as usize,
            save_every_updates: config.get_int("preference.save_every_updates").unwrap_or(8)
                as usize,
        };

        info!("Initializing predictive similarity model...");
        let predictive = predictive_similarity::PredictiveSimilarity::<i8>::new(
            &model_path,
            &tokenizer_path,
            &lmdb_path,
            optimization_level,
            lmdb_map_size_mb,
            lmdb_read_only,
            max_input_length,
            &inference_hardware,
            performance_config,
            preference_config,
        )
        .map_err(AlphaError::Predictive)?;
        info!("Predictive similarity model initialized.");

        Ok(Self { predictive })
    }

    pub fn compute_similarities(
        &self,
        input: &str,
        candidates: &[String],
    ) -> Result<Vec<(String, f32)>, AlphaError> {
        let similarities = self
            .predictive
            .compute_similarities(input, candidates)
            .map_err(AlphaError::Predictive)?;
        Ok(similarities)
    }

    pub fn update_user_preference(&self, committed_text: &str) -> Result<(), AlphaError> {
        self.predictive
            .update_user_preference(committed_text)
            .map_err(AlphaError::Predictive)
    }

    pub fn apply_user_feedback(
        &self,
        committed_text: &str,
        negative_candidates: &[String],
    ) -> Result<(), AlphaError> {
        self.predictive
            .apply_user_feedback(committed_text, negative_candidates)
            .map_err(AlphaError::Predictive)
    }
}

#[allow(improper_ctypes_definitions)]
#[unsafe(no_mangle)]
pub extern "C" fn alpha_predictive_new(config_path: *const c_char) -> *mut AlphaPredictive {
    unsafe {
        let config_path = CStr::from_ptr(config_path)
            .to_str()
            .expect("Invalid UTF-8 string");

        match AlphaPredictive::new(config_path) {
            Ok(predictive) => Box::into_raw(Box::new(predictive)),
            Err(e) => {
                eprintln!("Error initializing AlphaPredictive: {:?}", e);
                ptr::null_mut()
            }
        }
    }
}

#[allow(improper_ctypes_definitions)]
#[unsafe(no_mangle)]
pub extern "C" fn alpha_predictive_free(predictive: *mut AlphaPredictive) {
    unsafe {
        if predictive.is_null() {
            return;
        }
        let _ = Box::from_raw(predictive);
    }
}

#[repr(C)]
pub struct SimilarityResult {
    word: *mut c_char,
    score: c_float,
}

#[allow(improper_ctypes_definitions)]
#[unsafe(no_mangle)]
pub extern "C" fn alpha_predictive_compute_similarities(
    predictive: *mut AlphaPredictive,
    input: *const c_char,
    candidates: *const *const c_char,
    num_candidates: c_int,
    results: *mut *mut SimilarityResult,
) -> c_int {
    unsafe {
        let predictive = &*predictive;
        let input = CStr::from_ptr(input)
            .to_str()
            .expect("Invalid UTF-8 string");

        let mut rust_candidates = Vec::new();
        for i in 0..num_candidates {
            let c_str_ptr = *candidates.offset(i as isize);
            let candidate = CStr::from_ptr(c_str_ptr)
                .to_str()
                .expect("Invalid UTF-8 string");
            rust_candidates.push(candidate.to_string());
        }

        match predictive.compute_similarities(input, &rust_candidates) {
            Ok(mut sims) => {
                sims.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());

                let mut c_results: Vec<SimilarityResult> = Vec::with_capacity(sims.len());
                for (word, score) in sims {
                    let c_word = CString::new(word).unwrap().into_raw();
                    c_results.push(SimilarityResult {
                        word: c_word,
                        score,
                    });
                }

                let boxed_results = c_results.into_boxed_slice();
                let len = boxed_results.len();
                *results = Box::into_raw(boxed_results) as *mut SimilarityResult;
                len as c_int
            }
            Err(e) => {
                eprintln!("Error computing similarities: {:?}", e);
                -1
            }
        }
    }
}

#[allow(improper_ctypes_definitions)]
#[unsafe(no_mangle)]
pub extern "C" fn alpha_predictive_compute_similarities_ordered(
    predictive: *mut AlphaPredictive,
    input: *const c_char,
    candidates: *const *const c_char,
    num_candidates: c_int,
    results: *mut *mut SimilarityResult,
) -> c_int {
    unsafe {
        let predictive = &*predictive;
        let input = CStr::from_ptr(input)
            .to_str()
            .expect("Invalid UTF-8 string");

        let mut rust_candidates = Vec::new();
        for i in 0..num_candidates {
            let c_str_ptr = *candidates.offset(i as isize);
            let candidate = CStr::from_ptr(c_str_ptr)
                .to_str()
                .expect("Invalid UTF-8 string");
            rust_candidates.push(candidate.to_string());
        }

        match predictive.compute_similarities(input, &rust_candidates) {
            Ok(sims) => {
                let mut c_results: Vec<SimilarityResult> = Vec::with_capacity(sims.len());
                for (word, score) in sims {
                    let c_word = CString::new(word).unwrap().into_raw();
                    c_results.push(SimilarityResult {
                        word: c_word,
                        score,
                    });
                }

                let boxed_results = c_results.into_boxed_slice();
                let len = boxed_results.len();
                *results = Box::into_raw(boxed_results) as *mut SimilarityResult;
                len as c_int
            }
            Err(e) => {
                eprintln!("Error computing ordered similarities: {:?}", e);
                -1
            }
        }
    }
}

#[allow(improper_ctypes_definitions)]
#[unsafe(no_mangle)]
pub extern "C" fn alpha_predictive_update_user_preference(
    predictive: *mut AlphaPredictive,
    committed_text: *const c_char,
) -> c_int {
    unsafe {
        let predictive = &*predictive;
        let committed_text = CStr::from_ptr(committed_text)
            .to_str()
            .expect("Invalid UTF-8 string");

        match predictive.update_user_preference(committed_text) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("Error updating user preference: {:?}", e);
                -1
            }
        }
    }
}

#[allow(improper_ctypes_definitions)]
#[unsafe(no_mangle)]
pub extern "C" fn alpha_predictive_apply_user_feedback(
    predictive: *mut AlphaPredictive,
    committed_text: *const c_char,
    negative_candidates: *const *const c_char,
    num_negative_candidates: c_int,
) -> c_int {
    unsafe {
        let predictive = &*predictive;
        let committed_text = CStr::from_ptr(committed_text)
            .to_str()
            .expect("Invalid UTF-8 string");

        let mut rust_negative_candidates = Vec::new();
        if !negative_candidates.is_null() && num_negative_candidates > 0 {
            for i in 0..num_negative_candidates {
                let c_str_ptr = *negative_candidates.offset(i as isize);
                let candidate = CStr::from_ptr(c_str_ptr)
                    .to_str()
                    .expect("Invalid UTF-8 string");
                rust_negative_candidates.push(candidate.to_string());
            }
        }

        match predictive.apply_user_feedback(committed_text, &rust_negative_candidates) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("Error applying user feedback: {:?}", e);
                -1
            }
        }
    }
}

#[allow(improper_ctypes_definitions)]
#[unsafe(no_mangle)]
pub extern "C" fn alpha_predictive_free_similarities_result(
    results: *mut SimilarityResult,
    len: c_int,
) {
    unsafe {
        if results.is_null() {
            return;
        }
        let slice = Box::from_raw(std::slice::from_raw_parts_mut(results, len as usize));
        for result in slice.into_vec() {
            let _ = CString::from_raw(result.word);
        }
    }
}

static TRACING_INIT: Once = Once::new();

fn initialize_tracing() {
    TRACING_INIT.call_once(|| {
        let subscriber = FmtSubscriber::builder()
            .with_max_level(default_tracing_level())
            .with_ansi(false)
            .finish();
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}

fn default_tracing_level() -> Level {
    match std::env::var("ALPHA_INPUT_LOG_LEVEL")
        .unwrap_or_else(|_| "warn".to_string())
        .to_ascii_lowercase()
        .as_str()
    {
        "trace" => Level::TRACE,
        "debug" => Level::DEBUG,
        "info" => Level::INFO,
        "error" => Level::ERROR,
        _ => Level::WARN,
    }
}

fn resolve_optional_path(config_path: &str, raw_path: &str) -> Option<PathBuf> {
    let trimmed = raw_path.trim();
    if trimmed.is_empty() {
        return None;
    }

    let path = PathBuf::from(trimmed);
    if path.is_absolute() {
        return Some(path);
    }

    let base_dir = Path::new(config_path)
        .parent()
        .unwrap_or_else(|| Path::new("."));
    Some(base_dir.join(path))
}
