import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path) => readFileSync(resolve(root, path), "utf8");
const json = (path) => JSON.parse(read(path));
const [command = "check", argument, tag] = process.argv.slice(2);
const pattern = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;

function valid(version) {
  if (!pattern.test(version ?? "")) throw new Error("Use X.Y.Z without v, suffixes, or leading zeroes.");
  if (version.split(".").some((part) => !Number.isSafeInteger(Number(part)))) {
    throw new Error("Version component exceeds the supported integer range.");
  }
  return version;
}
function one(text, regex, path) {
  const matches = [...text.matchAll(new RegExp(regex.source, "gm"))];
  if (matches.length !== 1) throw new Error("Expected exactly one Viby version in " + path);
  return matches[0];
}
const cargoPattern = /(^version = ")([^"]+)(")/m;
const lockPattern = /(\[\[package\]\]\r?\nname = "viby"\r?\nversion = ")([^"]+)(")/m;
function versions() {
  const lock = json("package-lock.json");
  return {
    "package.json": json("package.json").version,
    "package-lock.json": lock.version,
    "package-lock.json packages root": lock.packages[""].version,
    "src-tauri/Cargo.toml": one(read("src-tauri/Cargo.toml"), cargoPattern, "Cargo.toml")[2],
    "src-tauri/Cargo.lock": one(read("src-tauri/Cargo.lock"), lockPattern, "Cargo.lock")[2],
    "src-tauri/tauri.conf.json": json("src-tauri/tauri.conf.json").version,
  };
}
function entry(version) {
  valid(version);
  const lines = read("CHANGELOG.md").split(/\r?\n/);
  const header = "## [" + version + "] - ";
  const matching = lines.map((line, index) => line.startsWith(header) ? index : -1).filter((i) => i >= 0);
  if (matching.length !== 1) throw new Error("Expected one dated CHANGELOG entry for " + version);
  const start = matching[0];
  const date = lines[start].slice(header.length);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || new Date(date + "T00:00:00Z").toISOString().slice(0, 10) !== date) {
    throw new Error("CHANGELOG release dates must be valid YYYY-MM-DD dates.");
  }
  let end = lines.findIndex((line, i) => i > start && (line.startsWith("## ") || /^\[[^\]]+\]: /.test(line)));
  if (end < 0) end = lines.length;
  const notes = lines.slice(start + 1, end).join("\n").trim();
  if (!notes || !notes.includes("### ")) throw new Error("Release entry has no grouped notes.");
  return notes + "\n";
}
try {
  if (["set", "notes"].includes(command) && process.argv.length > 4) {
    throw new Error("Unexpected version command arguments.");
  }
  const current = valid(json("package.json").version);
  if (command === "check") {
    if (argument && (argument !== "--tag" || !tag || process.argv.length !== 5)) {
      throw new Error("Usage: check [--tag vX.Y.Z]");
    }
    if (argument === "--tag" && tag !== "v" + current) throw new Error("Tag does not match app version.");
    for (const [path, actual] of Object.entries(versions())) {
      if (actual !== current) throw new Error(path + " has " + actual + "; expected " + current);
    }
    if (!read("CHANGELOG.md").includes("## [Unreleased]")) throw new Error("CHANGELOG needs Unreleased.");
    entry(current);
    console.log("Version " + current + " matches all app manifests, lockfiles and the changelog.");
  } else if (command === "set") {
    const next = valid(argument);
    const a = next.split(".").map(Number), b = current.split(".").map(Number);
    const first = a.findIndex((value, i) => value !== b[i]);
    if (first >= 0 && a[first] < b[first]) throw new Error("Version must not go backwards.");
    const updates = new Map();
    const pkg = json("package.json"); pkg.version = next;
    const lock = json("package-lock.json"); lock.version = next; lock.packages[""].version = next;
    const config = json("src-tauri/tauri.conf.json"); config.version = next;
    updates.set("package.json", JSON.stringify(pkg, null, 2) + "\n");
    updates.set("package-lock.json", JSON.stringify(lock, null, 2) + "\n");
    updates.set("src-tauri/tauri.conf.json", JSON.stringify(config, null, 2) + "\n");
    for (const [path, regex] of [["src-tauri/Cargo.toml", cargoPattern], ["src-tauri/Cargo.lock", lockPattern]]) {
      const text = read(path); one(text, regex, path);
      updates.set(path, text.replace(regex, (_all, before, _old, after) => before + next + after));
    }
    for (const [path, text] of updates) writeFileSync(resolve(root, path), text);
    console.log("Set " + next + " in all manifests and lockfiles. Add its dated CHANGELOG entry before checking.");
  } else if (command === "notes") {
    process.stdout.write(entry(argument ?? current));
  } else {
    throw new Error("Usage: version.mjs check [--tag vX.Y.Z] | set X.Y.Z | notes [X.Y.Z]");
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
