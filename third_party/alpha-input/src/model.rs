use ndarray::Array2;
use tokenizers::Tokenizer;

/// Generic trait for text embedding models
///
/// This trait provides a common interface for different types of embedding models,
/// allowing for easy swapping between implementations (ONNX, PyTorch, etc.)
pub trait Model<T> {
    type Error: std::error::Error + 'static;

    /// Get embedding vectors for a batch of inputs
    ///
    /// # Arguments
    /// * `inputs` - The input texts to generate embeddings for
    ///
    /// # Returns
    /// A 2D array where the first dimension is batch size
    /// and the second dimension is the embedding dimension
    fn get_predict_vectors(&self, inputs: &[&str]) -> Result<Array2<T>, Self::Error>;

    /// Get embedding vector for input text
    ///
    /// # Arguments
    /// * `input` - The input text to generate embeddings for
    ///
    /// # Returns
    /// A 2D array where the first dimension is batch size (usually 1)
    /// and the second dimension is the embedding dimension
    fn get_predict_vector(&self, input: &str) -> Result<Array2<T>, Self::Error> {
        self.get_predict_vectors(&[input])
    }

    /// Get access to the tokenizer
    ///
    /// # Returns
    /// Reference to the tokenizer used by this model
    fn tokenizer(&self) -> &Tokenizer;
}
