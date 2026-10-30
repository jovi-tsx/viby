mod audio;
mod bar;
mod engine;
mod flow;
mod prefs;
mod shortcut;
mod status;
mod tray;

use parking_lot::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use tauri_plugin_store::StoreExt;

use prefs::{Preferences, PrefsError, STORE_FILE, STORE_KEY};

/// What the interface needs to render engine and microphone state.
#[derive(Serialize)]
struct StatusDto {
    /// Whether an engine address is saved. Reachability is checked per take,
    /// never polled (R3).
    engine_configured: bool,
    microphone: Option<String>,
    shortcut: String,
    shortcut_error: Option<String>,
    discard_shortcut: String,
    discard_shortcut_error: Option<String>,
}

#[derive(Clone)]
struct PreferencesState {
    prefs: Preferences,
    load_error: Option<String>,
    active_shortcut: Option<String>,
    shortcut_error: Option<String>,
    active_discard_shortcut: Option<String>,
    discard_shortcut_error: Option<String>,
}
#[tauri::command]
fn get_status(app: AppHandle) -> StatusDto {
    let state = app.state::<Mutex<PreferencesState>>().lock().clone();
    StatusDto {
        engine_configured: !state.prefs.engine.endpoint.trim().is_empty(),
        microphone: status::configured_microphone(state.prefs.microphone.as_deref()),
        shortcut: state.prefs.shortcut,
        shortcut_error: state.shortcut_error,
        discard_shortcut: state.prefs.discard_shortcut,
        discard_shortcut_error: state.discard_shortcut_error,
    }
}

#[tauri::command]
fn get_preferences(app: AppHandle) -> Result<Preferences, String> {
    let preferences_state = app.state::<Mutex<PreferencesState>>();
    let state = preferences_state.lock();
    state
        .load_error
        .clone()
        .map_or_else(|| Ok(state.prefs.clone()), Err)
}

#[tauri::command]
fn list_microphones() -> Vec<String> {
    status::list_microphones()
}
#[tauri::command]
fn start_dictation(app: AppHandle) -> bool {
    let prefs = app.state::<Mutex<PreferencesState>>().lock().prefs.clone();
    app.state::<flow::FlowController>().start(
        engine::EngineConfig::from_prefs(&prefs),
        prefs.microphone,
        prefs.interface,
        prefs.insertion.confirm_before_insert,
    )
}

#[tauri::command]
fn stop_dictation(app: AppHandle) {
    app.state::<flow::FlowController>().stop();
}

#[tauri::command]
fn cancel_dictation(app: AppHandle) {
    app.state::<flow::FlowController>().cancel();
}

/// Releases a held transcript when `confirm_before_insert` is on.
#[tauri::command]
fn accept_dictation(app: AppHandle) {
    app.state::<flow::FlowController>().accept();
}

#[tauri::command]
fn get_flow_state(app: AppHandle) -> flow::FlowState {
    app.state::<flow::FlowController>().current_state()
}

/// Dispatches a raw OS shortcut event to whichever of the two configured
/// shortcuts it matches (D16). A press matching neither — briefly possible
/// right after a save changes one of them mid-flight — is silently dropped.
fn on_shortcut_event(app: &AppHandle, shortcut: &Shortcut, state: ShortcutState) {
    let (prefs, active_shortcut, active_discard_shortcut) = {
        let preferences_state = app.state::<Mutex<PreferencesState>>();
        let guard = preferences_state.lock();
        (
            guard.prefs.clone(),
            guard.active_shortcut.clone(),
            guard.active_discard_shortcut.clone(),
        )
    };
    if shortcut_matches(active_shortcut.as_deref(), shortcut) {
        match state {
            ShortcutState::Pressed => {
                tracing::info!("dictation shortcut pressed");
                // The Loading flow state (emitted by the controller before
                // the worker can fail) is the single ordered activation
                // signal; no separate event.
                app.state::<flow::FlowController>().dictation_pressed(
                    engine::EngineConfig::from_prefs(&prefs),
                    prefs.microphone,
                    prefs.interface,
                    prefs.insertion.confirm_before_insert,
                );
            }
            ShortcutState::Released => {
                // Press-once (D16): the key is not held, so release means
                // nothing on its own — the second press is what ends the
                // take, handled above as `DictationPressDecision::End`.
                if !prefs.insertion.confirm_before_insert {
                    stop_dictation(app.clone());
                }
            }
        }
    } else if matches!(state, ShortcutState::Pressed)
        && shortcut_matches(active_discard_shortcut.as_deref(), shortcut)
    {
        tracing::info!("discard shortcut pressed");
        app.state::<flow::FlowController>().discard_pressed();
    }
}

fn shortcut_matches(active_raw: Option<&str>, shortcut: &Shortcut) -> bool {
    active_raw
        .and_then(|raw| shortcut::parse(raw).ok())
        .map(|active| active.mods == shortcut.mods && active.key == shortcut.key)
        .unwrap_or(false)
}

