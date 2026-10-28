//! Native microphone capture with bounded, disposable PCM buffers.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample, Stream, StreamConfig};
use thiserror::Error;

const WHISPER_SAMPLE_RATE: u32 = 16_000;
const MAX_CAPTURE_SECONDS: u32 = 120;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum AudioError {
    #[error("no input microphone is available")]
    NoDevice,
    #[error("the selected microphone is not available")]
    DeviceNotFound,
    #[error("the microphone configuration is unavailable")]
    Configuration,
    #[error("the microphone stream could not start")]
    Stream,
    #[error("the microphone stopped unexpectedly")]
    Callback,
    #[error("the microphone format is unsupported")]
    UnsupportedFormat,
    #[error("the capture exceeded the two-minute limit")]
    DurationExceeded,
}

struct CaptureBuffer {
    samples: VecDeque<f32>,
    max_samples: usize,
    total_samples: u64,
    level: f32,
    failed: bool,
    duration_exceeded: bool,
}

impl CaptureBuffer {
    fn new(max_samples: usize) -> Self {
        Self {
            samples: VecDeque::with_capacity(max_samples.min(WHISPER_SAMPLE_RATE as usize)),
            max_samples,
            total_samples: 0,
            level: 0.0,
            failed: false,
            duration_exceeded: false,
        }
    }

    fn push(&mut self, samples: &[f32], channels: usize) {
        let mono = downmix_interleaved(samples, channels);
        let rms = if mono.is_empty() {
            0.0
        } else {
            (mono.iter().map(|sample| sample * sample).sum::<f32>() / mono.len() as f32).sqrt()
        };
        self.level = rms.clamp(0.0, 1.0);
        self.total_samples = self.total_samples.saturating_add(mono.len() as u64);
        for sample in mono {
            if self.samples.len() == self.max_samples {
                self.samples.pop_front();
                self.duration_exceeded = true;
            }
            self.samples.push_back(sample);
        }
    }
    /// Single guard both read paths apply before touching the samples.
    fn ensure_usable(&self) -> Result<(), AudioError> {
        if self.failed {
            return Err(AudioError::Callback);
        }
        if self.duration_exceeded {
            return Err(AudioError::DurationExceeded);
        }
        Ok(())
    }

    /// Newest `max_input_samples` at the capture rate, plus the running total.
    fn snapshot_raw(&self, max_input_samples: usize) -> Result<(Vec<f32>, u64), AudioError> {
        self.ensure_usable()?;
        let skip = self.samples.len().saturating_sub(max_input_samples);
        let raw = self.samples.iter().skip(skip).copied().collect::<Vec<_>>();
        Ok((raw, self.total_samples))
    }

    /// Current input level without touching the samples. The waveform polls
    /// this far more often than a preview window, so it never clones.
    fn level_raw(&self) -> Result<f32, AudioError> {
        self.ensure_usable()?;
        Ok(self.level)
    }

    fn finish_raw(&self) -> Result<Vec<f32>, AudioError> {
        self.ensure_usable()?;
        Ok(self.samples.iter().copied().collect())
    }
}
pub struct AudioCapture {
    stream: Stream,
    buffer: Arc<Mutex<CaptureBuffer>>,
    sample_rate: u32,
}

pub struct AudioSnapshot {
    pub samples: Vec<f32>,
    pub total_samples: u64,
}

impl AudioCapture {
    pub fn start(device_name: Option<&str>) -> Result<Self, AudioError> {
        let host = cpal::default_host();
        let device = match device_name {
            Some(name) => host
                .input_devices()
                .map_err(|_| AudioError::NoDevice)?
                .find(|device| device.name().ok().as_deref() == Some(name))
                .ok_or(AudioError::DeviceNotFound)?,
            None => host.default_input_device().ok_or(AudioError::NoDevice)?,
        };
        let supported = device
            .default_input_config()
            .map_err(|_| AudioError::Configuration)?;
        let sample_rate = supported.sample_rate().0;
        let channels = supported.channels() as usize;
        if channels == 0 {
            return Err(AudioError::Configuration);
        }
        let config: StreamConfig = supported.clone().into();
        let buffer = Arc::new(Mutex::new(CaptureBuffer::new(
            sample_rate as usize * MAX_CAPTURE_SECONDS as usize,
        )));
        let callback_buffer = Arc::clone(&buffer);
        let error_buffer = Arc::clone(&buffer);
        let on_error = move |_error: cpal::StreamError| {
            if let Ok(mut buffer) = error_buffer.lock() {
                buffer.failed = true;
            }
        };

        let stream = match supported.sample_format() {
            SampleFormat::F32 => {
                build_stream::<f32, _>(&device, &config, channels, callback_buffer, on_error)
            }
            SampleFormat::I16 => {
                build_stream::<i16, _>(&device, &config, channels, callback_buffer, on_error)
            }
            SampleFormat::U16 => {
                build_stream::<u16, _>(&device, &config, channels, callback_buffer, on_error)
            }
            SampleFormat::I32 => {
                build_stream::<i32, _>(&device, &config, channels, callback_buffer, on_error)
            }
            SampleFormat::U32 => {
                build_stream::<u32, _>(&device, &config, channels, callback_buffer, on_error)
            }
            SampleFormat::F64 => {
                build_stream::<f64, _>(&device, &config, channels, callback_buffer, on_error)
            }
            _ => return Err(AudioError::UnsupportedFormat),
        }
        .map_err(|_| AudioError::Stream)?;
        stream.play().map_err(|_| AudioError::Stream)?;
        Ok(Self {
            stream,
            buffer,
            sample_rate,
        })
    }

