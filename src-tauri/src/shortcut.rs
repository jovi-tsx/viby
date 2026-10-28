//! User-facing shortcut strings ("Ctrl+Shift+Space") to `Shortcut` values.
//! Pure mapping, hardware-free; OS conflicts surface at registration time.

use std::str::FromStr;

use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut};

use crate::prefs::{validate_shortcut, PrefsError};

pub fn parse(raw: &str) -> Result<Shortcut, PrefsError> {
    validate_shortcut(raw)?;
    let mut parts: Vec<&str> = raw.split('+').map(str::trim).collect();
    let key = parts.pop().ok_or(PrefsError::EmptyShortcut)?;

    let mut modifiers = Modifiers::empty();
    for part in parts {
        modifiers |= match part.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => Modifiers::CONTROL,
            "alt" => Modifiers::ALT,
            "shift" => Modifiers::SHIFT,
            "super" | "meta" | "win" | "cmd" => Modifiers::SUPER,
            _ => return Err(PrefsError::InvalidModifier(part.to_string())),
        };
    }

    let code = parse_code(key).ok_or(PrefsError::MissingKey)?;
    Ok(Shortcut::new(Some(modifiers), code))
}

/// Maps a key token to a keyboard-types `Code`. Single letters become
/// `KeyX`, single digits `DigitX`, everything else is normalized to the
/// keyboard-types name ("space" -> "Space", "f9" -> "F9").
fn parse_code(token: &str) -> Option<Code> {
    // Common aliases users type; keyboard-types names are canonical.
    let token = match token.to_ascii_lowercase().as_str() {
        "esc" => "Escape",
        _ => token,
    };
    let lower = token.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix('f') {
        if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
            return Code::from_str(&format!("F{rest}")).ok();
        }
    }

    let mut chars = token.chars();
    let first = chars.next()?;
    let name = if chars.next().is_none() {
        if first.is_ascii_alphabetic() {
            format!("Key{}", first.to_ascii_uppercase())
        } else if first.is_ascii_digit() {
            format!("Digit{first}")
        } else {
            token.to_string()
        }
    } else {
        token.to_string()
    };

    // Try the token verbatim ("ArrowUp"), then capitalized ("space" ->
    // "Space"): keyboard-types names are case-sensitive camelCase.
    Code::from_str(&name)
        .ok()
        .or_else(|| capitalize_first(&name).and_then(|candidate| Code::from_str(&candidate).ok()))
        .or_else(|| {
            let lower = name.to_ascii_lowercase();
            capitalize_first(&lower).and_then(|candidate| Code::from_str(&candidate).ok())
        })
}

fn capitalize_first(value: &str) -> Option<String> {
    let mut chars = value.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().collect::<String>() + chars.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_default_shortcut() {
        let shortcut = parse("Ctrl+Shift+Space").unwrap();
        assert_eq!(shortcut.mods, Modifiers::CONTROL | Modifiers::SHIFT);
        assert_eq!(shortcut.key, Code::Space);
    }

    #[test]
    fn maps_letters_digits_and_function_keys() {
        assert_eq!(parse("Alt+F9").unwrap().key, Code::F9);
        assert_eq!(parse("Ctrl+d").unwrap().key, Code::KeyD);
        assert_eq!(parse("Ctrl+3").unwrap().key, Code::Digit3);
        assert_eq!(parse("Ctrl+ArrowUp").unwrap().key, Code::ArrowUp);
        assert_eq!(parse("Ctrl+Esc").unwrap().key, Code::Escape);
    }

    #[test]
    fn rejects_invalid_shortcuts() {
        assert!(parse("").is_err());
        assert!(parse("Space").is_err());
        assert!(parse("Ctrl+").is_err());
        assert!(parse("Ctrl+NotAKey").is_err());
    }

    #[test]
    fn rejects_non_ascii_key_without_panicking() {
        let result = std::panic::catch_unwind(|| parse("Ctrl+é"));
        assert!(result.is_ok());
        assert!(result.unwrap().is_err());
    }
}
