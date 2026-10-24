import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { contrastRatio } from "../src/diagramTheme";
import { adaptMermaid } from "../src/mermaidAdapter";

test("diagram contrast calculation measures the required boundary", () => {
  expect(contrastRatio([0, 0, 0], [255, 255, 255])).toBe(21);
  expect(contrastRatio([255, 255, 255], [255, 255, 255])).toBe(1);
  expect(contrastRatio([99, 99, 102], [242, 242, 247])).toBeGreaterThan(3);
  expect(contrastRatio([174, 174, 178], [28, 28, 30])).toBeGreaterThan(3);
});

test("native Mermaid adapter preserves strict mode and authored source", () => {
  const source = readFileSync(new URL("../../../gistpad.dev/src/features/markdown/Mermaid.tsx", import.meta.url), "utf8");
  const adapted = adaptMermaid(source, "native-theme");
  expect(adapted).toContain('securityLevel: "strict"');
  expect(adapted).toContain("...nativeDiagramTheme()");
  expect(adapted).toContain("nativeDiagramThemeKey()");
  expect(adapted).toContain("await mermaid.parse(content)");
  expect(adapted).toContain("content, isDarkMode");
  expect(() => adaptMermaid("changed upstream component", "native-theme")).toThrow();
});
