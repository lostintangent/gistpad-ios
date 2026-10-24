import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { deflateSync } from "node:zlib";

const source = resolve(import.meta.dir, "../../../../documint");
const destination = resolve(import.meta.dir, "../Sources/GistPadDocumintSpike/Resources/Web");
await mkdir(destination, { recursive: true });
const result = await Bun.build({
  entrypoints: [resolve(import.meta.dir, "main.tsx")],
  outdir: destination,
  naming: "editor.js",
  target: "browser",
  format: "esm",
  minify: true,
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  plugins: [{
    name: "local-documint-source",
    setup(build) {
      build.onResolve({ filter: /^@lostintangent\/documint$/ }, () => ({
        path: resolve(source, "src/index.ts"),
      }));
      build.onResolve({ filter: /^react(?:-dom)?(?:\/.*)?$/ }, ({ path }) => ({
        path: Bun.resolveSync(path, source),
      }));
    },
  }],
});
if (!result.success) throw new AggregateError(result.logs, "Documint spike build failed");
await writeFile(resolve(destination, "index.html"), await readFile(resolve(import.meta.dir, "index.html")));
await writeFile(resolve(destination, "pixel.svg"), await readFile(resolve(import.meta.dir, "pixel.svg")));
await writeFile(resolve(destination, "pixel.png"), fixturePNG());
await writeFile(resolve(destination, "parity.md"), await readFile(resolve(import.meta.dir, "parity.md")));
const files = ["src/component/Documint.tsx", "src/component/sync/useDocumentSync.ts",
  "src/markdown/serializer/index.ts", "src/editor/text/fonts.ts"];
await writeFile(resolve(destination, "provenance.json"), JSON.stringify({
  source: "documint/src",
  commit: execFileSync("git", ["rev-parse", "HEAD"], { cwd: source }).toString().trim(),
  sourceDirty: Boolean(execFileSync("git", ["status", "--porcelain", "--untracked-files=no"], {
    cwd: source,
  }).toString().trim()),
  files: Object.fromEntries(await Promise.all(files.map(async (file) => [
    file, createHash("sha256").update(await readFile(resolve(source, file))).digest("hex"),
  ]))),
}, null, 2));
console.log(`Built local Documint source: ${result.outputs.reduce((sum, output) => sum + output.size, 0)} bytes`);

function fixturePNG(): Buffer {
  function chunk(type: string, data: Buffer): Buffer {
    const payload = Buffer.concat([Buffer.from(type), data]);
    let crc = 0xffffffff;
    for (const byte of payload) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    const header = Buffer.alloc(4);
    header.writeUInt32BE(data.length);
    const trailer = Buffer.alloc(4);
    trailer.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([header, payload, trailer]);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(240, 0);
  header.writeUInt32BE(96, 4);
  header[8] = 8;
  header[9] = 2;
  const rows = Buffer.alloc(96 * (240 * 3 + 1));
  for (let y = 0; y < 96; y++) for (let x = 0; x < 240; x++) {
    const offset = y * 721 + 1 + x * 3;
    rows.set(y > 70 - Math.abs(x - 100) / 3 ? [66, 117, 102] : [232, 243, 239], offset);
  }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header), chunk("IDAT", deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]);
}
