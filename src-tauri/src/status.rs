//! Model and microphone state exposed to the interface. Detection is local
//! only: the model is a file on disk, the microphone is a WASAPI device.

use crate::prefs::{validate_model_path, ModelPrefs};
use crate::stt::is_local_model_path;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ModelState {
    /// No model file configured, or the configured file is absent.
    Missing,
    /// A model file exists at this path.
    Present { path: String },
}

pub fn detect_model(prefs: &ModelPrefs) -> ModelState {
    match &prefs.path {
        Some(path)
            if validate_model_path(Some(path)).is_ok()
                && is_local_model_path(path)
                && std::path::Path::new(path).is_file() =>
        {
            ModelState::Present { path: path.clone() }
        }
        _ => ModelState::Missing,
    }
}

/// Name of the configured input device when it is available.
pub fn configured_microphone(selected: Option<&str>) -> Option<String> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    match selected {
        Some(selected) => host.input_devices().ok()?.find_map(|device| {
            let name = device.name().ok()?;
            (name == selected).then_some(name)
        }),
        None => host
            .default_input_device()
            .and_then(|device| device.name().ok()),
    }
}

/// All capturable input device names, for the Options window.
pub fn list_microphones() -> Vec<String> {
    use cpal::traits::{DeviceTrait, HostTrait};
    cpal::default_host()
        .input_devices()
        .map(|devices| devices.filter_map(|d| d.name().ok()).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_is_missing_without_a_path_or_file() {
        let prefs = ModelPrefs::default();
        assert_eq!(detect_model(&prefs), ModelState::Missing);

        let prefs = ModelPrefs {
            path: Some("does/not/exist.gguf".to_string()),
            ..ModelPrefs::default()
        };
        assert_eq!(detect_model(&prefs), ModelState::Missing);
    }

    #[test]
    fn model_is_missing_for_non_local_paths() {
        let prefs = ModelPrefs {
            path: Some(r"\\server\share\model.bin".to_string()),
            ..ModelPrefs::default()
        };
        assert_eq!(detect_model(&prefs), ModelState::Missing);
    }

    #[test]
    fn model_is_present_when_the_file_exists() {
        let dir = std::env::temp_dir().join(format!("whisper-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("model.bin");
        std::fs::write(&file, b"placeholder").unwrap();

        let prefs = ModelPrefs {
            path: Some(file.to_string_lossy().into_owned()),
            ..ModelPrefs::default()
        };
        assert!(matches!(detect_model(&prefs), ModelState::Present { .. }));

        std::fs::remove_dir_all(&dir).ok();
    }
}