/// Why a save failed; the Options page picks its recovery state from `kind`.
#[derive(Serialize)]
struct SaveError {
    kind: &'static str,
    message: String,
    field: Option<&'static str>,
}

impl SaveError {
    fn validation(field: &'static str, message: String) -> Self {
        Self {
            kind: "validation",
            message,
            field: Some(field),
        }
    }
    fn conflict(message: String) -> Self {
        Self {
            kind: "conflict",
            message,
            field: None,
        }
    }
    fn persistence(message: String) -> Self {
        Self {
            kind: "persistence",
            message,
            field: None,
        }
    }
}

/// Validates and applies new preferences. Persistence commits the managed
/// state only after the store accepts the new value.
///
/// Async because a non-empty engine endpoint is resolved and checked against
/// R3a under the permission being saved; that check belongs to saving alone
/// and never runs on load (R7).
#[tauri::command]
async fn save_preferences(app: AppHandle, next: Preferences) -> Result<(), SaveError> {
    prefs::validate_preferences_field(&next)
        .map_err(|(field, e)| SaveError::validation(field, e.to_string()))?;
    if !next.engine.endpoint.trim().is_empty() {
        engine::Engine::system()
            .validate_for_save(&next.engine.endpoint, next.engine.allow_local_network)
            .await
            .map_err(|e| SaveError::validation("engine-endpoint", e.to_string()))?;
    }
    let next_shortcut = shortcut::parse(&next.shortcut)
        .map_err(|e| SaveError::validation("shortcut", e.to_string()))?;
    let next_discard_shortcut = shortcut::parse(&next.discard_shortcut)
        .map_err(|e| SaveError::validation("discard-shortcut", e.to_string()))?;

    let previous = app.state::<Mutex<PreferencesState>>().lock().clone();
    // A previous load failure does not block saving: the in-memory state fell
    // back to defaults, and a successful save clears the error (recovery).
    let shortcut_changed = shortcut_differs(previous.active_shortcut.as_deref(), &next_shortcut);
    let discard_shortcut_changed = shortcut_differs(
        previous.active_discard_shortcut.as_deref(),
        &next_discard_shortcut,
    );

    if shortcut_changed {
        replace_shortcut(&app, previous.active_shortcut.as_deref(), &next.shortcut).map_err(
            |_| {
                SaveError::conflict(PrefsError::ShortcutConflict(next.shortcut.clone()).to_string())
            },
        )?;
    }
    if discard_shortcut_changed
        && replace_shortcut(
            &app,
            previous.active_discard_shortcut.as_deref(),
            &next.discard_shortcut,
        )
        .is_err()
    {
        // The dictation shortcut may already have been swapped above; undo
        // just that one before reporting the conflict.
        if shortcut_changed {
            rollback_shortcut(&app, previous.active_shortcut.as_deref(), &next.shortcut);
        }
        return Err(SaveError::conflict(
            PrefsError::ShortcutConflict(next.discard_shortcut.clone()).to_string(),
        ));
    }

    if let Err(error) = persist(&app, &next) {
        if shortcut_changed {
            rollback_shortcut(&app, previous.active_shortcut.as_deref(), &next.shortcut);
        }
        if discard_shortcut_changed {
            rollback_shortcut(
                &app,
                previous.active_discard_shortcut.as_deref(),
                &next.discard_shortcut,
            );
        }
        return Err(SaveError::persistence(error));
    }

    let preferences_state = app.state::<Mutex<PreferencesState>>();
    let mut state = preferences_state.lock();
    state.prefs = next.clone();
    state.load_error = None;
    state.active_shortcut = if shortcut_changed {
        Some(next.shortcut)
    } else {
        previous.active_shortcut
    };
    state.active_discard_shortcut = if discard_shortcut_changed {
        Some(next.discard_shortcut)
    } else {
        previous.active_discard_shortcut
    };
    Ok(())
}

/// Whether `next` differs from the currently registered raw shortcut string,
/// comparing parsed value rather than text so equivalent modifier order does
/// not read as a change.
fn shortcut_differs(active_raw: Option<&str>, next: &Shortcut) -> bool {
    match active_raw {
        Some(raw) => shortcut::parse(raw)
            .map(|current| current.mods != next.mods || current.key != next.key)
            .unwrap_or(true),
        None => true,
    }
}

fn register_shortcut(app: &AppHandle, raw: &str) -> Result<(), PrefsError> {
    let parsed = shortcut::parse(raw)?;
    app.global_shortcut()
        .register(parsed)
        .map_err(|_| PrefsError::ShortcutConflict(raw.to_string()))
}

/// Register the replacement before removing the working shortcut. A rejected
/// OS registration therefore leaves the previous shortcut active.
fn replace_shortcut(
    app: &AppHandle,
    previous_raw: Option<&str>,
    next_raw: &str,
) -> Result<(), PrefsError> {
    let next = shortcut::parse(next_raw)?;
    let previous = previous_raw.map(shortcut::parse).transpose()?;
    if let Some(previous) = &previous {
        if previous.mods == next.mods && previous.key == next.key {
            return Ok(());
        }
    }
    let shortcuts = app.global_shortcut();

    shortcuts
        .register(next)
        .map_err(|_| PrefsError::ShortcutConflict(next_raw.to_string()))?;

    if let Some(previous) = previous {
        if shortcuts.unregister(previous).is_err() {
            if let Ok(registered_next) = shortcut::parse(next_raw) {
                let _ = shortcuts.unregister(registered_next);
            }
            return Err(PrefsError::ShortcutConflict(next_raw.to_string()));
        }
    }

    Ok(())
}

