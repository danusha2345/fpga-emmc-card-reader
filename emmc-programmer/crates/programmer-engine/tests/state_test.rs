use programmer_engine::command::Command;
use programmer_engine::image::ImageBuffer;
use programmer_engine::state::{AppState, OperationStatus, SpeedProfile};
use std::path::PathBuf;

#[test]
fn state_defaults() {
    let state = AppState::new();
    assert!(!state.connected);
    assert!(!state.is_busy());
    assert!(state.chip_info.is_none());
    assert!(state.ext_csd_raw.is_none());
    assert!(state.hex_data.is_empty());
    assert!(state.partition_data.is_none());
    assert!(!state.partition_read_pending);
    assert_eq!(state.speed_profile, SpeedProfile::Safe);
    assert_eq!(state.selected_baud, 3_000_000);
    assert_eq!(state.current_baud, 3_000_000);
}

#[test]
fn speed_profiles() {
    assert_eq!(SpeedProfile::Safe.baud_preset(), 0);
    assert_eq!(SpeedProfile::Safe.clk_preset(), 0);
    assert_eq!(SpeedProfile::Safe.target_baud(), 3_000_000);

    assert_eq!(SpeedProfile::Medium.baud_preset(), 1);
    assert_eq!(SpeedProfile::Medium.clk_preset(), 2);
    assert_eq!(SpeedProfile::Medium.target_baud(), 6_000_000);

    assert_eq!(SpeedProfile::Fast.baud_preset(), 3);
    assert_eq!(SpeedProfile::Fast.clk_preset(), 3);
    assert_eq!(SpeedProfile::Fast.target_baud(), 12_000_000);
}

#[test]
fn operation_status_transitions() {
    let mut state = AppState::new();

    // Idle → Running
    state.set_running("Reading...");
    assert!(state.is_busy());
    assert!(matches!(state.operation_status, OperationStatus::Running(_)));

    // Running → Completed
    state.set_completed("Done");
    assert!(!state.is_busy());
    assert!(matches!(
        state.operation_status,
        OperationStatus::Completed(_)
    ));

    // → Failed
    state.set_running("Writing...");
    state.set_failed("CRC error");
    assert!(!state.is_busy());
    assert!(matches!(state.operation_status, OperationStatus::Failed(_)));
}

#[test]
fn cancel_flag() {
    let state = AppState::new();
    assert!(!state.cancel_flag.load(std::sync::atomic::Ordering::Relaxed));
    state.cancel_operation();
    assert!(state.cancel_flag.load(std::sync::atomic::Ordering::Relaxed));

    // set_running resets cancel flag
    let mut state2 = AppState::new();
    state2.cancel_operation();
    state2.set_running("test");
    assert!(!state2.cancel_flag.load(std::sync::atomic::Ordering::Relaxed));
}

#[test]
fn hex_edit_apply() {
    let mut state = AppState::new();
    state.hex_data = vec![0x00, 0x11, 0x22, 0x33];

    state.hex_apply_edit(1, 0xFF);
    assert_eq!(state.hex_data[1], 0xFF);
    assert!(state.hex_modified.contains(&1));
    assert_eq!(state.hex_undo_stack.len(), 1);
    assert!(state.hex_redo_stack.is_empty());
}

#[test]
fn hex_edit_no_change() {
    let mut state = AppState::new();
    state.hex_data = vec![0x42];
    state.hex_apply_edit(0, 0x42); // same value
    assert!(state.hex_undo_stack.is_empty()); // no edit recorded
}

#[test]
fn hex_undo_redo() {
    let mut state = AppState::new();
    state.hex_data = vec![0xAA, 0xBB, 0xCC];

    // Edit byte 0
    state.hex_apply_edit(0, 0x11);
    assert_eq!(state.hex_data[0], 0x11);

    // Undo
    state.hex_undo();
    assert_eq!(state.hex_data[0], 0xAA);
    assert_eq!(state.hex_undo_stack.len(), 0);
    assert_eq!(state.hex_redo_stack.len(), 1);

    // Redo
    state.hex_redo();
    assert_eq!(state.hex_data[0], 0x11);
    assert_eq!(state.hex_undo_stack.len(), 1);
    assert_eq!(state.hex_redo_stack.len(), 0);

    // Edit clears redo stack
    state.hex_undo();
    state.hex_apply_edit(0, 0x22); // new edit
    assert!(state.hex_redo_stack.is_empty()); // redo cleared
}

