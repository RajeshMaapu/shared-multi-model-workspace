import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const STALE = "Web validation missing or stale; revalidate before Electron carry-over";

const REQUIRED_FRESH_CHECKS = [
  "full_layout_1586x992",
  "compact_980x680",
  "no_generation_suffix_in_system_messages",
  "options_reset_after_create",
  "requested_peers_honored",
];

const fail = () => { throw new Error(STALE); };

const sha256 = (path) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");

export function assertWebValidated(root) {
  let manifest;
  try {
    manifest = JSON.parse(
      readFileSync(join(root, "Web", "web-validation.json"), "utf8"));
  } catch {
    fail();
  }
  if (manifest === null || typeof manifest !== "object"
      || manifest.result !== "passed") {
    fail();
  }
  const expected = manifest.renderer_file_sha256;
  if (expected === null || typeof expected !== "object"
      || Array.isArray(expected)) {
    fail();
  }
  const rendererDir = join(root, "Web", "renderer");
  let files;
  try {
    files = readdirSync(rendererDir)
      .filter((name) => /\.(js|html|css)$/.test(name));
  } catch {
    fail();
  }
  if (JSON.stringify(files.slice().sort())
      !== JSON.stringify(Object.keys(expected).sort())) {
    fail();
  }
  for (const [name, hash] of Object.entries(expected)) {
    if (typeof hash !== "string" || sha256(join(rendererDir, name)) !== hash) {
      fail();
    }
  }
  if (typeof manifest.reference !== "string"
      || !existsSync(join(root, manifest.reference))) {
    fail();
  }
  if (typeof manifest.evidence !== "string"
      || !existsSync(join(root, manifest.evidence))) {
    fail();
  }
  if (!Array.isArray(manifest.screenshots)
      || manifest.screenshots.length === 0) {
    fail();
  }
  for (const shot of manifest.screenshots) {
    if (typeof shot !== "string" || !existsSync(join(root, shot))) {
      fail();
    }
  }
  let evidence;
  try {
    evidence = JSON.parse(readFileSync(join(root, manifest.evidence), "utf8"));
  } catch {
    fail();
  }
  const evidenceHashes = evidence && evidence.renderer_file_sha256;
  if (evidenceHashes === null || typeof evidenceHashes !== "object"
      || JSON.stringify(Object.keys(evidenceHashes).sort())
        !== JSON.stringify(Object.keys(expected).sort())) {
    fail();
  }
  for (const [name, hash] of Object.entries(expected)) {
    if (evidenceHashes[name] !== hash) {
      fail();
    }
  }
  const checks = evidence && evidence.checks;
  if (checks === null || typeof checks !== "object") {
    fail();
  }
  for (const name of REQUIRED_FRESH_CHECKS) {
    const check = checks[name];
    if (check === null || typeof check !== "object"
        || check.result !== "pass" || check.fresh !== true) {
      fail();
    }
  }
}
