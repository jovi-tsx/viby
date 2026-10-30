//! Local, non-sensitive preferences. This module is the only code that reads
//! or writes the persisted store, so the privacy invariant ("no audio, no
//! transcription, no clipboard content on disk") is auditable in one place.

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const STORE_FILE: &str = "preferences.json";
pub const STORE_KEY: &str = "preferences";
pub const DEFAULT_SHORTCUT: &str = "Ctrl+Shift+Space";
/// Discards a transcript waiting for confirmation (D16) or cancels a take the
/// engine is still processing (R4); consulted only in those two states.
pub const DEFAULT_DISCARD_SHORTCUT: &str = "Ctrl+Shift+Backspace";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    /// The dictation shortcut. Hold-to-talk when `confirm_before_insert` is
    /// off; press-once when it is on (D16).
    pub shortcut: String,
    /// Discards a transcript waiting for confirmation or cancels a take the
    /// engine is processing; consulted only in those two states (R4, R7).
    pub discard_shortcut: String,
    /// Input device name; `None` follows the system default.
    pub microphone: Option<String>,
    pub engine: EnginePrefs,
    pub model: ModelPrefs,
    pub insertion: InsertionPrefs,
    pub interface: InterfacePrefs,
}

/// Where the user's own engine answers (R3, R3a). Viby never starts it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct EnginePrefs {
    /// Full http(s) URL; empty leaves Viby unconfigured (R7).
    pub endpoint: String,
    /// Lets the endpoint be a private-network address. Off by default: when
    /// on, audio leaves this PC (R3a).
    pub allow_local_network: bool,
}

/// What the engine is asked for. The object keeps its pre-D23 key and shape
/// so a previous revision still loads a store saved by this one; the old
/// `variant` and `path` fields are dropped on load and never written.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelPrefs {
    /// "auto" or an ISO 639 code; multilingual is the contract default.
    pub language: String,
    /// Optional model name for engines that ask for one; empty sends none.
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct InsertionPrefs {
    /// Send Enter after pasting. Opt-in only, off by default.
    pub send_enter: bool,
    /// Hold the finished transcript until the user accepts it on the bar.
    /// Off by default: releasing the shortcut already means "send it", so the
    /// accept control is redundant for most people and only appears here.
    pub confirm_before_insert: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct InterfacePrefs {
    /// Show the provisional local preview while speaking (D4).
    pub show_preview: bool,
    /// Bottom-edge bar position: "left", "center" (default), or "right" (D9).
    pub bar_position: String,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            shortcut: DEFAULT_SHORTCUT.to_string(),
            discard_shortcut: DEFAULT_DISCARD_SHORTCUT.to_string(),
            microphone: None,
            engine: EnginePrefs::default(),
            model: ModelPrefs::default(),
            insertion: InsertionPrefs::default(),
            interface: InterfacePrefs::default(),
        }
    }
}

impl Default for ModelPrefs {
    fn default() -> Self {
        Self {
            language: "auto".to_string(),
            name: String::new(),
        }
    }
}

