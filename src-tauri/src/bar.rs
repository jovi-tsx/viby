//! The bottom-edge dock window: where it sits and how it appears.
//!
//! Two invariants live here. The dock is anchored to the bottom edge of the
//! work area at the persisted horizontal position (D9), and showing it never
//! activates it — the destination window captured at recording start must keep
//! focus (R4, UI Contract). A click still activates the dock normally, so its
//! controls remain reachable after the user explicitly picks Viby.

use std::sync::atomic::{AtomicU64, Ordering};

use tauri::{AppHandle, Manager};

/// Distance from the work-area edge, in logical pixels ("safe edge inset").
const INSET: f64 = 24.0;

/// Counts how many times the dock has been shown. A deferred hide carries the
/// generation it was scheduled for, so it can never take down a dock that a
/// newer flow put on screen in the meantime.
static GENERATION: AtomicU64 = AtomicU64::new(0);

pub fn generation() -> u64 {
    GENERATION.load(Ordering::Acquire)
}

/// Hides the dock only if nothing was shown after `generation`.
pub fn hide_stale(app: &AppHandle, generation: u64) {
    if GENERATION.load(Ordering::Acquire) == generation {
        hide(app);
    }
}

/// Work area in physical pixels: the desktop minus the taskbar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct WorkArea {
    pub(crate) left: i32,
    pub(crate) top: i32,
    pub(crate) right: i32,
    pub(crate) bottom: i32,
}

/// Top-left corner for a capsule of `width` x `height` at `position`.
///
/// The vertical anchor never depends on the position (D9): only the horizontal
/// placement changes. A capsule wider or taller than the work area is clamped
/// to the work-area origin instead of being pushed off-screen.
pub(crate) fn origin(
    work: WorkArea,
    width: i32,
    height: i32,
    inset: i32,
    position: &str,
) -> (i32, i32) {
    let x = match position {
        "left" => work.left + inset,
        "right" => work.right - width - inset,
        // Unknown values behave like the default (D9: Bottom center).
        _ => work.left + (work.right - work.left - width) / 2,
    };
    let y = work.bottom - height - inset;
    (
        x.clamp(work.left, (work.right - width).max(work.left)),
        y.clamp(work.top, (work.bottom - height).max(work.top)),
    )
}

/// Places the dock and shows it without stealing focus.
pub fn show(app: &AppHandle, position: &str) {
    GENERATION.fetch_add(1, Ordering::AcqRel);
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::HWND;

        let size = window.outer_size().ok();
        let scale = window.scale_factor().unwrap_or(1.0);
        if let (Some(size), Some(work), Ok(handle)) = (size, work_area(), window.hwnd()) {
            let (x, y) = origin(
                work,
                size.width as i32,
                size.height as i32,
                (INSET * scale).round() as i32,
                position,
            );
            if place(handle.0 as isize, x, y, size.width as i32, size.height as i32) {
                remove_taskbar_button(HWND(handle.0 as *mut _));
                return;
            }
        }
    }
    #[cfg(not(windows))]
    let _ = position;
    let _ = window.show();
}

/// Hidden the same way it was shown. Tauri's `show`/`hide` pair diffs against
/// a cached window-flag set, so a `hide` after a raw non-activating show is a
/// no-op and the capsule would stay on screen forever. Both directions go
/// through Win32 so the two views of visibility can never disagree.
///
/// The window is first parked off the virtual screen: Chromium's compositor
/// presents one last damaged frame as the visibility changes, and when the
/// window simply disappears that frame lands on the desktop as a brief white
/// square. Painted offscreen, it is invisible, and `show` moves the window
/// back in the same call that displays it.
pub fn hide(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    #[cfg(windows)]
    if let Ok(handle) = window.hwnd() {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{
            SetWindowPos, ShowWindow, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER, SW_HIDE,
        };

        let hwnd = HWND(handle.0 as *mut _);
        unsafe {
            let _ = SetWindowPos(
                hwnd,
                None,
                -32_000,
                -32_000,
                0,
                0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
            );
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
        return;
    }
    let _ = window.hide();
}

/// Topmost, positioned, visible, and never activated — one call, so the
/// capsule cannot be observed at a stale position before it moves.
#[cfg(windows)]
fn place(hwnd: isize, x: i32, y: i32, width: i32, height: i32) -> bool {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_SHOWWINDOW,
    };

    unsafe {
        SetWindowPos(
            HWND(hwnd as *mut _),
            Some(HWND_TOPMOST),
            x,
            y,
            width,
            height,
            SWP_NOACTIVATE | SWP_SHOWWINDOW,
        )
    }
    .is_ok()
}

