use std::collections::VecDeque;
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Instant;

const MAX_LOG_ENTRIES: usize = 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevel {
    pub fn label(&self) -> &'static str {
        match self {
            LogLevel::Debug => "DBG",
            LogLevel::Info => "INF",
            LogLevel::Warn => "WRN",
            LogLevel::Error => "ERR",
        }
    }
}

#[derive(Debug, Clone)]
pub struct LogEntry {
    pub level: LogLevel,
    pub message: String,
    pub elapsed_secs: f64,
}

#[derive(Clone)]
pub struct AppLog {
    entries: Arc<Mutex<VecDeque<LogEntry>>>,
    start_time: Instant,
    log_file: Arc<Mutex<Option<std::fs::File>>>,
    log_file_path: Arc<String>,
}

impl std::fmt::Debug for AppLog {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppLog")
            .field("entries_count", &self.entries.lock().unwrap().len())
            .field("log_file_path", &*self.log_file_path)
            .finish()
    }
}

impl AppLog {
    pub fn new() -> Self {
        let log_path = "emmc_gui.log".to_string();
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .ok();

        if let Some(ref f) = file {
            let mut f = f.try_clone().ok();
            if let Some(ref mut f) = f {
                let now = chrono_now();
                let _ = writeln!(f, "\n=== Session started {} ===", now);
            }
        }

        Self {
            entries: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_LOG_ENTRIES))),
            start_time: Instant::now(),
            log_file: Arc::new(Mutex::new(file)),
            log_file_path: Arc::new(log_path),
        }
    }

    pub fn log(&self, level: LogLevel, message: impl Into<String>) {
        let msg = message.into();
        let elapsed = self.start_time.elapsed().as_secs_f64();
        let entry = LogEntry {
            level,
            message: msg.clone(),
            elapsed_secs: elapsed,
        };

        // Write to file
        if let Ok(mut guard) = self.log_file.lock() {
            if let Some(ref mut f) = *guard {
                let now = chrono_now();
                let _ = writeln!(f, "[{}] [{:8.2}] [{}] {}", now, elapsed, level.label(), msg);
                let _ = f.flush();
            }
        }

        let mut entries = self.entries.lock().unwrap();
        if entries.len() >= MAX_LOG_ENTRIES {
            entries.pop_front();
        }
        entries.push_back(entry);
    }

    pub fn info(&self, message: impl Into<String>) {
        self.log(LogLevel::Info, message);
    }

    pub fn warn(&self, message: impl Into<String>) {
        self.log(LogLevel::Warn, message);
    }

    pub fn error(&self, message: impl Into<String>) {
        self.log(LogLevel::Error, message);
    }

    pub fn debug(&self, message: impl Into<String>) {
        self.log(LogLevel::Debug, message);
    }

    pub fn entries(&self) -> Vec<LogEntry> {
        self.entries.lock().unwrap().iter().cloned().collect()
    }

    pub fn len(&self) -> usize {
        self.entries.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.lock().unwrap().is_empty()
    }

    pub fn clear(&self) {
        self.entries.lock().unwrap().clear();
    }

    pub fn log_file_path(&self) -> &str {
        &self.log_file_path
    }

    pub fn save_to_file(&self, path: &str) -> std::io::Result<()> {
        let entries = self.entries.lock().unwrap();
        let mut f = std::fs::File::create(path)?;
        for entry in entries.iter() {
            writeln!(
                f,
                "[{:8.2}] [{}] {}",
                entry.elapsed_secs,
                entry.level.label(),
                entry.message
            )?;
        }
        Ok(())
    }
}

impl Default for AppLog {
    fn default() -> Self {
        Self::new()
    }
}

fn chrono_now() -> String {
    use std::time::SystemTime;
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let millis = now.subsec_millis();
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    format!("{:02}:{:02}:{:02}.{:03}", h, m, s, millis)
}
