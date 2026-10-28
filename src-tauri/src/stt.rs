//! Local-only Whisper model loading and transcription.

use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use thiserror::Error;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use crate::prefs::{validate_model_path, ModelPrefs};

#[cfg(windows)]
use windows::core::PCWSTR;
#[cfg(windows)]
use windows::Win32::Storage::FileSystem::GetDriveTypeW;

pub(crate) fn is_local_model_path(path: &str) -> bool {
    #[cfg(not(windows))]
    {
        let _ = path;
        true
    }

    #[cfg(windows)]
    {
        fn root_for(path: &str) -> Option<String> {
            let normalized = path.replace('/', "\\");
            let normalized = normalized.strip_prefix("\\\\?\\").unwrap_or(&normalized);
            if normalized.as_bytes().get(1) == Some(&b':') {
                Some(format!("{}:\\", &normalized[..1]))
            } else {
                None
            }
        }

        fn is_local_drive(root: &str) -> bool {
            let wide: Vec<u16> = root.encode_utf16().chain(std::iter::once(0)).collect();
            let drive_type = unsafe { GetDriveTypeW(PCWSTR(wide.as_ptr())) };
            matches!(drive_type, 2 | 3 | 5 | 6)
        }

        let Some(configured_root) = root_for(path).or_else(|| {
            std::env::current_dir()
                .ok()
                .and_then(|current| root_for(&current.to_string_lossy()))
        }) else {
            return false;
        };
        if !is_local_drive(&configured_root) {
            return false;
        }
        let Ok(canonical) = Path::new(path).canonicalize() else {
            return true;
        };
        root_for(&canonical.to_string_lossy()).is_some_and(|root| is_local_drive(&root))
    }
}

pub const MIN_AUDIO_SAMPLES: usize = 4_000;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum TranscriptionError {
    #[error("no local Whisper model is configured — open Viby Options and choose a local model file")]
    MissingModel,
    #[error("the configured model path is not local — in Viby Options, choose a model file stored on this PC")]
    InvalidModelPath,
    #[error("the configured local Whisper model does not exist — open Viby Options and choose the file again")]
    ModelNotFound,
    #[error("the local Whisper model could not be loaded — check the file in Viby Options or choose another local model")]
    ModelLoad,
    #[error("the local Whisper model state could not be created")]
    State,
    #[error("the capture was too short to transcribe")]
    TooShort,
    #[error("transcription was cancelled")]
    Cancelled,
    #[error("local transcription failed")]
    Inference,
    #[error("the local transcription returned no text")]
    Empty,
}

/// Cloud-backed placeholders (OneDrive Files On-Demand) hydrate on open, which
/// would put network traffic in the dictation path. They are not local files.
#[cfg(windows)]
fn is_cloud_placeholder(path: &Path) -> bool {
    use windows::Win32::Storage::FileSystem::{
        GetFileAttributesW, FILE_ATTRIBUTE_OFFLINE, FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS,
        FILE_ATTRIBUTE_RECALL_ON_OPEN,
    };
    let wide: Vec<u16> = path
        .to_string_lossy()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let attributes = unsafe { GetFileAttributesW(PCWSTR(wide.as_ptr())) };
    if attributes == u32::MAX {
        return false;
    }
    attributes & (FILE_ATTRIBUTE_OFFLINE.0 | FILE_ATTRIBUTE_RECALL_ON_OPEN.0 | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS.0) != 0
}

fn validated_model_path(path: &str) -> Result<PathBuf, TranscriptionError> {
    validate_model_path(Some(path)).map_err(|_| TranscriptionError::InvalidModelPath)?;
    if !is_local_model_path(path) {
        return Err(TranscriptionError::InvalidModelPath);
    }
    let source = Path::new(path);
    if !source.is_file() {
        return Err(TranscriptionError::ModelNotFound);
    }
    let canonical = source
        .canonicalize()
        .map_err(|_| TranscriptionError::ModelNotFound)?;
    if !is_local_model_path(&canonical.to_string_lossy()) {
        return Err(TranscriptionError::InvalidModelPath);
    }
    #[cfg(windows)]
    if is_cloud_placeholder(&canonical) {
        return Err(TranscriptionError::InvalidModelPath);
    }
    Ok(canonical)
}

pub fn validate_model_preferences(prefs: &ModelPrefs) -> Result<(), TranscriptionError> {
    let path = prefs
        .path
        .as_deref()
        .ok_or(TranscriptionError::MissingModel)?;
    validated_model_path(path).map(|_| ())
}
pub fn validate_audio(audio: &[f32]) -> Result<(), TranscriptionError> {
    if audio.len() < MIN_AUDIO_SAMPLES || audio.iter().any(|sample| !sample.is_finite()) {
        return Err(TranscriptionError::TooShort);
    }
    Ok(())
}
// `whisper-rs` 0.16's safe closure adapter stores a trait-object pointer but
// invokes it as the concrete closure type, so the callback can spuriously
// abort encoding. Keep the callback ABI raw and pass the live AtomicBool.
unsafe extern "C" fn whisper_abort_callback(user_data: *mut std::ffi::c_void) -> bool {
    if user_data.is_null() {
        return false;
    }
    (*(user_data as *const AtomicBool)).load(Ordering::Relaxed)
}

pub struct LocalWhisper {
    context: WhisperContext,
    language: Option<String>,
}

