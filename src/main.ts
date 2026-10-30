import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

type FlowEvent =
  | { kind: "state"; state: string; message?: string | null }
  | { kind: "level"; level: number }
  | { kind: "preview"; sequence: number; text: string; provisional: boolean }
  | { kind: "final"; text: string }
  | { kind: "notice"; text: string };

/** Bars in the waveform. The newest level enters on the right. */
const BARS = 28;
/** Discrete update interval for the reduced-motion meter (S6). */
const STATIC_METER_INTERVAL = 400;
/**
 * Speech RMS lives in the bottom fifth of the scale, so a linear mapping draws
 * an almost flat line. This curve spends the pill's height where the voice
 * actually is, without ever claiming more level than was measured.
 */
function gain(level: number) {
  return Math.min(1, Math.sqrt(level * 1.6));
}

const capsule = document.getElementById("capsule") as HTMLDivElement;
const wave = document.getElementById("wave") as HTMLDivElement;
const meter = document.getElementById("meter") as HTMLDivElement;
const stateText = document.getElementById("state") as HTMLParagraphElement;
const noticeText = document.getElementById("notice") as HTMLParagraphElement;
const errorText = document.getElementById("error") as HTMLParagraphElement;
const preview = document.getElementById("preview") as HTMLParagraphElement;
const previewText = document.getElementById("preview-text") as HTMLSpanElement;
const controls = document.getElementById("controls") as HTMLDivElement;
const pill = document.getElementById("pill") as HTMLDivElement;
const acceptButton = document.getElementById("accept") as HTMLButtonElement;
const cancelButton = document.getElementById("cancel") as HTMLButtonElement;

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const bars: HTMLSpanElement[] = [];
for (let index = 0; index < BARS; index += 1) {
  const bar = document.createElement("span");
  bar.style.setProperty("--level", "0");
  // Phase index for the processing sweep; the level path never reads it.
  bar.style.setProperty("--i", String(index));
  wave.append(bar);
  bars.push(bar);
}

let levels = new Array<number>(BARS).fill(0);
let lastMeterUpdate = 0;
/** A delivered result must outlive its own Idle transition to be readable. */
let showingOutcome = false;

/** One announcement per transition: an unchanged string is not re-announced. */
function announce(element: HTMLElement, text: string) {
  if (element.textContent !== text) element.textContent = text;
}

function setLevel(level: number) {
  const clamped = Math.max(0, Math.min(1, level));
  if (reducedMotion.matches) {
    // A static meter, updated at discrete intervals — never a continuous
    // animation (S6).
    const now = performance.now();
    if (now - lastMeterUpdate < STATIC_METER_INTERVAL) return;
    lastMeterUpdate = now;
    meter.style.setProperty("--level", gain(clamped).toFixed(3));
    meter.setAttribute("aria-valuenow", Math.round(clamped * 100).toString());
    return;
  }
  levels = levels.slice(1);
  levels.push(clamped);
  for (let index = 0; index < BARS; index += 1) {
    bars[index].style.setProperty("--level", gain(levels[index]).toFixed(3));
  }
}

function resetLevels() {
  levels = new Array<number>(BARS).fill(0);
  for (const bar of bars) bar.style.setProperty("--level", "0");
  meter.style.setProperty("--level", "0");
  meter.setAttribute("aria-valuenow", "0");
  lastMeterUpdate = 0;
}

/**
 * The level is shown only while audio is actually being captured, and the
 * accessible meter never claims a live level outside capture: processing must
 * not simulate an open microphone. Processing keeps the bars visible but grey
 * and self-animated (see `[data-state="processing"]`), which reads as work in
 * progress rather than as sound.
 */
function showAudioLevel(state: string) {
  const capturing = state === "recording";
  const staticMeter = capturing && reducedMotion.matches;
  wave.hidden = staticMeter || !(capturing || state === "processing");
  meter.hidden = !staticMeter;
}

function clearPreview() {
  preview.hidden = true;
  preview.removeAttribute("aria-label");
  previewText.textContent = "";
}

function render(state: string, message?: string | null) {
  capsule.dataset.state = state;
  errorText.hidden = state !== "error";
  // Any real transition supersedes a refusal notice.
  noticeText.hidden = true;
  showAudioLevel(state);
  // Each control appears only where it means something. There is no
  // capture-time accept: releasing the shortcut already ends the take, so the
  // accept control belongs to the confirmation step alone, and that step only
  // exists when the user asked to confirm before inserting.
  const running = ["loading", "recording", "processing"].includes(state);
  const confirming = state === "confirming";
  controls.hidden = !running && !confirming;
  cancelButton.hidden = controls.hidden;
  acceptButton.hidden = !confirming;
  // Nothing is being heard while the transcript waits, so the level pill would
  // be an empty lozenge; the two controls carry the whole choice.
  pill.hidden = confirming;
  if (state !== "recording") {
    clearPreview();
    resetLevels();
  }

  switch (state) {
    case "loading":
      announce(stateText, "Loading local model…");
      break;
    case "recording":
      announce(stateText, "Listening");
      break;
    case "processing":
      announce(stateText, "Processing");
      break;
    case "success":
      announce(stateText, "Success");
      break;
    case "confirming":
      // The one state that must be printed as well as announced: nothing on
      // screen would otherwise say why the dock is waiting.
      noticeText.hidden = false;
      noticeText.textContent = "Ready to finish";
      announce(stateText, "Ready to finish. Accept or discard.");
      break;
    case "error":
      // Meaning never rests on colour alone, and the message is assertive
      // because the flow ended and the user must act (R6).
      stateText.textContent = "";
      announce(errorText, `Error — ${message ?? "the dictation flow stopped."}`);
      break;
    default:
      // Idle. A message means the flow ended in a way the user must read.
      announce(stateText, message ?? "");
      errorText.textContent = "";
  }
}

function showFlow(event: FlowEvent) {
  switch (event.kind) {
    case "state":
      // The Idle that follows a delivered result would erase the success the
      // user has not read yet; the backend hides the capsule shortly after.
      if (event.state === "idle" && showingOutcome && !event.message) return;
      showingOutcome = false;
      render(event.state, event.message);
      break;
    case "level":
      setLevel(event.level);
      break;
    case "preview":
      if (capsule.dataset.state !== "recording" || !event.provisional) return;
      // One deterministic accessible name for the whole line: UIA would
      // otherwise split the generated chip from the text into two elements
      // and neither alone proves the preview is on screen.
      preview.setAttribute("aria-label", `Provisional: ${event.text}`);
      preview.hidden = false;
      previewText.textContent = event.text;
      break;
    case "final":
      // The recognized text itself is never rendered: the provisional preview
      // is the only spoken content the surface ever shows (R5).
      showingOutcome = true;
      render("success");
      break;
    case "notice":
      // A refusal, not a state: the dock stays as it is, the plate carries the
      // reason, and the polite region announces it once.
      noticeText.hidden = false;
      noticeText.textContent = event.text;
      announce(stateText, event.text);
      break;
  }
}

window.addEventListener("DOMContentLoaded", () => {
  render("idle");
  acceptButton.addEventListener("click", () => void invoke("accept_dictation"));
  cancelButton.addEventListener("click", () => void invoke("cancel_dictation"));
  listen<FlowEvent>("dictation://flow", (event) => showFlow(event.payload));
});