impl Default for InterfacePrefs {
    fn default() -> Self {
        Self {
            show_preview: true,
            bar_position: "center".to_string(),
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PrefsError {
    #[error("shortcut must not be empty")]
    EmptyShortcut,
    #[error("shortcut needs at least one modifier (Ctrl, Alt, Shift, Super)")]
    NoModifier,
    #[error("shortcut is missing a key after the modifiers")]
    MissingKey,
    #[error("shortcut modifier '{0}' is not recognized")]
    InvalidModifier(String),
    #[error("shortcut '{0}' is already registered by another application")]
    ShortcutConflict(String),
    #[error("bar position must be left, center, or right")]
    InvalidBarPosition,
    #[error("the discard shortcut must be different from the dictation shortcut")]
    DuplicateShortcut,
}

/// Valid bottom-edge positions for the bar (D9); center is the default.
pub const BAR_POSITIONS: [&str; 3] = ["left", "center", "right"];

/// Structural validation of a shortcut before the OS-level conflict check.
pub fn validate_shortcut(raw: &str) -> Result<(), PrefsError> {
    let parts: Vec<&str> = raw.split('+').map(str::trim).collect();
    if parts.iter().all(|p| p.is_empty()) {
        return Err(PrefsError::EmptyShortcut);
    }
    let (key, modifiers) = parts.split_last().ok_or(PrefsError::EmptyShortcut)?;
    if key.is_empty() || is_modifier(key) {
        return Err(PrefsError::MissingKey);
    }
    if !modifiers.iter().any(|m| is_modifier(m)) {
        return Err(PrefsError::NoModifier);
    }
    if let Some(unknown) = modifiers.iter().find(|m| !is_modifier(m)) {
        return Err(PrefsError::InvalidModifier((*unknown).to_string()));
    }
    Ok(())
}

pub fn is_modifier(token: &str) -> bool {
    matches!(
        token.to_ascii_lowercase().as_str(),
        "ctrl" | "control" | "alt" | "shift" | "super" | "meta" | "win" | "cmd"
    )
}

pub fn validate_preferences(prefs: &Preferences) -> Result<(), PrefsError> {
    validate_preferences_field(prefs).map_err(|(_, error)| error)
}

/// Validates like `validate_preferences` and also names the Options field
/// whose value is wrong, so the message lands under the control the user has
/// to change: an invalid discard shortcut is the discard field's error, never
/// the dictation shortcut's (R7).
///
/// This is also the load-time check, so it never looks at the engine
/// endpoint: R3a needs name resolution, and a load failure quarantines the
/// whole store. The endpoint is checked on save and per take instead.
pub fn validate_preferences_field(prefs: &Preferences) -> Result<(), (&'static str, PrefsError)> {
    validate_shortcut(&prefs.shortcut).map_err(|error| ("shortcut", error))?;
    validate_shortcut(&prefs.discard_shortcut).map_err(|error| ("discard-shortcut", error))?;
    if shortcuts_equal(&prefs.shortcut, &prefs.discard_shortcut) {
        return Err(("discard-shortcut", PrefsError::DuplicateShortcut));
    }
    if !BAR_POSITIONS.contains(&prefs.interface.bar_position.as_str()) {
        return Err(("bar-position", PrefsError::InvalidBarPosition));
    }
    Ok(())
}

/// Semantic equality of two shortcut strings (R7: the dictation and discard
/// shortcuts "may not be the same"). Structurally invalid input is never
/// equal to anything — the caller validates shape separately and reports the
/// more specific error.
pub fn shortcuts_equal(a: &str, b: &str) -> bool {
    match (crate::shortcut::parse(a), crate::shortcut::parse(b)) {
        (Ok(a), Ok(b)) => a.mods == b.mods && a.key == b.key,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The exact set of JSON keys allowed in the persisted store. Anything
    /// beyond this set means a sensitive field crept into the schema.
    const ALLOWED_STORE_KEYS: &[&str] = &[
        "shortcut",
        "discard_shortcut",
        "microphone",
        "engine",
        "endpoint",
        "allow_local_network",
        "model",
        "insertion",
        "interface",
        "language",
        "name",
        "send_enter",
        "confirm_before_insert",
        "show_preview",
        "bar_position",
    ];

    #[test]
    fn default_shortcut_is_valid() {
        validate_shortcut(DEFAULT_SHORTCUT).unwrap();
    }

    #[test]
    fn default_discard_shortcut_is_valid_and_distinct() {
        validate_shortcut(DEFAULT_DISCARD_SHORTCUT).unwrap();
        assert!(!shortcuts_equal(DEFAULT_SHORTCUT, DEFAULT_DISCARD_SHORTCUT));
        validate_preferences(&Preferences::default()).unwrap();
    }

    #[test]
    fn rejects_a_discard_shortcut_equal_to_the_dictation_shortcut() {
        let prefs = Preferences {
            discard_shortcut: DEFAULT_SHORTCUT.to_string(),
            ..Preferences::default()
        };
        assert_eq!(
            validate_preferences(&prefs),
            Err(PrefsError::DuplicateShortcut)
        );
    }

    #[test]
    fn treats_equivalent_modifier_order_as_the_same_shortcut() {
        // "may not be the same" (R7) is a semantic check, not string equality:
        // Ctrl+Shift+Space and Shift+Ctrl+Space register the same OS shortcut.
        assert!(shortcuts_equal("Ctrl+Shift+Space", "Shift+Ctrl+Space"));
    }

    #[test]
    fn rejects_an_invalid_discard_shortcut() {
        let prefs = Preferences {
            discard_shortcut: "Space".to_string(),
            ..Preferences::default()
        };
        assert_eq!(validate_preferences(&prefs), Err(PrefsError::NoModifier));
    }

    #[test]
    fn a_refused_shortcut_is_reported_on_its_own_field() {
        let invalid_discard = Preferences {
            discard_shortcut: "Backspace".to_string(),
            ..Preferences::default()
        };
        assert_eq!(
            validate_preferences_field(&invalid_discard),
            Err(("discard-shortcut", PrefsError::NoModifier))
        );

        let invalid_dictation = Preferences {
            shortcut: "Space".to_string(),
            ..Preferences::default()
        };
        assert_eq!(
            validate_preferences_field(&invalid_dictation),
            Err(("shortcut", PrefsError::NoModifier))
        );

        let duplicate = Preferences {
            discard_shortcut: "Shift+Ctrl+Space".to_string(),
            ..Preferences::default()
        };
        assert_eq!(
            validate_preferences_field(&duplicate),
            Err(("discard-shortcut", PrefsError::DuplicateShortcut))
        );
    }

    #[test]
    fn rejects_shortcuts_that_are_not_global_safe() {
        assert_eq!(validate_shortcut(""), Err(PrefsError::EmptyShortcut));
        assert_eq!(validate_shortcut("  + "), Err(PrefsError::EmptyShortcut));
        assert_eq!(validate_shortcut("Space"), Err(PrefsError::NoModifier));
        assert_eq!(validate_shortcut("A"), Err(PrefsError::NoModifier));
        assert_eq!(validate_shortcut("Ctrl+"), Err(PrefsError::MissingKey));
        assert_eq!(validate_shortcut("Ctrl+Shift"), Err(PrefsError::MissingKey));
    }

    #[test]
    fn accepts_modifier_plus_key() {
        validate_shortcut("Ctrl+Shift+Space").unwrap();
        validate_shortcut("Alt+F9").unwrap();
        validate_shortcut("Super+D").unwrap();
    }

    #[test]
    fn rejects_invalid_persisted_preferences() {
        let prefs = Preferences {
            shortcut: "Space".to_string(),
            ..Preferences::default()
        };
        assert_eq!(validate_preferences(&prefs), Err(PrefsError::NoModifier));

        let prefs = Preferences {
            interface: InterfacePrefs {
                bar_position: "top".to_string(),
                ..InterfacePrefs::default()
            },
            ..Preferences::default()
        };
        assert_eq!(
            validate_preferences(&prefs),
            Err(PrefsError::InvalidBarPosition)
        );
    }

    #[test]
    fn rejects_unknown_modifier_tokens() {
        assert!(validate_shortcut("Ctrl+Banana+A").is_err());
    }

    #[test]
    fn persisted_schema_stays_non_sensitive() {
        let json = serde_json::to_value(Preferences::default()).unwrap();
        let mut keys = Vec::new();
        collect_keys(&json, &mut keys);
        for key in &keys {
            assert!(
                ALLOWED_STORE_KEYS.contains(&key.as_str()),
                "unexpected persisted key: {key}"
            );
            let lowered = key.to_ascii_lowercase();
            for banned in ["audio", "transcript", "history", "clipboard", "text"] {
                assert!(
                    !lowered.contains(banned),
                    "sensitive-looking key persisted: {key}"
                );
            }
        }
    }

    #[test]
    fn enter_and_confirmation_are_opt_in_and_preview_defaults_on() {
        let prefs = Preferences::default();
        assert!(!prefs.insertion.send_enter);
        // Releasing the shortcut is the send; a confirmation step is for the
        // few who want it, never the default.
        assert!(!prefs.insertion.confirm_before_insert);
        assert!(prefs.interface.show_preview);
        assert_eq!(prefs.model.language, "auto");
        // The only path by which audio leaves this PC is opt-in (R3a).
        assert!(!prefs.engine.allow_local_network);
        assert!(prefs.engine.endpoint.is_empty());
    }

    /// A store written before D23: model path and variant, no engine.
    const PRE_D23_STORE: &str = r#"{
        "shortcut": "Ctrl+Alt+D",
        "discard_shortcut": "Ctrl+Alt+X",
        "microphone": null,
        "model": {"variant": "small", "language": "pt", "path": "C:\\models\\ggml-small.bin"},
        "insertion": {"send_enter": false, "confirm_before_insert": true},
        "interface": {"show_preview": false, "bar_position": "left"}
    }"#;

    #[test]
    fn an_old_store_loads_with_its_language_kept_and_no_engine() {
        let prefs: Preferences = serde_json::from_str(PRE_D23_STORE).unwrap();
        validate_preferences(&prefs).unwrap();
        assert_eq!(prefs.model.language, "pt");
        assert_eq!(prefs.model.name, "");
        assert_eq!(prefs.engine, EnginePrefs::default());
        assert_eq!(prefs.shortcut, "Ctrl+Alt+D");
        assert!(prefs.insertion.confirm_before_insert);
        // The discarded model fields are never written back.
        let saved = serde_json::to_value(&prefs).unwrap();
        assert!(saved["model"].get("path").is_none());
        assert!(saved["model"].get("variant").is_none());
    }

    /// The pre-D23 schema, as the previous revision deserializes it. Rollback
    /// (PLAN) depends on that revision loading what this one saves.
    #[derive(Deserialize)]
    #[serde(default)]
    #[allow(dead_code)]
    struct PreviousRevision {
        shortcut: String,
        discard_shortcut: String,
        microphone: Option<String>,
        model: PreviousModel,
        insertion: InsertionPrefs,
        interface: InterfacePrefs,
    }

    #[derive(Deserialize, Default)]
    #[serde(default)]
    #[allow(dead_code)]
    struct PreviousModel {
        variant: String,
        language: String,
        path: Option<String>,
    }

    impl Default for PreviousRevision {
        fn default() -> Self {
            Self {
                shortcut: DEFAULT_SHORTCUT.into(),
                discard_shortcut: DEFAULT_DISCARD_SHORTCUT.into(),
                microphone: None,
                model: PreviousModel::default(),
                insertion: InsertionPrefs::default(),
                interface: InterfacePrefs::default(),
            }
        }
    }

    #[test]
    fn the_previous_revision_still_loads_a_store_saved_by_this_one() {
        let prefs = Preferences {
            engine: EnginePrefs {
                endpoint: "http://127.0.0.1:8080/inference".into(),
                allow_local_network: true,
            },
            model: ModelPrefs {
                language: "es".into(),
                name: "whisper-1".into(),
            },
            ..Preferences::default()
        };
        let saved = serde_json::to_value(&prefs).unwrap();
        let previous: PreviousRevision = serde_json::from_value(saved).unwrap();
        assert_eq!(previous.model.language, "es");
        // The previous load path validates `model.path`; an endpoint never
        // lands there.
        assert_eq!(previous.model.path, None);
    }

    fn collect_keys(value: &serde_json::Value, out: &mut Vec<String>) {
        if let serde_json::Value::Object(map) = value {
            for (key, nested) in map {
                out.push(key.clone());
                collect_keys(nested, out);
            }
        }
    }
}