impl LocalWhisper {
    pub fn load(prefs: &ModelPrefs) -> Result<Self, TranscriptionError> {
        validate_model_preferences(prefs)?;
        let path = prefs
            .path
            .as_deref()
            .ok_or(TranscriptionError::MissingModel)?;
        let model_path = validated_model_path(path)?;
        let context = WhisperContext::new_with_params(
            model_path.to_string_lossy().as_ref(),
            WhisperContextParameters::default(),
        )
        .map_err(|_| TranscriptionError::ModelLoad)?;
        let language = match prefs.language.trim().to_ascii_lowercase().as_str() {
            "" | "auto" => None,
            language => Some(language.to_string()),
        };
        Ok(Self { context, language })
    }

    pub fn transcribe(
        &mut self,
        audio: &[f32],
        cancelled: &Arc<AtomicBool>,
    ) -> Result<String, TranscriptionError> {
        validate_audio(audio)?;
        if cancelled.load(Ordering::Relaxed) {
            return Err(TranscriptionError::Cancelled);
        }
        let mut state = self
            .context
            .create_state()
            .map_err(|_| TranscriptionError::State)?;
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(self.language.as_deref());
        params.set_no_context(true);
        params.set_no_timestamps(true);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_single_segment(false);
        let threads = std::thread::available_parallelism()
            .map(|count| count.get().clamp(1, 8) as i32)
            .unwrap_or(4);
        params.set_n_threads(threads);
        let peak = audio.iter().copied().map(f32::abs).fold(0.0_f32, f32::max);
        tracing::info!(samples = audio.len(), peak, "transcribing local audio");
        let user_data = Arc::as_ptr(cancelled) as *mut std::ffi::c_void;
        unsafe {
            params.set_abort_callback(Some(whisper_abort_callback));
            params.set_abort_callback_user_data(user_data);
        }
        if state.full(params, audio).is_err() {
            return if cancelled.load(Ordering::Relaxed) {
                Err(TranscriptionError::Cancelled)
            } else {
                Err(TranscriptionError::Inference)
            };
        }
        if cancelled.load(Ordering::Relaxed) {
            return Err(TranscriptionError::Cancelled);
        }

        let mut result = String::new();
        for segment in state.as_iter() {
            let text = segment
                .to_str()
                .map_err(|_| TranscriptionError::Inference)?
                .trim();
            if !text.is_empty() {
                if !result.is_empty() {
                    result.push(' ');
                }
                result.push_str(text);
            }
        }
        if result.is_empty() {
            return Err(TranscriptionError::Empty);
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prefs::ModelPrefs;

    #[test]
    fn missing_model_is_actionable_and_local() {
        let error = validate_model_preferences(&ModelPrefs::default()).unwrap_err();
        assert_eq!(error, TranscriptionError::MissingModel);
    }
    #[test]
    fn configured_missing_model_is_actionable() {
        let path = std::env::temp_dir()
            .join(format!("viby-missing-model-{}", std::process::id()))
            .join("model.bin");
        let error = validated_model_path(&path.to_string_lossy()).unwrap_err();
        assert_eq!(error, TranscriptionError::ModelNotFound);
    }

    #[test]
    fn invalid_model_file_is_rejected_by_loader() {
        let dir = std::env::temp_dir().join(format!("viby-invalid-model-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("model.bin");
        std::fs::write(&path, b"not a whisper model").unwrap();
        let prefs = ModelPrefs {
            path: Some(path.to_string_lossy().into_owned()),
            ..ModelPrefs::default()
        };
        assert_eq!(
            LocalWhisper::load(&prefs).err(),
            Some(TranscriptionError::ModelLoad)
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[cfg(windows)]
    #[test]
    fn lowercase_drive_letter_remains_local() {
        let dir = std::env::temp_dir().join(format!("viby-lowercase-drive-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("model.bin");
        std::fs::write(&path, b"placeholder").unwrap();
        let raw = path.to_string_lossy().into_owned();
        let lowercase = format!("{}{}", raw[..1].to_ascii_lowercase(), &raw[1..]);
        assert!(is_local_model_path(&lowercase));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn short_capture_is_rejected_before_inference() {
        let error = validate_audio(&vec![0.0; MIN_AUDIO_SAMPLES - 1]).unwrap_err();
        assert_eq!(error, TranscriptionError::TooShort);
    }

    #[test]
    fn non_finite_samples_are_rejected_before_inference() {
        // A long-enough buffer isolates the finiteness branch: a device
        // glitch that yields NaN/Inf must not reach whisper.cpp.
        let mut audio = vec![0.0_f32; MIN_AUDIO_SAMPLES];
        audio[MIN_AUDIO_SAMPLES / 2] = f32::NAN;
        assert_eq!(
            validate_audio(&audio).unwrap_err(),
            TranscriptionError::TooShort
        );
        audio[MIN_AUDIO_SAMPLES / 2] = f32::INFINITY;
        assert_eq!(
            validate_audio(&audio).unwrap_err(),
            TranscriptionError::TooShort
        );
        audio[MIN_AUDIO_SAMPLES / 2] = 0.0;
        assert!(validate_audio(&audio).is_ok());
    }

    #[test]
    fn raw_abort_callback_reads_atomic_flag() {
        let cancelled = AtomicBool::new(false);
        let user_data = &cancelled as *const AtomicBool as *mut std::ffi::c_void;
        assert!(!unsafe { whisper_abort_callback(user_data) });
        cancelled.store(true, Ordering::Relaxed);
        assert!(unsafe { whisper_abort_callback(user_data) });
    }
}