/// Undoes a single `replace_shortcut` — unregisters only `next_raw` and
/// restores only `previous_raw`. Scoped to the one shortcut being rolled
/// back: with two independently configurable shortcuts (D16), an
/// `unregister_all` here would also drop the other one's registration.
fn rollback_shortcut(app: &AppHandle, previous_raw: Option<&str>, next_raw: &str) {
    let shortcuts = app.global_shortcut();
    if let Ok(next) = shortcut::parse(next_raw) {
        let _ = shortcuts.unregister(next);
    }
    if let Some(previous_raw) = previous_raw {
        if let Ok(previous) = shortcut::parse(previous_raw) {
            let _ = shortcuts.register(previous);
        }
    }
}

fn persist(app: &AppHandle, prefs: &Preferences) -> Result<(), String> {
    let store = app.store(STORE_FILE).map_err(|e| e.to_string())?;
    let previous = store.get(STORE_KEY);
    store.set(
        STORE_KEY,
        serde_json::to_value(prefs).map_err(|e| e.to_string())?,
    );
    if let Err(error) = store.save().map_err(|e| e.to_string()) {
        match previous {
            Some(value) => store.set(STORE_KEY, value),
            None => {
                let _ = store.delete(STORE_KEY);
            }
        }
        return Err(error);
    }
    Ok(())
}

/// An unreadable store is moved aside so a later save recreates it cleanly;
/// the original remains as `.bak` for manual inspection.
fn quarantine_unreadable_store(app: &AppHandle) {
    let Ok(path) = app.path().app_data_dir().map(|dir| dir.join(STORE_FILE)) else {
        return;
    };
    if path.exists() {
        let backup = path.with_extension("bak");
        if let Err(error) = std::fs::rename(&path, &backup) {
            tracing::warn!(%error, "could not move unreadable store aside");
        }
    }
}

fn load_preferences(app: &AppHandle) -> Result<Preferences, String> {
    let path = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join(STORE_FILE);
    if !path.exists() {
        return Ok(Preferences::default());
    }
    let raw = std::fs::read_to_string(&path).map_err(|error| error.to_string())?;
    let root: serde_json::Value = serde_json::from_str(&raw).map_err(|error| error.to_string())?;
    let value = root
        .get(STORE_KEY)
        .ok_or_else(|| format!("missing store key '{STORE_KEY}'"))?;
    let prefs: Preferences =
        serde_json::from_value(value.clone()).map_err(|error| error.to_string())?;
    prefs::validate_preferences(&prefs).map_err(|error| error.to_string())?;
    Ok(prefs)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "viby=info".into()),
        )
        .init();

    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| on_shortcut_event(app, shortcut, event.state))
                .build(),
        )
        .setup(|app| {
            let (prefs, load_error) = match load_preferences(app.handle()) {
                Ok(prefs) => (prefs, None),
                Err(error) => {
                    tracing::error!(%error, "could not load preferences");
                    quarantine_unreadable_store(app.handle());
                    (Preferences::default(), Some(error))
                }
            };
            // One clean slate before registering either shortcut:
            // `register_shortcut` itself only adds, so a stale registration
            // from a prior `setup` in the same process (tests, hot reload)
            // would otherwise linger.
            let _ = app.global_shortcut().unregister_all();
            let (active_shortcut, shortcut_error) = if load_error.is_none() {
                match register_shortcut(app.handle(), &prefs.shortcut) {
                    Ok(()) => (Some(prefs.shortcut.clone()), None),
                    Err(err) => {
                        tracing::warn!(%err, "could not register configured shortcut");
                        (None, Some(err.to_string()))
                    }
                }
            } else {
                (None, None)
            };
            let (active_discard_shortcut, discard_shortcut_error) = if load_error.is_none() {
                match register_shortcut(app.handle(), &prefs.discard_shortcut) {
                    Ok(()) => (Some(prefs.discard_shortcut.clone()), None),
                    Err(err) => {
                        tracing::warn!(%err, "could not register configured discard shortcut");
                        (None, Some(err.to_string()))
                    }
                }
            } else {
                (None, None)
            };
            app.manage(Mutex::new(PreferencesState {
                prefs,
                load_error,
                active_shortcut,
                shortcut_error,
                active_discard_shortcut,
                discard_shortcut_error,
            }));
            app.manage(flow::FlowController::new(app.handle().clone()));
            bar::prepare(app.handle());
            tray::build(app.handle())?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_preferences,
            save_preferences,
            list_microphones,
            start_dictation,
            stop_dictation,
            cancel_dictation,
            accept_dictation,
            get_flow_state,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
