// Run in WSL. Every rendered identity asset comes from the approved SVG.
import { cpSync, copyFileSync, mkdtempSync, readFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";

const root = fileURLToPath(new URL("../", import.meta.url));
const require = createRequire(import.meta.url);
const manifestPath = require.resolve("@tauri-apps/cli/package.json");
const { bin } = JSON.parse(readFileSync(manifestPath, "utf8"));
const cli = resolve(dirname(manifestPath), typeof bin === "string" ? bin : bin.tauri);
const source = join(root, "assets/branding/viby-icon.svg");
const scratch = mkdtempSync(join(tmpdir(), "viby-icons-"));
function generate(...args) {
  const result = spawnSync(process.execPath, [cli, "icon", source, ...args], {
    cwd: root,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error("Tauri icon generation failed: " + result.status);
}
try {
  const standard = join(scratch, "standard");
  const raster = join(scratch, "raster");
  generate("--output", standard);
  generate("--output", raster, "--png", "64", "--png", "2048");
  const target = join(root, "src-tauri/icons");
  mkdirSync(target, { recursive: true });
  cpSync(standard, target, { recursive: true, force: true });
  copyFileSync(join(raster, "64x64.png"), join(target, "64x64.png"));
  copyFileSync(join(raster, "2048x2048.png"), join(root, "assets/branding/viby-icon.png"));
  console.log("Generated native/platform icons and 2048px PNG from assets/branding/viby-icon.svg.");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