    pub fn snapshot(&self, max_samples: usize) -> Result<AudioSnapshot, AudioError> {
        let (raw, total_samples) = {
            let buffer = self.buffer.lock().map_err(|_| AudioError::Callback)?;
            let max_input_samples = max_samples.saturating_mul(self.sample_rate as usize)
                / WHISPER_SAMPLE_RATE as usize;
            let (raw, total_input) = buffer.snapshot_raw(max_input_samples)?;
            let total_samples =
                total_input * WHISPER_SAMPLE_RATE as u64 / self.sample_rate as u64;
            (raw, total_samples)
        };
        let samples = resample_to_16khz(&raw, self.sample_rate);
        Ok(AudioSnapshot {
            samples,
            total_samples,
        })
    }

    /// Level for the bar's waveform (R2). Cheap enough for a display cadence.
    pub fn level(&self) -> Result<f32, AudioError> {
        let buffer = self.buffer.lock().map_err(|_| AudioError::Callback)?;
        buffer.level_raw()
    }
    pub fn finish(self) -> Result<Vec<f32>, AudioError> {
        let AudioCapture {
            stream,
            buffer,
            sample_rate,
        } = self;
        drop(stream);
        let samples = {
            let buffer = buffer.lock().map_err(|_| AudioError::Callback)?;
            buffer.finish_raw()?
        };
        Ok(resample_to_16khz(&samples, sample_rate))
    }

    pub fn discard(self) {
        drop(self);
    }
}

fn build_stream<T, E>(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: usize,
    buffer: Arc<Mutex<CaptureBuffer>>,
    on_error: E,
) -> Result<Stream, cpal::BuildStreamError>
where
    T: SizedSample + Sample,
    f32: FromSample<T>,
    E: FnMut(cpal::StreamError) + Send + 'static,
{
    device.build_input_stream(
        config,
        move |data: &[T], _| {
            if let Ok(mut buffer) = buffer.lock() {
                let samples: Vec<f32> = data
                    .iter()
                    .map(|sample| sample.to_sample::<f32>())
                    .collect();
                buffer.push(&samples, channels);
            }
        },
        on_error,
        None,
    )
}

pub(crate) fn downmix_interleaved(samples: &[f32], channels: usize) -> Vec<f32> {
    if channels == 0 {
        return Vec::new();
    }
    samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect()
}

