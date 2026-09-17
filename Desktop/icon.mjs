import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";

const SIZES = [16, 32, 64, 128, 256, 512, 1024];

export function prepareIcon(root) {
  const master = path.join(root, "Web", "renderer", "assets",
    "workshop-icon.png");
  if (!existsSync(master)) {
    throw new Error(`Icon master missing: ${master}`);
  }
  const base = path.join(root, ".build", "desktop-assets");
  const stamp = Date.now();
  const iconset = path.join(base, `iconset-${stamp}.iconset`);
  const icns = path.join(base, `workshop-${stamp}.icns`);
  mkdirSync(iconset, { recursive: true });
  for (const size of SIZES) {
    execFileSync("/usr/bin/sips",
      ["-z", String(size), String(size), master,
        "--out", path.join(iconset, `icon_${size}x${size}.png`)],
      { stdio: "pipe" });
  }
  execFileSync("/usr/bin/iconutil",
    ["-c", "icns", "-o", icns, iconset], { stdio: "pipe" });
  if (!existsSync(icns)) {
    throw new Error("iconutil did not produce an icns file");
  }
  return icns;
}
