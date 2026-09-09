import { build } from "esbuild";
import { mkdir } from "node:fs/promises";
await mkdir(".lan", { recursive: true });
await build({
  entryPoints: ["server/index.ts"],
  outfile: ".lan/server.mjs",
  bundle: true,
  platform: "node",
  format: "esm",
  packages: "external",
  alias: {
    "@dimforge/rapier3d-compat": "@dimforge/rapier3d-compat/rapier.es.js",
  },
});
await import("../.lan/server.mjs");
