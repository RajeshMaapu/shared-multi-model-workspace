import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync }
  from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { assertWebValidated } from "./web-validation.mjs";
import { prepareIcon } from "./icon.mjs";

const DESKTOP_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(DESKTOP_DIR);

assertWebValidated(ROOT);

const daemon = path.join(ROOT, ".build", "debug", "workshop-daemon");
const mcp = path.join(ROOT, ".build", "debug", "workshop-mcp");
for (const required of [daemon, mcp]) {
  if (!existsSync(required)) {
    throw new Error(`Required packaging input missing: ${required}`);
  }
}

const icon = prepareIcon(ROOT);

const stamp = Date.now();
const stage = path.join(ROOT, ".build", `desktop-stage-${stamp}`);
if (existsSync(stage)) {
  throw new Error(`Refusing to overwrite existing staging dir: ${stage}`);
}
const out = path.join(ROOT, "dist", `desktop-preview-${stamp}`);
if (existsSync(out)) {
  throw new Error(`Refusing to overwrite existing output: ${out}`);
}

const manifest = JSON.parse(readFileSync(
  path.join(ROOT, "package.json"), "utf8"));
const stagedManifest = {
  name: manifest.name,
  version: manifest.version,
  private: true,
  type: "module",
  main: "Desktop/main.mjs",
};

mkdirSync(path.join(stage, "Desktop"), { recursive: true });
mkdirSync(path.join(stage, "Web"), { recursive: true });
writeFileSync(path.join(stage, "package.json"),
  JSON.stringify(stagedManifest, null, 2) + "\n");
for (const file of [
  "main.mjs", "preload.cjs", "ipc-policy.mjs",
]) {
  cpSync(path.join(DESKTOP_DIR, file), path.join(stage, "Desktop", file));
}
for (const file of ["rpc-client.mjs", "task-api.mjs"]) {
  cpSync(path.join(ROOT, "Web", file), path.join(stage, "Web", file));
}
cpSync(path.join(ROOT, "Web", "renderer"),
  path.join(stage, "Web", "renderer"), { recursive: true });
cpSync(path.join(ROOT, "Web", "web-validation.json"),
  path.join(stage, "Web", "web-validation.json"));

mkdirSync(out, { recursive: true });
const { packager } = await import("@electron/packager");
if (typeof packager !== "function") {
  throw new Error("@electron/packager did not expose a packager function");
}

const paths = await packager({
  electronVersion: manifest.devDependencies.electron,
  dir: stage,
  out,
  platform: "darwin",
  arch: "arm64",
  appBundleId: "ai.maapu.workshop.community-preview",
  appVersion: "0.2.0",
  name: "Workshop Preview",
  icon,
  asar: true,
  overwrite: false,
  extraResource: [daemon, mcp],
  osxSign: false,
  osxNotarize: false,
});

console.log("PACKAGED " + JSON.stringify({ stage, paths }));
