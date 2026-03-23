use thiserror::Error;

#[derive(Error, Debug)]
pub enum ProgrammerError {
    #[error("Connection error: {0}")]
    Connection(String),
    #[error("Communication error: {0}")]
    Communication(String),
    #[error("Chip not found")]
    ChipNotFound,
    #[error("Verify failed: {count} mismatch(es)")]
    VerifyFailed { count: usize },
    #[error("Operation cancelled")]
    Cancelled,
    #[error("Unsupported operation: {0}")]
    Unsupported(String),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

pub type Result<T> = std::result::Result<T, ProgrammerError>;
