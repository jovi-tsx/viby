//! Dictation flow lifecycle, capture coordination, and newest-preview scheduling.

use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{self, Receiver, Sender, TryRecvError},
    Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::audio::AudioCapture;
use crate::bar;
use crate::engine::{self, Engine, EngineConfig, EngineError, MIN_AUDIO_SAMPLES};
use crate::prefs::InterfacePrefs;

const PREVIEW_WINDOW_SAMPLES: usize = 48_000;
const PREVIEW_STEP_SAMPLES: usize = 6_400;
const PREVIEW_INTERVAL: Duration = Duration::from_millis(400);
/// Waveform cadence. The preview interval is far too coarse for a level the
/// user reads as "the microphone is hearing me" (R2), so the level is polled
/// on its own clock and never clones the capture buffer.
const LEVEL_INTERVAL: Duration = Duration::from_millis(60);
/// How long a delivered result stays on screen before the dock returns to the
/// tray. A cancellation is not on this clock: it leaves at once.
const OUTCOME_LINGER: Duration = Duration::from_millis(1_400);
/// A recoverable failure needs longer, because it carries an instruction (R6).
const ERROR_LINGER: Duration = Duration::from_secs(6);
/// A refused activation only has to be noticed.
const NOTICE_LINGER: Duration = Duration::from_millis(1_600);
const CLOSE_WAIT_TIMEOUT: Duration = Duration::from_secs(5);
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FlowState {
    /// No capture, transcription, or insertion in progress.
    Idle,
    /// The activation was accepted and the microphone is opening: the first
    /// ordered signal a shortcut press produces.
    Loading,
    /// Audio is being captured while preview windows go to the engine.
    Recording,
    /// Capture ended and the user's engine is transcribing the take.
    Processing,
    /// The transcript is finished and waiting for the user to accept or
    /// discard it. Only reachable with `confirm_before_insert` on.
    Confirming,
    /// A recoverable local failure ended the flow.
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseDecision {
    /// Nothing pending: discard nothing, exit immediately.
    ExitClean,
    /// Cancel the active flow, discard transient data, then exit.
    CancelAndExit,
}

/// Whether the process may exit, and what must be discarded first.
pub fn on_close_requested(state: FlowState) -> CloseDecision {
    match state {
        FlowState::Idle | FlowState::Error => CloseDecision::ExitClean,
        // A pending confirmation still holds a transcript that must be dropped
        // without being inserted (S9).
        FlowState::Loading
        | FlowState::Recording
        | FlowState::Processing
        | FlowState::Confirming => CloseDecision::CancelAndExit,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StartDecision {
    /// Nothing is pending: open the microphone.
    Begin,
    /// Something must be resolved before a new take; tell the user which.
    Busy(&'static str),
    /// A flow is already live, or the app is exiting: the press means nothing.
    Ignore,
}

pub(crate) const BUSY_DISCARDING: &str = "Just a moment — Viby is discarding the last take.";
pub(crate) const BUSY_CONFIRMING: &str = "Accept or discard the last take first.";
pub(crate) const NO_ENGINE: &str = "No speech engine is set — add your engine's address in Viby Options.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DictationPressDecision {
    /// Nothing is pending: open the microphone.
    Begin,
    /// Press-once, second press: end the take (D16).
    End,
    /// A transcript waits: this press resolves it rather than starting a new
    /// take (D16, R4).
    Accept,
    /// Something must be resolved before a new take; tell the user which.
    Busy(&'static str),
    /// The press means nothing right now.
    Ignore,
}

/// What a press of the *dictation* shortcut means right now (D16). Hold mode
/// and press-once share every branch except the live-capture one: hold
/// ignores a second press because release is what ends the take; press-once
/// treats the second press as that release.
pub(crate) fn dictation_press_decision(
    state: FlowState,
    cancel_requested: bool,
    closing: bool,
    press_once: bool,
) -> DictationPressDecision {
    if closing {
        return DictationPressDecision::Ignore;
    }
    match state {
        // A transcript only waits when confirmation is on, which is exactly
        // when D16 also switches activation to press-once — but this branch
        // reads the state, not the preference, so it holds either way.
        FlowState::Confirming => DictationPressDecision::Accept,
        FlowState::Idle | FlowState::Error => DictationPressDecision::Begin,
        _ if cancel_requested => DictationPressDecision::Busy(BUSY_DISCARDING),
        _ if press_once => DictationPressDecision::End,
        _ => DictationPressDecision::Ignore,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DiscardPressDecision {
    /// A transcript waits, or the engine is still processing the take:
    /// discard it (R4).
    Discard,
    /// The discard shortcut does nothing anywhere else (R7).
    Ignore,
}

/// The discard shortcut is the keyboard path out of the two states that wait
/// on something other than the user's voice: a transcript awaiting a decision
/// and an engine that has not answered yet. A slow engine never holds someone
/// without a pointing device until the timeout (R4, D23).
pub(crate) fn discard_press_decision(state: FlowState) -> DiscardPressDecision {
    match state {
        FlowState::Confirming | FlowState::Processing => DiscardPressDecision::Discard,
        _ => DiscardPressDecision::Ignore,
    }
}

/// What a shortcut press means right now.
///
/// Cancellation returns the dock instantly but the worker still has to discard
/// buffers and abandon engine requests. A press landing in that window would
/// otherwise vanish with no explanation, which reads as a dropped shortcut. A
/// pending confirmation is refused for the same reason, and never silently
/// throws away a transcript the user has not decided on.
pub(crate) fn start_decision(
    state: FlowState,
    cancel_requested: bool,
    closing: bool,
) -> StartDecision {
    if closing {
        return StartDecision::Ignore;
    }
    match state {
        FlowState::Idle | FlowState::Error => StartDecision::Begin,
        FlowState::Confirming => StartDecision::Busy(BUSY_CONFIRMING),
        _ if cancel_requested => StartDecision::Busy(BUSY_DISCARDING),
        _ => StartDecision::Ignore,
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum FlowEvent {
    State {
        state: FlowState,
        message: Option<String>,
    },
    Level {
        level: f32,
    },
    Preview {
        sequence: u64,
        text: String,
        provisional: bool,
    },
    Final {
        text: String,
    },
    /// Something the user tried was refused; no state changed.
    Notice {
        text: String,
    },
}

#[derive(Clone)]
pub struct FlowController {
    app: AppHandle,
    state: Arc<Mutex<FlowState>>,
    commands: std::sync::mpsc::Sender<Command>,
    cancel_requested: Arc<AtomicBool>,
    stop_requested: Arc<AtomicBool>,
    closing: Arc<AtomicBool>,
}

enum Command {
    Start {
        engine: EngineConfig,
        microphone: Option<String>,
        show_preview: bool,
        confirm_before_insert: bool,
    },
    Stop,
    Cancel,
}

impl FlowController {
    pub fn new(app: AppHandle) -> Self {
        let (commands, receiver) = mpsc::channel();
        let state = Arc::new(Mutex::new(FlowState::Idle));
        let cancel_requested = Arc::new(AtomicBool::new(false));
        let stop_requested = Arc::new(AtomicBool::new(false));
        let closing = Arc::new(AtomicBool::new(false));
        let worker_state = Arc::clone(&state);
        let worker_cancel = Arc::clone(&cancel_requested);
        let worker_stop = Arc::clone(&stop_requested);
        let worker_app = app.clone();
        let engine = Arc::new(Engine::system());
        thread::spawn(move || {
            run_worker(
                worker_app,
                receiver,
                worker_state,
                worker_cancel,
                worker_stop,
                engine,
            )
        });
        Self {
            app,
            state,
            commands,
            cancel_requested,
            stop_requested,
            closing,
        }
    }

    pub fn current_state(&self) -> FlowState {
        self.state
            .lock()
            .map(|state| *state)
            .unwrap_or(FlowState::Idle)
    }

    pub fn start(
        &self,
        engine: EngineConfig,
        microphone: Option<String>,
        interface: InterfacePrefs,
        confirm_before_insert: bool,
    ) -> bool {
        let closing = self.closing.load(Ordering::Acquire);
        let mut state = match self.state.lock() {
            Ok(state) => state,
            Err(_) => return false,
        };
        match start_decision(
            *state,
            self.cancel_requested.load(Ordering::Acquire),
            closing,
        ) {
            StartDecision::Begin => {}
            StartDecision::Ignore => return false,
            StartDecision::Busy(reason) => {
                drop(state);
                // Discarding the last take, or waiting on a confirmation, can
                // outlive the keystroke that asked for a new one: say which
                // instead of dropping the press silently.
                self.notice(&interface.bar_position, reason);
                return false;
            }
        }
        if !engine.is_configured() {
            // Refused before the microphone opens: there is nowhere to send
            // the take (R3, S3). Viby never opens Options on its own to ask.
            drop(state);
            self.notice(&interface.bar_position, NO_ENGINE);
            return false;
        }
        self.cancel_requested.store(false, Ordering::Release);
        self.stop_requested.store(false, Ordering::Release);
        *state = FlowState::Loading;
        drop(state);
        tracing::info!(state = ?FlowState::Loading, "flow state");
        emit(
            &self.app,
            FlowEvent::State {
                state: FlowState::Loading,
                message: None,
            },
        );
        // The capsule is placed and shown here, at the first ordered
        // activation signal, so the human sees Viby react to the shortcut
        // before the microphone opens. It is never activated: the
        // destination window keeps focus for M4 insertion.
        bar::show(&self.app, &interface.bar_position);
        self.commands
            .send(Command::Start {
                engine,
                microphone,
                show_preview: interface.show_preview,
                confirm_before_insert,
            })
            .is_ok()
    }

    /// Entry point for every press of the *dictation* shortcut (D16). Hold
    /// mode's press was always just "begin"; press-once overloads the same
    /// key with "begin", "end", and "accept the waiting transcript"
    /// depending on where the flow already is, so the dispatch lives here
    /// rather than in the two OS-level callers (the shortcut handler and any
    /// harness driving it directly).
    pub fn dictation_pressed(
        &self,
        engine: EngineConfig,
        microphone: Option<String>,
        interface: InterfacePrefs,
        confirm_before_insert: bool,
    ) {
        let state = self.current_state();
        let cancel_requested = self.cancel_requested.load(Ordering::Acquire);
        let closing = self.closing.load(Ordering::Acquire);
        match dictation_press_decision(state, cancel_requested, closing, confirm_before_insert) {
            DictationPressDecision::Begin => {
                self.start(engine, microphone, interface, confirm_before_insert);
            }
            DictationPressDecision::End => self.stop(),
            DictationPressDecision::Accept => self.accept(),
            DictationPressDecision::Busy(reason) => self.notice(&interface.bar_position, reason),
            DictationPressDecision::Ignore => {}
        }
    }

    /// Entry point for every press of the *discard* shortcut (D16). It acts
    /// only while a transcript waits or the engine is processing (R4, R7), so
    /// it never cancels a live capture the way the dock's own discard
    /// control does.
    pub fn discard_pressed(&self) {
        if discard_press_decision(self.current_state()) == DiscardPressDecision::Discard {
            self.cancel();
        }
    }

    pub fn stop(&self) {
        // The flag is set under the state lock so the worker's Recording
        // transition cannot interleave with a release.
        {
            let state = match self.state.lock() {
                Ok(state) => state,
                Err(_) => return,
            };
            if !matches!(
                *state,
                FlowState::Loading | FlowState::Recording | FlowState::Processing
            ) {
                return;
            }
            if matches!(*state, FlowState::Loading | FlowState::Recording) {
                self.stop_requested.store(true, Ordering::Release);
            }
        }
        let _ = self.commands.send(Command::Stop);
    }

    /// Arms cancellation and takes the dock down immediately. The worker still
    /// has to discard buffers and abandon engine requests, and the user must
    /// not wait for that to see their own decision land; an activation that
    /// arrives before the teardown finishes gets the busy notice.
    ///
    /// A pending confirmation has no worker left to notify — the session ended
    /// when the transcript was published — so it is resolved here.
    pub fn cancel(&self) {
        {
            let state = match self.state.lock() {
                Ok(state) => state,
                Err(_) => return,
            };
            if matches!(*state, FlowState::Idle | FlowState::Error) {
                return;
            }
            if matches!(*state, FlowState::Confirming) {
                drop(state);
                self.resolve_confirmation(false);
                return;
            }
            self.cancel_requested.store(true, Ordering::Release);
        }
        bar::hide(&self.app);
        let _ = self.commands.send(Command::Cancel);
    }

    /// Accepts a held transcript. M4's insertion attaches here: this is the
    /// only point at which a confirmed transcript may reach the destination.
    pub fn accept(&self) {
        self.resolve_confirmation(true);
    }

    fn resolve_confirmation(&self, accepted: bool) {
        {
            let mut state = match self.state.lock() {
                Ok(state) => state,
                Err(_) => return,
            };
            if !matches!(*state, FlowState::Confirming) {
                return;
            }
            *state = FlowState::Idle;
        }
        // Counts and outcomes only, never recognized text (R5).
        tracing::info!(accepted, "flow confirmation");
        tracing::info!(state = ?FlowState::Idle, "flow state");
        emit(
            &self.app,
            FlowEvent::State {
                state: FlowState::Idle,
                message: None,
            },
        );
        bar::hide(&self.app);
    }

    fn notice(&self, position: &str, text: &str) {
        // Refusals are part of the flow's observable behaviour, so they leave a
        // trace like the states do. The text is a fixed string, never content.
        tracing::info!("flow busy");
        bar::show(&self.app, position);
        emit(
            &self.app,
            FlowEvent::Notice {
                text: text.to_string(),
            },
        );
        hide_dock_after(&self.app, NOTICE_LINGER);
    }

    pub fn begin_close(&self) {
        self.closing.store(true, Ordering::Release);
    }

    pub fn cancel_and_wait(&self) {
        self.begin_close();
        self.cancel();
        let deadline = Instant::now() + CLOSE_WAIT_TIMEOUT;
        while matches!(
            self.current_state(),
            FlowState::Loading | FlowState::Recording | FlowState::Processing
        ) && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(10));
        }
        if matches!(
            self.current_state(),
            FlowState::Loading | FlowState::Recording | FlowState::Processing
        ) {
            tracing::warn!("close cancellation exceeded wait limit");
        }
    }
}

struct SessionConfig {
    engine: EngineConfig,
    microphone: Option<String>,
    show_preview: bool,
    confirm_before_insert: bool,
}

fn run_worker(
    app: AppHandle,
    commands: Receiver<Command>,
    state: Arc<Mutex<FlowState>>,
    cancel_requested: Arc<AtomicBool>,
    stop_requested: Arc<AtomicBool>,
    engine: Arc<Engine>,
) {
    while let Ok(command) = commands.recv() {
        let Command::Start {
            engine: engine_config,
            microphone,
            show_preview,
            confirm_before_insert,
        } = command
        else {
            continue;
        };
        run_session(
            &app,
            &commands,
            &state,
            &cancel_requested,
            &stop_requested,
            &engine,
            SessionConfig {
                engine: engine_config,
                microphone,
                show_preview,
                confirm_before_insert,
            },
        );
    }
}

/// What the engine said, delivered back to the session loop.
enum EngineEvent {
    Check(Result<(), EngineError>),
    Preview {
        sequence: u64,
        result: Result<String, EngineError>,
    },
    Final(Result<String, EngineError>),
}

/// The session's requests in flight. Dropping it aborts every one, which
/// closes its connection and drops its audio: no request outlives the take
/// that made it, whichever way the session ends (R3, R5, S9).
#[derive(Default)]
struct EngineRequests {
    check: Option<tauri::async_runtime::JoinHandle<()>>,
    preview: Option<tauri::async_runtime::JoinHandle<()>>,
    final_request: Option<tauri::async_runtime::JoinHandle<()>>,
}

impl EngineRequests {
    fn abort(slot: &mut Option<tauri::async_runtime::JoinHandle<()>>) {
        if let Some(handle) = slot.take() {
            handle.abort();
        }
    }
}

impl Drop for EngineRequests {
    fn drop(&mut self) {
        Self::abort(&mut self.check);
        Self::abort(&mut self.preview);
        Self::abort(&mut self.final_request);
    }
}

fn spawn_request<F>(events: &Sender<EngineEvent>, request: F) -> tauri::async_runtime::JoinHandle<()>
where
    F: std::future::Future<Output = EngineEvent> + Send + 'static,
{
    let events = events.clone();
    tauri::async_runtime::spawn(async move {
        let _ = events.send(request.await);
    })
}

/// Which request the session sends next. The final never waits for a
/// preview: once the take ends it goes out at once and any preview still in
/// flight is abandoned (R3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Dispatch {
    Nothing,
    Final,
    Preview,
}

pub(crate) fn next_dispatch(
    finishing: bool,
    final_pending: bool,
    preview_in_flight: bool,
    preview_queued: bool,
) -> Dispatch {
    if finishing {
        if final_pending {
            Dispatch::Final
        } else {
            Dispatch::Nothing
        }
    } else if !preview_in_flight && preview_queued {
        Dispatch::Preview
    } else {
        Dispatch::Nothing
    }
}

fn run_session(
    app: &AppHandle,
    commands: &Receiver<Command>,
    state: &Arc<Mutex<FlowState>>,
    cancel_requested: &Arc<AtomicBool>,
    stop_requested: &Arc<AtomicBool>,
    engine: &Arc<Engine>,
    config: SessionConfig,
) {
    // A Cancel/Close queued behind Start must never open the microphone.
    if cancel_requested.load(Ordering::Acquire) {
        cancel(app, state);
        return;
    }
    let mut capture = Some(match AudioCapture::start(config.microphone.as_deref()) {
        Ok(capture) => capture,
        Err(error) => {
            fail(app, state, error);
            return;
        }
    });
    let (events_tx, events) = mpsc::channel();
    let mut requests = EngineRequests::default();
    // The engine is checked as the microphone opens, never before it: capture
    // is not delayed, and a dead engine ends the take at once (R3).
    requests.check = Some(spawn_request(&events_tx, {
        let (engine, engine_config) = (Arc::clone(engine), config.engine.clone());
        async move { EngineEvent::Check(engine.check(&engine_config).await) }
    }));

    let mut final_audio: Option<Vec<f32>> = None;
    let mut finishing = false;
    {
        // Decided under the state lock: a release or cancel that lands while
        // the microphone opens can never be followed by a Recording state.
        enum Opened {
            Cancel,
            Finish,
            Record,
        }
        let decision = match state.lock() {
            Ok(mut current) => {
                if cancel_requested.load(Ordering::Acquire) {
                    Opened::Cancel
                } else if stop_requested.load(Ordering::Acquire) {
                    Opened::Finish
                } else {
                    *current = FlowState::Recording;
                    Opened::Record
                }
            }
            Err(_) => Opened::Cancel,
        };
        match decision {
            Opened::Cancel => {
                cancel_session(app, state, &mut capture, requests);
                return;
            }
            Opened::Finish => {
                let current_capture = capture.take().expect("capture was just opened");
                match current_capture.finish() {
                    Ok(audio) => {
                        final_audio = Some(audio);
                        finishing = true;
                    }
                    Err(error) => {
                        fail(app, state, error);
                        return;
                    }
                }
            }
            Opened::Record => {
                tracing::info!(state = ?FlowState::Recording, "flow state");
                emit(
                    app,
                    FlowEvent::State {
                        state: FlowState::Recording,
                        message: None,
                    },
                );
            }
        }
    }
    if finishing {
        set_state(app, state, FlowState::Processing, None);
    }

    let mut queue = LatestPreviewQueue::default();
    let mut sequence = 0_u64;
    let mut shown_sequence: Option<u64> = None;
    let mut next_preview_at = Instant::now();
    let mut next_level_at = Instant::now();
    let mut last_queued_samples = 0_u64;
    let mut final_started: Option<Instant> = None;
    loop {
        if cancel_requested.load(Ordering::Acquire) {
            cancel_session(app, state, &mut capture, requests);
            return;
        }

        loop {
            match commands.try_recv() {
                Ok(Command::Stop) => {
                    if !finishing {
                        let Some(current_capture) = capture.take() else {
                            continue;
                        };
                        match current_capture.finish() {
                            Ok(audio) => {
                                final_audio = Some(audio);
                                finishing = true;
                                set_state(app, state, FlowState::Processing, None);
                            }
                            Err(error) => {
                                fail(app, state, error);
                                return;
                            }
                        }
                    }
                }
                Ok(Command::Cancel) => {
                    cancel_requested.store(true, Ordering::Release);
                }
                Ok(Command::Start { .. }) => {}
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            }
        }
        if cancel_requested.load(Ordering::Acquire) {
            cancel_session(app, state, &mut capture, requests);
            return;
        }

        // The waveform runs on its own clock. A device failure is not handled
        // here: the preview tick below applies the same buffer guard and ends
        // the flow within one preview interval.
        if !finishing && next_level_at <= Instant::now() {
            if let Some(level) = capture.as_ref().and_then(|capture| capture.level().ok()) {
                emit(app, FlowEvent::Level { level });
            }
            next_level_at = Instant::now() + LEVEL_INTERVAL;
        }

        if !finishing && next_preview_at <= Instant::now() {
            let current_capture = capture
                .as_ref()
                .expect("capture remains live until stop or cancellation");
            match current_capture.snapshot(PREVIEW_WINDOW_SAMPLES) {
                Ok(snapshot) => {
                    if config.show_preview
                        && snapshot.samples.len() >= MIN_AUDIO_SAMPLES
                        && snapshot.total_samples
                            >= last_queued_samples + PREVIEW_STEP_SAMPLES as u64
                    {
                        sequence += 1;
                        last_queued_samples = snapshot.total_samples;
                        queue.replace(PreviewJob {
                            sequence,
                            samples: snapshot.samples,
                        });
                    }
                    next_preview_at = Instant::now() + PREVIEW_INTERVAL;
                }
                Err(error) => {
                    if let Some(capture) = capture.take() {
                        capture.discard();
                    }
                    fail(app, state, error);
                    return;
                }
            }
        }

        match next_dispatch(
            finishing,
            final_audio.is_some(),
            requests.preview.is_some(),
            queue.has_queued(),
        ) {
            Dispatch::Final => {
                let audio = final_audio.take().expect("final audio is pending");
                // The take ended: no preview or check may hold the final back.
                EngineRequests::abort(&mut requests.preview);
                EngineRequests::abort(&mut requests.check);
                let bound = engine::final_response_bound(audio.len());
                final_started = Some(Instant::now());
                requests.final_request = Some(spawn_request(&events_tx, {
                    let (engine, engine_config) = (Arc::clone(engine), config.engine.clone());
                    async move {
                        EngineEvent::Final(engine.transcribe(&engine_config, audio, bound).await)
                    }
                }));
            }
            Dispatch::Preview => {
                let job = queue.take_latest().expect("a preview is queued");
                requests.preview = Some(spawn_request(&events_tx, {
                    let (engine, engine_config) = (Arc::clone(engine), config.engine.clone());
                    async move {
                        EngineEvent::Preview {
                            sequence: job.sequence,
                            result: engine
                                .transcribe(&engine_config, job.samples, engine::PREVIEW_RESPONSE_BOUND)
                                .await,
                        }
                    }
                }));
            }
            Dispatch::Nothing => {}
        }
        if cancel_requested.load(Ordering::Acquire) {
            cancel_session(app, state, &mut capture, requests);
            return;
        }
        match events.try_recv() {
            Ok(EngineEvent::Check(Ok(()))) => requests.check = None,
            Ok(EngineEvent::Check(Err(error))) => {
                // The engine cannot take this take: end it now rather than let
                // the user speak into it (R3).
                if let Some(capture) = capture.take() {
                    capture.discard();
                }
                drop(requests);
                fail(app, state, error);
                return;
            }
            Ok(EngineEvent::Preview { sequence, result }) => {
                requests.preview = None;
                if accepts_preview_result(finishing, shown_sequence, sequence) {
                    // A failed preview is dropped silently: capture continues
                    // and only the final request can fail the flow (R3).
                    if let Ok(text) = result {
                        // Counts and delivery only, never recognized text
                        // (R5) — the same discipline as `flow final`.
                        let chars = text.chars().count();
                        let delivered = app
                            .emit(
                                "dictation://flow",
                                FlowEvent::Preview {
                                    sequence,
                                    text,
                                    provisional: true,
                                },
                            )
                            .is_ok();
                        shown_sequence = Some(sequence);
                        tracing::info!(chars, delivered, "flow preview");
                    }
                }
            }
            Ok(EngineEvent::Final(result)) => {
                drop(requests);
                if cancel_requested.load(Ordering::Acquire) {
                    cancel(app, state);
                    return;
                }
                match result {
                    Ok(text) => {
                        if !commit_final(
                            app,
                            state,
                            cancel_requested,
                            text,
                            final_started,
                            config.confirm_before_insert,
                        ) {
                            cancel(app, state);
                        }
                    }
                    Err(error) => fail(app, state, error),
                }
                return;
            }
            Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => {}
        }
        thread::sleep(Duration::from_millis(30));
    }
}

/// Discards the capture and abandons every request before announcing the
/// cancellation, so nothing of the take survives the notice.
fn cancel_session(
    app: &AppHandle,
    state: &Arc<Mutex<FlowState>>,
    capture: &mut Option<AudioCapture>,
    requests: EngineRequests,
) {
    if let Some(capture) = capture.take() {
        capture.discard();
    }
    drop(requests);
    cancel(app, state);
}

fn set_state(
    app: &AppHandle,
    state: &Arc<Mutex<FlowState>>,
    next: FlowState,
    message: Option<String>,
) {
    tracing::info!(state = ?next, message = ?message, "flow state");
    if let Ok(mut current) = state.lock() {
        *current = next;
    }
    emit(
        app,
        FlowEvent::State {
            state: next,
            message,
        },
    );
}

/// Returns the dock to the tray after `after`, unless a newer flow has shown
/// it again meanwhile: the hide belongs to the outcome it was scheduled for,
/// never to whatever the user started next.
fn hide_dock_after(app: &AppHandle, after: Duration) {
    let app = app.clone();
    let generation = bar::generation();
    thread::spawn(move || {
        thread::sleep(after);
        bar::hide_stale(&app, generation);
    });
}

/// A recoverable failure stays readable long enough to act on (R6, S3, S4).
fn fail<E: std::fmt::Display>(app: &AppHandle, state: &Arc<Mutex<FlowState>>, error: E) {
    set_state(app, state, FlowState::Error, Some(error.to_string()));
    hide_dock_after(app, ERROR_LINGER);
}

/// A cancellation has nothing to read: the dock is already gone by the time
/// the teardown lands here, and the announcement carries the outcome.
fn cancel(app: &AppHandle, state: &Arc<Mutex<FlowState>>) {
    set_state(
        app,
        state,
        FlowState::Idle,
        Some("Canceled — no text was inserted.".to_string()),
    );
    bar::hide(app);
}

fn emit(app: &AppHandle, event: FlowEvent) {
    let _ = app.emit("dictation://flow", event);
}

/// Publishes the final result. The commit runs under the same state lock
/// `FlowController::cancel` takes before arming its flag, so a concurrent
/// Cancel/Close either happens-before the commit — nothing is emitted and
/// this returns false — or lands after it, when the flow already reads Idle
/// and `cancel` returns without arming. A bare atomic load before `emit`
/// would leave a window in which Close is accepted and a result is still
/// delivered; M4 insertion hangs off this commit point (S2, S9).
fn commit_final(
    app: &AppHandle,
    state: &Arc<Mutex<FlowState>>,
    cancel_requested: &Arc<AtomicBool>,
    text: String,
    started: Option<Instant>,
    confirm_before_insert: bool,
) -> bool {
    let chars = text.chars().count();
    let seconds = started
        .map(|started| started.elapsed().as_secs_f64())
        .unwrap_or_default();
    // With confirmation on the flow does not end here: it waits for the user,
    // and only `FlowController::accept` may release the transcript onward.
    let settled = if confirm_before_insert {
        FlowState::Confirming
    } else {
        FlowState::Idle
    };
    let delivered = {
        let Ok(mut current) = state.lock() else {
            return false;
        };
        if cancel_requested.load(Ordering::Acquire) {
            return false;
        }
        *current = settled;
        app.emit("dictation://flow", FlowEvent::Final { text }).is_ok()
    };
    // Production-path proof for M2: counts and timing only, never recognized
    // text (R5). `delivered` reports the event actually reaching the webview,
    // so this line cannot outlive a broken emit and stand in for delivery.
    tracing::info!(chars, seconds, delivered, "flow final");
    set_state(app, state, settled, None);
    if !confirm_before_insert {
        // The success state the webview rendered from `Final` must survive its
        // own Idle transition, or the human never sees the flow succeed (R2).
        hide_dock_after(app, OUTCOME_LINGER);
    }
    true
}

#[derive(Debug, PartialEq)]
pub(crate) struct PreviewJob {
    pub(crate) sequence: u64,
    pub(crate) samples: Vec<f32>,
}

/// Holds only the newest window not yet sent: a request carries the audio
/// that is most recent when it goes out, never a queued older one.
#[derive(Default)]
pub(crate) struct LatestPreviewQueue {
    latest: Option<PreviewJob>,
}

impl LatestPreviewQueue {
    pub(crate) fn replace(&mut self, job: PreviewJob) {
        self.latest = Some(job);
    }

    pub(crate) fn take_latest(&mut self) -> Option<PreviewJob> {
        self.latest.take()
    }

    pub(crate) fn has_queued(&self) -> bool {
        self.latest.is_some()
    }
}

/// A preview result is shown while capture is active when it is newer than
/// the preview on screen. Newer windows queued while it ran do not make it
/// stale — otherwise an engine slower than the window cadence would never
/// preview at all (R3).
pub(crate) fn accepts_preview_result(finishing: bool, shown: Option<u64>, sequence: u64) -> bool {
    !finishing && shown.is_none_or(|shown| sequence > shown)
}

#[cfg(test)]
mod tests {
    use super::*;


    #[test]
    fn a_press_at_rest_begins_a_flow() {
        assert_eq!(
            start_decision(FlowState::Idle, false, false),
            StartDecision::Begin
        );
        // A recoverable error left the flow at rest too; the next press is a
        // normal activation, not a refusal.
        assert_eq!(
            start_decision(FlowState::Error, false, false),
            StartDecision::Begin
        );
    }

    #[test]
    fn a_press_while_a_cancellation_winds_down_reports_busy() {
        for state in [FlowState::Loading, FlowState::Recording, FlowState::Processing] {
            assert_eq!(
                start_decision(state, true, false),
                StartDecision::Busy(BUSY_DISCARDING),
                "{state:?} was cancelled and is still discarding"
            );
            // Without a cancellation the flow is simply already live: the
            // dock already shows it, so a notice would be noise.
            assert_eq!(start_decision(state, false, false), StartDecision::Ignore);
        }
    }

    #[test]
    fn a_press_while_a_transcript_waits_asks_for_a_decision() {
        // Starting a new take would silently throw away a transcript the user
        // has not decided on, so the press is refused and says why.
        assert_eq!(
            start_decision(FlowState::Confirming, false, false),
            StartDecision::Busy(BUSY_CONFIRMING)
        );
        assert_eq!(
            start_decision(FlowState::Confirming, true, false),
            StartDecision::Busy(BUSY_CONFIRMING)
        );
    }

    #[test]
    fn hold_mode_press_only_ever_begins_or_refuses() {
        // Hold mode (press_once = false): a second press while already live
        // is ignored, exactly like the old `start_decision` — release, not a
        // second press, is what ends the take.
        for state in [FlowState::Loading, FlowState::Recording, FlowState::Processing] {
            assert_eq!(
                dictation_press_decision(state, false, false, false),
                DictationPressDecision::Ignore,
                "{state:?} hold mode, no cancellation in flight"
            );
            assert_eq!(
                dictation_press_decision(state, true, false, false),
                DictationPressDecision::Busy(BUSY_DISCARDING),
                "{state:?} hold mode, discarding the last take"
            );
        }
        assert_eq!(
            dictation_press_decision(FlowState::Idle, false, false, false),
            DictationPressDecision::Begin
        );
    }

    #[test]
    fn press_once_second_press_ends_the_take() {
        // D16: with confirm_before_insert on, the second press is the
        // release — it ends the take rather than being ignored.
        for state in [FlowState::Loading, FlowState::Recording, FlowState::Processing] {
            assert_eq!(
                dictation_press_decision(state, false, false, true),
                DictationPressDecision::End,
                "{state:?} press-once, no cancellation in flight"
            );
        }
        // A press landing while the *previous* take is still being discarded
        // is refused the same way in both modes — it is not the take this
        // press would end.
        assert_eq!(
            dictation_press_decision(FlowState::Recording, true, false, true),
            DictationPressDecision::Busy(BUSY_DISCARDING)
        );
    }

    #[test]
    fn a_waiting_transcript_is_accepted_by_the_dictation_shortcut_in_either_mode() {
        // D16, R4: the press that would otherwise start a take resolves the
        // one already held, regardless of press_once — Confirming is reached
        // by state, not by re-deriving the preference here.
        assert_eq!(
            dictation_press_decision(FlowState::Confirming, false, false, false),
            DictationPressDecision::Accept
        );
        assert_eq!(
            dictation_press_decision(FlowState::Confirming, false, false, true),
            DictationPressDecision::Accept
        );
    }

    #[test]
    fn closing_ignores_the_dictation_shortcut_in_either_mode() {
        for press_once in [false, true] {
            assert_eq!(
                dictation_press_decision(FlowState::Recording, false, true, press_once),
                DictationPressDecision::Ignore
            );
            assert_eq!(
                dictation_press_decision(FlowState::Confirming, false, true, press_once),
                DictationPressDecision::Ignore
            );
        }
    }

    #[test]
    fn discard_shortcut_acts_while_a_transcript_waits_or_the_engine_processes() {
        // R4, R7: the keyboard path out of a waiting transcript and out of a
        // slow engine, in either activation mode — the decision reads the
        // state, never the preference.
        for state in [FlowState::Confirming, FlowState::Processing] {
            assert_eq!(
                discard_press_decision(state),
                DiscardPressDecision::Discard,
                "{state:?}"
            );
        }
        for state in [
            FlowState::Idle,
            FlowState::Loading,
            FlowState::Recording,
            FlowState::Error,
        ] {
            assert_eq!(
                discard_press_decision(state),
                DiscardPressDecision::Ignore,
                "{state:?}"
            );
        }
    }

    #[test]
    fn a_waiting_transcript_is_discarded_before_exit() {
        // S9: Close with a held transcript must cancel it, never insert it.
        assert_eq!(
            on_close_requested(FlowState::Confirming),
            CloseDecision::CancelAndExit
        );
    }

    #[test]
    fn closing_never_starts_or_explains() {
        for state in [
            FlowState::Idle,
            FlowState::Error,
            FlowState::Recording,
            FlowState::Processing,
        ] {
            assert_eq!(
                start_decision(state, true, true),
                StartDecision::Ignore,
                "{state:?} during close"
            );
        }
    }
    #[test]
    fn close_with_no_active_flow_exits_clean() {
        assert_eq!(
            on_close_requested(FlowState::Idle),
            CloseDecision::ExitClean
        );
    }

    #[test]
    fn close_during_active_flow_maps_to_cancel_and_exit() {
        assert_eq!(
            on_close_requested(FlowState::Loading),
            CloseDecision::CancelAndExit
        );
        assert_eq!(
            on_close_requested(FlowState::Recording),
            CloseDecision::CancelAndExit
        );
        assert_eq!(
            on_close_requested(FlowState::Processing),
            CloseDecision::CancelAndExit
        );
    }

    #[test]
    fn close_after_recoverable_error_exits_clean() {
        assert_eq!(
            on_close_requested(FlowState::Error),
            CloseDecision::ExitClean
        );
    }

    #[test]
    fn queued_preview_keeps_only_the_newest_window() {
        let mut queue = LatestPreviewQueue::default();
        queue.replace(PreviewJob {
            sequence: 1,
            samples: vec![0.1],
        });
        queue.replace(PreviewJob {
            sequence: 2,
            samples: vec![0.2],
        });

        let job = queue.take_latest().expect("latest preview");
        assert_eq!(job.sequence, 2);
        assert_eq!(job.samples, vec![0.2]);
        assert!(queue.take_latest().is_none());
    }

    #[test]
    fn a_preview_older_than_the_one_shown_is_dropped() {
        assert!(accepts_preview_result(false, None, 1));
        assert!(accepts_preview_result(false, Some(1), 2));
        assert!(!accepts_preview_result(false, Some(2), 1));
        assert!(!accepts_preview_result(false, Some(2), 2));
    }

    #[test]
    fn a_slow_engine_still_previews_while_newer_windows_queue() {
        // The engine took longer than several 400 ms ticks: windows 2..5
        // queued behind the request for window 1. Its answer is still newer
        // than anything shown, so it is shown; the next request then carries
        // only the newest window, never a backlog.
        let mut queue = LatestPreviewQueue::default();
        for sequence in 2..=5 {
            queue.replace(PreviewJob {
                sequence,
                samples: vec![sequence as f32],
            });
        }
        assert!(accepts_preview_result(false, None, 1));
        let next = queue.take_latest().expect("newest window");
        assert_eq!(next.sequence, 5);
        assert!(!queue.has_queued());
    }

    #[test]
    fn no_preview_is_shown_once_the_take_ended() {
        assert!(!accepts_preview_result(true, None, 1));
        assert!(!accepts_preview_result(true, Some(1), 9));
    }

    #[test]
    fn the_final_goes_out_at_once_even_with_a_preview_in_flight() {
        assert_eq!(next_dispatch(true, true, true, true), Dispatch::Final);
        assert_eq!(next_dispatch(true, true, false, false), Dispatch::Final);
        // Once sent, nothing else goes out for this take.
        assert_eq!(next_dispatch(true, false, true, true), Dispatch::Nothing);
    }

    #[test]
    fn at_most_one_preview_request_is_in_flight() {
        assert_eq!(next_dispatch(false, false, false, true), Dispatch::Preview);
        assert_eq!(next_dispatch(false, false, true, true), Dispatch::Nothing);
        assert_eq!(next_dispatch(false, false, false, false), Dispatch::Nothing);
    }
}
