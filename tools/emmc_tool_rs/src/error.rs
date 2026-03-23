use thiserror::Error;

#[derive(Debug, Error)]
#[allow(dead_code)]
pub enum ProtocolError {
    #[error("No response from FPGA (timeout)")]
    Timeout,
    #[error("Incomplete response header")]
    IncompleteHeader,
    #[error("Incomplete payload: got {got}/{expected}")]
    IncompletePayload { got: usize, expected: usize },
    #[error("Missing CRC byte")]
    MissingCrc,
    #[error("CRC mismatch: got 0x{got:02X}, expected 0x{expected:02X}")]
    CrcMismatch { got: u8, expected: u8 },
    #[error("Command failed: {0}")]
    BadStatus(String),
}
