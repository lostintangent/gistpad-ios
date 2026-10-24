import { parseDocument, serializeDocument } from "../../../../documint/src/markdown/index";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const directory = process.argv[2];
if (!directory?.startsWith("/tmp/")) throw new Error("Use a private /tmp directory for personal notes");
await mkdir(resolve(directory, "outputs"), { recursive: true });
const results = [];
for (const name of ["manga", "daily", "oss"]) {
  const source = await readFile(resolve(directory, `${name}.md`), "utf8");
  const parsed = parseDocument(source);
  const canonical = serializeDocument(parsed);
  const preamble = (value: string) => value.match(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/)?.[0] ?? null;
  await writeFile(resolve(directory, "outputs", `${name}-canonical.md`), canonical);
  const diff = spawnSync("git", ["diff", "--no-index", "--numstat",
    resolve(directory, `${name}.md`), resolve(directory, "outputs", `${name}-canonical.md`)],
  { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (diff.error || (diff.status !== 0 && diff.status !== 1)) {
    throw diff.error ?? new Error(diff.stderr);
  }
  results.push({ name, sourceBytes: Buffer.byteLength(source), canonicalBytes: Buffer.byteLength(canonical),
    byteIdentical: source === canonical, changedLines: diff.stdout.split("\t").slice(0, 2),
    sourceInsTags: (source.match(/<ins>/g) ?? []).length,
    outputInsTags: (canonical.match(/<ins>/g) ?? []).length,
    metadata: parsed.metadata === null ? "absent" : "present",
    frontMatterByteIdentical: preamble(source) === preamble(canonical) });
}
console.log(JSON.stringify(results, null, 2));
