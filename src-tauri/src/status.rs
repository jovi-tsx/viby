//! Microphone state exposed to the interface. Detection is local only: the
//! microphone is a WASAPI device. The engine is the user's and is checked per
//! take, never polled from here (R3).

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
