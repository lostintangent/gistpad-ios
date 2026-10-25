import { createHash } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin } from "vite";
import { adaptCalculations } from "./src/calculatorAdapter";
import { adaptMermaid } from "./src/mermaidAdapter";

const root = fileURLToPath(new URL(".", import.meta.url));
const web = realpathSync(resolve(root, "../../gistpad.dev"));
const sourceFiles = [
  "features/markdown/MarkdownPreview.tsx",
  "features/markdown/remarkInlineSyntax.ts",
  "features/markdown/rehypeToc.ts",
  "features/markdown/Mermaid.tsx",
  "features/markdown/index.css",
  "shared/calculations.ts",
];

function webSourceAdapter(): Plugin {
  const adapted = new Set<string>();
  return {
    name: "gistpad-web-source-adapter",
    enforce: "pre",
    transform(code, id) {
      if (id === resolve(web, "src/shared/calculations.ts")) {
        adapted.add("calculations");
        return { code: adaptCalculations(code, resolve(root, "src/arithmetic.ts")), map: null };
      }
      if (id === resolve(web, "src/features/markdown/Mermaid.tsx")) {
        adapted.add("mermaid");
        return { code: adaptMermaid(code, resolve(root, "src/diagramTheme.ts")), map: null };
      }
    },
    generateBundle() {
      if (!adapted.has("calculations") || !adapted.has("mermaid")) {
        throw new Error("Required offline web-source adapters did not run. Check resolved source paths.");
      }
      this.emitFile({
        type: "asset",
        fileName: "provenance.json",
        source: JSON.stringify(
          {
            source: "gistpad.dev/src",
            adapters: [
              "Function arithmetic evaluation replaced with a non-executable parser",
              "Mermaid media-query hook bound to the native appearance payload",
              "Mermaid default theme/cache key use resolved native colors without changing authored styles",
            ],
            files: Object.fromEntries(
              sourceFiles.map((file) => [
                file,
                createHash("sha256").update(readFileSync(resolve(web, "src", file))).digest("hex"),
              ]),
            ),
          },
          null,
          2,
        ),
      });
    },
  };
}

export default defineConfig({
  plugins: [webSourceAdapter()],
  base: "./",
  resolve: {
    alias: {
      "@/shared/useMediaQuery": resolve(root, "src/useNativeAppearance.ts"),
      "@": resolve(web, "src"),
      "@web": resolve(web, "src"),
      "@gistpad/rehype-toc": resolve(web, "src/features/markdown/rehypeToc.ts"),
    },
    dedupe: ["react", "react-dom", "@tanstack/react-query"],
  },
  build: {
    target: "safari18",
    outDir: "../Packages/GistPadPreview/Sources/GistPadPreview/Resources/Web",
    emptyOutDir: true,
    cssCodeSplit: false,
    sourcemap: false,
  },
});
