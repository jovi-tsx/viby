import { invoke } from "@tauri-apps/api/core";
import logoUrl from "../assets/branding/viby-lockup-light.svg";

type Status = {
  engine_configured: boolean;
  microphone: string | null;
  shortcut: string;
  shortcut_error: string | null;
  discard_shortcut: string;
  discard_shortcut_error: string | null;
};

type Preferences = {
  shortcut: string;
  discard_shortcut: string;
  microphone: string | null;
  engine: { endpoint: string; allow_local_network: boolean };
  model: { language: string; name: string };
  insertion: { send_enter: boolean; confirm_before_insert: boolean };
  interface: { show_preview: boolean; bar_position: string };
};

/** The Options form state machine (SPEC UI Contract). Save is enabled only in
 *  `dirty`; a conflict keeps the field focused and the previous value active
 *  until the user edits. */
type FormState =
  | "loading"
  | "clean"
  | "dirty"
  | "saving"
  | "conflict"
  | "load-failed";

function field<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing element #${id}`);
  return el as T;
}

const form = field<HTMLFormElement>("options-form");
const saveButton = field<HTMLButtonElement>("save");
const statusEl = field<HTMLParagraphElement>("save-state");
const errorEl = field<HTMLParagraphElement>("shortcut-error");
const discardErrorEl = field<HTMLParagraphElement>("discard-shortcut-error");
const endpointErrorEl = field<HTMLParagraphElement>("engine-endpoint-error");
const barPositionErrorEl = field<HTMLParagraphElement>("bar-position-error");
const shortcutInput = field<HTMLInputElement>("shortcut");
const discardShortcutInput = field<HTMLInputElement>("discard-shortcut");
const cards = Array.from(
  form.querySelectorAll<HTMLInputElement | HTMLSelectElement>("input, select"),
);

let state: FormState = "loading";
let revision = 0;

function setStatus(text: string, saved = false) {
  statusEl.textContent = text;
  statusEl.classList.toggle("saved", saved);
}

function setControlsEnabled(enabled: boolean) {
  for (const el of cards) el.disabled = !enabled;
  saveButton.disabled = true; // Save is re-enabled only by an edit (dirty).
}
function clearFieldErrors() {
  for (const error of [errorEl, discardErrorEl, endpointErrorEl, barPositionErrorEl]) {
    error.textContent = "";
  }
  for (const input of [
    shortcutInput,
    discardShortcutInput,
    field<HTMLInputElement>("engine-endpoint"),
    field<HTMLSelectElement>("bar-position"),
  ]) {
    input.removeAttribute("aria-invalid");
  }
}

function markDirty() {
  revision += 1;
  if (state === "loading" || state === "saving") {
    return;
  }
  clearFieldErrors();
  state = "dirty";
  saveButton.disabled = false;
  setStatus("Unsaved changes");
}

async function load(): Promise<Status> {
  const [prefs, status, devices] = await Promise.all([
    invoke<Preferences>("get_preferences"),
    invoke<Status>("get_status"),
    invoke<string[]>("list_microphones"),
  ]);

  shortcutInput.value = prefs.shortcut;
  discardShortcutInput.value = prefs.discard_shortcut;

  const mic = field<HTMLSelectElement>("microphone");
  for (const name of devices) {
    mic.add(new Option(name, name));
  }
  if (prefs.microphone && !devices.includes(prefs.microphone)) {
    mic.add(new Option(`${prefs.microphone} (unavailable)`, prefs.microphone));
  }
  mic.value = prefs.microphone ?? "";
  field<HTMLInputElement>("engine-endpoint").value = prefs.engine.endpoint;
  field<HTMLInputElement>("allow-local-network").checked =
    prefs.engine.allow_local_network;
  field<HTMLInputElement>("model-name").value = prefs.model.name;
  field<HTMLInputElement>("model-language").value = prefs.model.language;
  // Viby never opens this window on its own to ask for an engine; this line
  // is where an unconfigured install says what dictation needs (R3, DESIGN).
  field("engine-state").textContent = status.engine_configured
    ? "Viby sends each take to the engine below. It is checked when you start dictating."
    : "No engine set — dictation needs a speech-to-text engine you run. Enter its address below.";

  field<HTMLInputElement>("send-enter").checked = prefs.insertion.send_enter;
  field<HTMLInputElement>("confirm-insert").checked =
    prefs.insertion.confirm_before_insert;
  field<HTMLSelectElement>("bar-position").value =
    prefs.interface.bar_position;
  field<HTMLInputElement>("show-preview").checked =
    prefs.interface.show_preview;
  return status;
}