/// Strips every frame style from the dock window once, at startup, makes the
/// webview's controller background transparent, and removes its taskbar
/// button.
///
/// Sources of the one-frame white square at the dock's bottom-right corner,
/// all eliminated here:
///
/// 1. Tauri leaves `WS_DLGFRAME | WS_BORDER | WS_EX_WINDOWEDGE` on the window
///    even with `decorations: false`, giving DWM frame pixels to paint for one
///    frame at show/hide transitions. A pure popup window has no frame.
/// 2. The WebView2 controller's default background is opaque white whenever no
///    background color is configured, and that frame — not the page — is what
///    the compositor shows while the webview's visibility changes. Setting it
///    fully transparent leaves nothing white to flash.
/// 3. An unowned visible window gets a taskbar button, and the auto-hidden
///    taskbar flashes that button's white tile for one frame as it appears and
///    disappears — flush under the dock's bottom-right corner on a centred
///    taskbar. `ITaskbarList::DeleteTab` removes the button outright, at
///    startup and after every show in case the shell re-adds it. The window
///    keeps `WS_EX_APPWINDOW` because that is the only extended style
///    combination in which UI Automation — and therefore screen readers — can
///    see the dock at all: `WS_EX_TOOLWINDOW`, an owner window, and a plain
///    unowned popup were all tried and all drop it out of the ControlView.
/// 4. DWM runs its own transition animation on the surface at show/hide, and
///    Windows 11 rounds every window's corners by default. Both can present
///    the not-yet-composited corner of the transparent surface as a sharp
///    white square for one frame, flush to the window's bottom-right corner.
///    The dock has no frame and no rounded corners, so neither animation has
///    anything to paint.
#[cfg(windows)]
pub fn prepare(app: &AppHandle) {
    use windows::core::BOOL;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWCP_DONOTROUND, DWMWA_TRANSITIONS_FORCEDISABLED,
        DWMWA_WINDOW_CORNER_PREFERENCE, DWM_WINDOW_CORNER_PREFERENCE,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowLongPtrW, SetWindowPos, GWL_EXSTYLE, GWL_STYLE, SWP_FRAMECHANGED,
        SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, WS_CLIPSIBLINGS,
        WS_EX_APPWINDOW, WS_EX_TOPMOST, WS_POPUP,
    };

    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let _ = window.set_background_color(Some(tauri::window::Color(0, 0, 0, 0)));
    let Ok(handle) = window.hwnd() else {
        return;
    };
    let hwnd = HWND(handle.0 as *mut _);
    unsafe {
        SetWindowLongPtrW(hwnd, GWL_STYLE, (WS_POPUP | WS_CLIPSIBLINGS).0 as isize);
        SetWindowLongPtrW(
            hwnd,
            GWL_EXSTYLE,
            (WS_EX_TOPMOST | WS_EX_APPWINDOW).0 as isize,
        );
        let no_transitions = BOOL(1);
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_TRANSITIONS_FORCEDISABLED,
            &no_transitions as *const BOOL as *const _,
            size_of::<BOOL>() as u32,
        );
        let no_rounding = DWMWCP_DONOTROUND;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &no_rounding as *const DWM_WINDOW_CORNER_PREFERENCE as *const _,
            size_of::<DWM_WINDOW_CORNER_PREFERENCE>() as u32,
        );
        remove_taskbar_button(hwnd);
        let _ = SetWindowPos(
            hwnd,
            None,
            0,
            0,
            0,
            0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
        );
    }
}

/// Deletes the dock's taskbar button. Safe to call on any thread and safe to
/// repeat; COM initialization failures only mean the button stays.
#[cfg(windows)]
fn remove_taskbar_button(hwnd: windows::Win32::Foundation::HWND) {
    use windows::core::GUID;
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL};
    use windows::Win32::UI::Shell::ITaskbarList;

    // The crate does not export the constant; this is the published CLSID.
    const CLSID_TASKBARLIST: GUID =
        GUID::from_u128(0x56fdf344_fd6d_11d0_958a_006097c9a090u128);

    unsafe {
        let _ = CoInitializeEx(None, windows::Win32::System::Com::COINIT_APARTMENTTHREADED);
        if let Ok(list) = CoCreateInstance::<_, ITaskbarList>(&CLSID_TASKBARLIST, None, CLSCTX_ALL)
        {
            let _ = list.HrInit();
            let _ = list.DeleteTab(hwnd);
        }
    }
}

#[cfg(not(windows))]
pub fn prepare(_app: &AppHandle) {}

/// ponytail: primary-monitor work area. Per-monitor placement matters only
/// once the capsule must follow the focused window across displays.
#[cfg(windows)]
fn work_area() -> Option<WorkArea> {
    use windows::Win32::Foundation::RECT;
    use windows::Win32::UI::WindowsAndMessaging::{
        SystemParametersInfoW, SPI_GETWORKAREA, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    };

    let mut rect = RECT::default();
    unsafe {
        SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some(&mut rect as *mut RECT as *mut _),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    }
    .ok()?;
    if rect.right <= rect.left || rect.bottom <= rect.top {
        return None;
    }
    Some(WorkArea {
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORK: WorkArea = WorkArea {
        left: 0,
        top: 0,
        right: 1920,
        bottom: 1032, // 1080 minus a 48 px taskbar
    };

    #[test]
    fn center_is_the_default_and_horizontally_centred() {
        let (x, y) = origin(WORK, 460, 76, 24, "center");
        assert_eq!(x, (1920 - 460) / 2);
        assert_eq!(y, 1032 - 76 - 24);
        // An unrecognised persisted value must not move the capsule off the
        // approved set; it renders as the default position (D9).
        assert_eq!(origin(WORK, 460, 76, 24, "bottom-middle"), (x, y));
    }

    #[test]
    fn left_and_right_keep_the_inset_and_the_bottom_anchor() {
        let (left_x, left_y) = origin(WORK, 460, 76, 24, "left");
        let (right_x, right_y) = origin(WORK, 460, 76, 24, "right");
        assert_eq!(left_x, 24);
        assert_eq!(right_x, 1920 - 460 - 24);
        assert_eq!(left_y, right_y, "the vertical anchor never changes (D9)");
        assert_eq!(left_y, 1032 - 76 - 24);
    }

    #[test]
    fn work_area_offset_is_respected() {
        let work = WorkArea {
            left: -1920,
            top: 100,
            right: 0,
            bottom: 1000,
        };
        assert_eq!(origin(work, 400, 80, 20, "left"), (-1900, 900));
        assert_eq!(origin(work, 400, 80, 20, "right"), (-420, 900));
    }

    #[test]
    fn an_oversized_capsule_stays_inside_the_work_area() {
        let (x, y) = origin(WORK, 4000, 2000, 24, "right");
        assert_eq!((x, y), (WORK.left, WORK.top));
    }
}