#[test]
fn hex_undo_empty() {
    let mut state = AppState::new();
    state.hex_data = vec![0x00];
    state.hex_undo(); // should not panic
    state.hex_redo(); // should not panic
}

#[test]
fn hex_edit_out_of_bounds() {
    let mut state = AppState::new();
    state.hex_data = vec![0x00];
    state.hex_apply_edit(100, 0xFF); // out of bounds
    assert!(state.hex_undo_stack.is_empty());
    assert_eq!(state.hex_data, vec![0x00]); // unchanged
}

#[test]
fn command_labels() {
    assert_eq!(Command::Identify.label(), "Identify");
    assert_eq!(
        Command::ReadSectors {
            lba: 0,
            count: 1,
            path: None
        }
        .label(),
        "Read Sectors"
    );
    assert_eq!(
        Command::Erase {
            lba: 0,
            count: 100
        }
        .label(),
        "Erase"
    );
}

#[test]
fn command_destructive() {
    assert!(!Command::Identify.is_destructive());
    assert!(
        !Command::ReadSectors {
            lba: 0,
            count: 1,
            path: None
        }
        .is_destructive()
    );
    assert!(!Command::ReadExtCsd.is_destructive());

    assert!(
        Command::WriteSectors {
            lba: 0,
            path: PathBuf::from("test"),
            verify: false
        }
        .is_destructive()
    );
    assert!(
        Command::Erase {
            lba: 0,
            count: 100
        }
        .is_destructive()
    );
    assert!(
        Command::RestoreFull {
            path: PathBuf::from("test"),
            verify: false
        }
        .is_destructive()
    );
    assert!(
        Command::HexWriteBack {
            lba: 0,
            data: vec![]
        }
        .is_destructive()
    );
}

#[test]
fn command_confirm_messages() {
    assert!(Command::Identify.confirm_message().is_none());
    assert!(
        Command::ReadSectors {
            lba: 0,
            count: 1,
            path: None
        }
        .confirm_message()
        .is_none()
    );

    let msg = Command::Erase {
        lba: 100,
        count: 50,
    }
    .confirm_message();
    assert!(msg.is_some());
    let msg = msg.unwrap();
    assert!(msg.contains("50"));
    assert!(msg.contains("100"));

    let msg = Command::HexWriteBack {
        lba: 42,
        data: vec![0; 512],
    }
    .confirm_message()
    .unwrap();
    assert!(msg.contains("512"));
    assert!(msg.contains("42"));
}

#[test]
fn image_buffer_diff_identical() {
    let a = ImageBuffer {
        data: vec![0u8; 1024],
        path: None,
    };
    let b = ImageBuffer {
        data: vec![0u8; 1024],
        path: None,
    };
    assert!(a.diff(&b).is_empty());
}

#[test]
fn image_buffer_diff_one_sector() {
    let a = ImageBuffer {
        data: vec![0u8; 1024],
        path: None,
    };
    let mut b_data = vec![0u8; 1024];
    b_data[0] = 0xFF;
    let b = ImageBuffer {
        data: b_data,
        path: None,
    };
    let diffs = a.diff(&b);
    assert_eq!(diffs.len(), 1);
    assert_eq!(diffs[0].sector_lba, 0);
}

#[test]
fn image_buffer_diff_different_sizes() {
    let a = ImageBuffer {
        data: vec![0u8; 512],
        path: None,
    };
    let b = ImageBuffer {
        data: vec![0u8; 1024],
        path: None,
    };
    let diffs = a.diff(&b);
    // Second sector exists only in b → diff
    assert_eq!(diffs.len(), 1);
    assert_eq!(diffs[0].sector_lba, 1);
}

#[test]
fn image_buffer_sector_count() {
    let buf = ImageBuffer {
        data: vec![0u8; 1000],
        path: None,
    };
    assert_eq!(buf.sector_count(), 2); // 1000 / 512 = 1.95 → 2
}

#[test]
fn image_buffer_empty() {
    let a = ImageBuffer {
        data: vec![],
        path: None,
    };
    let b = ImageBuffer {
        data: vec![],
        path: None,
    };
    assert!(a.diff(&b).is_empty());
    assert_eq!(a.sector_count(), 0);
}
