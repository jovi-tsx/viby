//! Tray icon and its menu. The contract surface is exactly "Options…" and
//! "Close" (D6); `TRAY_ITEMS` is the single source the smoke test inspects.

use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager};

use crate::bar;
use crate::flow;

/// The Options canvas, matching `--canvas` in `src/styles.css`.
///
/// A window built without one gets WebView2's default opaque white, which is
/// what the compositor shows while the window is created and again while it is
/// destroyed. On Windows the alpha channel is ignored for the window layer, so
/// the near-black reaches it either way; the webview layer honours the colour
/// only when alpha is zero, and a transparent webview over a near-black window
/// composites to the same near-black with no white frame at either end.
const OPTIONS_CANVAS: tauri::window::Color = tauri::window::Color(0x09, 0x09, 0x0b, 0);

/// (id, label) pairs, in menu order. Exactly two, per the contract.
pub const TRAY_ITEMS: [(&str, &str); 2] = [("options", "Options…"), ("close", "Close")];

pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let mut menu = MenuBuilder::new(app);
    for (id, label) in TRAY_ITEMS {
        menu = menu.item(&MenuItemBuilder::with_id(id, label).build(app)?);
    }

    TrayIconBuilder::new()
        .icon(app.default_window_icon().unwrap().clone())
        .tooltip("Viby")
        .menu(&menu.build()?)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "options" => open_options(app),
            "close" => close(app),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn open_options(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("options") {
        let _ = window.set_focus();
        return;
    }
    let _ = tauri::WebviewWindowBuilder::new(
        app,
        "options",
        tauri::WebviewUrl::App("options.html".into()),
    )
    .title("Viby — Options")
    .inner_size(560.0, 720.0)
    .min_inner_size(480.0, 480.0)
    .background_color(OPTIONS_CANVAS)
    .build();
}

/// Exits, but never before every app-owned window has left the screen.
///
/// `AppHandle::exit` destroys the windows outright. That is a different
/// teardown from `bar::hide`, which parks the dock off the virtual screen so
/// the compositor's last damaged frame lands nowhere the user can see it —
/// destruction skips the park, and the surface's final frame is presented onto
/// the desktop instead.
///
/// The takedown therefore runs on both decisions, not only on the one that
/// cancels a flow. `ExitClean` is reachable with the dock fully visible: after a
/// delivered result the flow reads `Idle` for the whole outcome linger, a
/// recoverable failure reads `Error` for the error linger, and a refused
/// activation shows the dock without changing the state at all. Routing the
/// takedown through `cancel` alone left exactly those three windows uncovered.
fn close(app: &AppHandle) {
    let controller = app.state::<flow::FlowController>();
    controller.begin_close();
    // Before the wait, not after: the human asked to close, and a dock that
    // lingers for the length of a cancellation reads as a stuck application.
    bar::hide(app);
    if flow::on_close_requested(controller.current_state()) == flow::CloseDecision::CancelAndExit {
        controller.cancel_and_wait();
    }
    // Options is an ordinary decorated window, so Tauri's own hide is in sync
    // with it and takes it down the way it was put up.
    if let Some(window) = app.get_webview_window("options") {
        let _ = window.hide();
    }
    app.exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tray_menu_is_exactly_options_and_close() {
        assert_eq!(TRAY_ITEMS.len(), 2);
        assert_eq!(TRAY_ITEMS[0], ("options", "Options…"));
        assert_eq!(TRAY_ITEMS[1], ("close", "Close"));
        assert_ne!(TRAY_ITEMS[0].0, TRAY_ITEMS[1].0);
    }
}