function collect(): Preferences {
  const mic = field<HTMLSelectElement>("microphone").value;
  return {
    shortcut: shortcutInput.value.trim(),
    discard_shortcut: discardShortcutInput.value.trim(),
    microphone: mic === "" ? null : mic,
    engine: {
      endpoint: field<HTMLInputElement>("engine-endpoint").value.trim(),
      allow_local_network: field<HTMLInputElement>("allow-local-network")
        .checked,
    },
    model: {
      language:
        field<HTMLInputElement>("model-language").value.trim() || "auto",
      name: field<HTMLInputElement>("model-name").value.trim(),
    },
    insertion: {
      send_enter: field<HTMLInputElement>("send-enter").checked,
      confirm_before_insert: field<HTMLInputElement>("confirm-insert").checked,
    },
    interface: {
      show_preview: field<HTMLInputElement>("show-preview").checked,
      bar_position: field<HTMLSelectElement>("bar-position").value,
    },
  };
}

window.addEventListener("DOMContentLoaded", async () => {
  field<HTMLImageElement>("brand-logo").src = logoUrl;

  setControlsEnabled(false);
  form.setAttribute("aria-busy", "true");
  setStatus("Loading settings…");

  // Handlers register before the load attempt so the load-failed recovery
  // path (edit -> dirty -> save) works instead of dead-ending.
  form.addEventListener("input", markDirty);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (state === "saving") return;

    const saveRevision = revision;
    state = "saving";
    saveButton.disabled = true;
    setStatus("Saving…");

    try {
      await invoke("save_preferences", { next: collect() });
      if (revision === saveRevision) {
        state = "clean";
        clearFieldErrors();
        setStatus("Saved", true);
      } else {
        state = "dirty";
        saveButton.disabled = false;
        setStatus("Unsaved changes");
      }
    } catch (error) {
      if (revision !== saveRevision) {
        state = "dirty";
        saveButton.disabled = false;
        setStatus("Unsaved changes");
        return;
      }
      const e = error as {
        kind?: string;
        field?:
          | "shortcut"
          | "discard-shortcut"
          | "engine-endpoint"
          | "bar-position";
        message?: string;
      };
      if (e.kind === "conflict" || e.kind === "validation") {
        state = "conflict";
        clearFieldErrors();
        const target =
          e.field === "engine-endpoint"
            ? [endpointErrorEl, field<HTMLInputElement>("engine-endpoint")]
            : e.field === "bar-position"
              ? [barPositionErrorEl, field<HTMLSelectElement>("bar-position")]
              : e.field === "discard-shortcut"
                ? [discardErrorEl, discardShortcutInput]
                : [errorEl, shortcutInput];
        target[0].textContent = e.message ?? String(error);
        target[1].setAttribute("aria-invalid", "true");
        target[1].focus();
        setStatus("");
        // Save stays disabled until the user edits (markDirty re-enables).
      } else {
        state = "dirty";
        saveButton.disabled = false;
        setStatus("Couldn't save settings. Try again.");
      }
    }
  });

  try {
    const loadedStatus = await load();
    form.setAttribute("aria-busy", "false");
    setControlsEnabled(true);
    if (loadedStatus.shortcut_error) {
      state = "conflict";
      errorEl.textContent = loadedStatus.shortcut_error;
      shortcutInput.setAttribute("aria-invalid", "true");
      shortcutInput.focus();
      setStatus("Choose another shortcut and save.");
    } else if (loadedStatus.discard_shortcut_error) {
      state = "conflict";
      discardErrorEl.textContent = loadedStatus.discard_shortcut_error;
      discardShortcutInput.setAttribute("aria-invalid", "true");
      discardShortcutInput.focus();
      setStatus("Choose another discard shortcut and save.");
    } else {
      state = "clean";
      setStatus("");
    }
  } catch {
    state = "load-failed";
    form.setAttribute("aria-busy", "false");
    setControlsEnabled(true);
    setStatus(
      "Couldn't load settings. Review the values and save to start fresh.",
    );
  }
});