pub(crate) fn resample_to_16khz(samples: &[f32], input_rate: u32) -> Vec<f32> {
    if samples.is_empty() || input_rate == 0 {
        return Vec::new();
    }
    if input_rate == WHISPER_SAMPLE_RATE {
        return samples.to_vec();
    }
    let output_len =
        (samples.len() as u64 * WHISPER_SAMPLE_RATE as u64 / input_rate as u64) as usize;
    let ratio = WHISPER_SAMPLE_RATE as f64 / input_rate as f64;
    let cutoff = ratio.min(1.0) * 0.94;
    let half_taps = 16_i32;
    (0..output_len)
        .map(|index| {
            let source = index as f64 / ratio;
            let center = source.floor() as i32;
            let start = center - half_taps + 1;
            let mut value = 0.0_f64;
            let mut weight_sum = 0.0_f64;
            for tap in 0..(half_taps * 2) {
                let source_index = start + tap;
                if source_index < 0 || source_index >= samples.len() as i32 {
                    continue;
                }
                let distance = source_index as f64 - source;
                let window =
                    0.5 * (1.0 + (std::f64::consts::PI * distance / half_taps as f64).cos());
                let sinc = if distance.abs() < f64::EPSILON {
                    1.0
                } else {
                    let argument = std::f64::consts::PI * distance * cutoff;
                    argument.sin() / (std::f64::consts::PI * distance)
                };
                let weight = sinc * window;
                value += samples[source_index as usize] as f64 * weight;
                weight_sum += weight;
            }
            if weight_sum.abs() < f64::EPSILON {
                0.0
            } else {
                (value / weight_sum) as f32
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_averages_interleaved_channels() {
        let mono = downmix_interleaved(&[-1.0, 1.0, -0.5, 0.5], 2);
        assert_eq!(mono, vec![0.0, 0.0]);
    }
    #[test]
    fn capture_buffer_reports_duration_overflow() {
        let mut buffer = CaptureBuffer::new(2);
        buffer.push(&[0.0, 0.0], 1);
        assert!(!buffer.duration_exceeded);
        buffer.push(&[0.0], 1);
        assert!(buffer.duration_exceeded);
    }

    #[test]
    fn snapshot_and_finish_report_duration_overflow() {
        let mut buffer = CaptureBuffer::new(2);
        buffer.push(&[0.0, 0.0], 1);
        assert!(buffer.snapshot_raw(2).is_ok());
        assert!(buffer.finish_raw().is_ok());
        buffer.push(&[0.0], 1);
        assert_eq!(
            buffer.snapshot_raw(2).unwrap_err(),
            AudioError::DurationExceeded
        );
        assert_eq!(buffer.finish_raw().unwrap_err(), AudioError::DurationExceeded);
    }

    #[test]
    fn snapshot_and_finish_report_stream_failure() {
        let mut buffer = CaptureBuffer::new(2);
        buffer.push(&[0.0], 1);
        buffer.failed = true;
        assert_eq!(buffer.snapshot_raw(2).unwrap_err(), AudioError::Callback);
        assert_eq!(buffer.finish_raw().unwrap_err(), AudioError::Callback);
    }

    #[test]
    fn level_tracks_rms_and_reports_stream_failure() {
        let mut buffer = CaptureBuffer::new(4);
        assert_eq!(buffer.level_raw(), Ok(0.0));
        // RMS of a constant 0.5 signal is 0.5; the waveform must follow the
        // real level instead of a decorative constant.
        buffer.push(&[0.5, 0.5], 1);
        let level = buffer.level_raw().expect("usable buffer");
        assert!((level - 0.5).abs() < 1e-6, "level was {level}");
        buffer.failed = true;
        assert_eq!(buffer.level_raw().unwrap_err(), AudioError::Callback);
    }
    #[test]
    fn downmix_preserves_asymmetric_mono_signal() {
        let mono = downmix_interleaved(&[0.8, -0.2, -0.4, 0.6], 2);
        assert!((mono[0] - 0.3).abs() < f32::EPSILON);
        assert!((mono[1] - 0.1).abs() < f32::EPSILON);
    }

    #[test]
    fn resampling_preserves_in_band_tone() {
        let input_rate = 48_000;
        let input: Vec<f32> = (0..4_800)
            .map(|index| {
                (2.0 * std::f32::consts::PI * 1_000.0 * index as f32 / input_rate as f32).sin()
            })
            .collect();
        let output = resample_to_16khz(&input, input_rate);
        let rms =
            (output.iter().map(|sample| sample * sample).sum::<f32>() / output.len() as f32).sqrt();
        assert!(rms > 0.5, "in-band RMS was attenuated: {rms}");
    }

    #[test]
    fn resampling_produces_whisper_rate() {
        let input = [1.0, 1.0, 1.0, 1.0];
        let output = resample_to_16khz(&input, 32_000);
        assert_eq!(output.len(), 2);
        assert!((output[0] - 1.0).abs() < 0.1);
        assert!((output[1] - 1.0).abs() < 0.1);
    }
    #[test]
    fn resampling_attenuates_above_whisper_nyquist() {
        let input_rate = 48_000;
        let input: Vec<f32> = (0..4_800)
            .map(|index| {
                (2.0 * std::f32::consts::PI * 12_000.0 * index as f32 / input_rate as f32).sin()
            })
            .collect();
        let output = resample_to_16khz(&input, input_rate);
        let rms =
            (output.iter().map(|sample| sample * sample).sum::<f32>() / output.len() as f32).sqrt();
        assert!(rms < 0.4, "ultrasonic RMS was not attenuated: {rms}");
    }
}
