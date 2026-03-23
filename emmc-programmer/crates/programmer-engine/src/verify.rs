use programmer_hal::traits::{BlankCheckResult, VerifyResult};

pub fn format_verify_result(result: &VerifyResult) -> String {
    if result.is_ok() {
        format!(
            "Verify OK: {} bytes match",
            result.total_bytes
        )
    } else {
        let first_few: Vec<String> = result
            .mismatches
            .iter()
            .take(10)
            .map(|m| {
                format!(
                    "  0x{:08X}: expected 0x{:02X}, got 0x{:02X}",
                    m.offset, m.expected, m.actual
                )
            })
            .collect();
        let mut msg = format!(
            "Verify FAILED: {} mismatch(es) in {} bytes\n",
            result.mismatches.len(),
            result.total_bytes
        );
        msg.push_str(&first_few.join("\n"));
        if result.mismatches.len() > 10 {
            msg.push_str(&format!(
                "\n  ... and {} more",
                result.mismatches.len() - 10
            ));
        }
        msg
    }
}

pub fn format_blank_check_result(result: &BlankCheckResult) -> String {
    if result.is_blank {
        format!("Blank check OK: {} bytes are blank", result.total_bytes)
    } else {
        format!(
            "NOT blank: first non-blank byte at offset 0x{:08X}",
            result.first_non_blank.unwrap_or(0)
        )
    }
}
