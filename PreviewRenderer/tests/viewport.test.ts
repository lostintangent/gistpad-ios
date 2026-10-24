import { expect, test } from "bun:test";
import { validateViewportInsets } from "../src/viewport";

test("accepts only bounded native viewport inset numbers", () => {
  for (const insets of [{ top: 0, bottom: 0 }, { top: 64, bottom: 82.5 }, { top: 10_000, bottom: 0 }]) {
    expect(validateViewportInsets(insets)).toEqual(insets);
  }
  for (const insets of [
    null, {}, { top: 1 }, { top: "64px", bottom: 0 }, { top: -1, bottom: 0 },
    { top: Infinity, bottom: 0 }, { top: 0, bottom: NaN }, { top: 0, bottom: 10_001 },
  ]) {
    expect(() => validateViewportInsets(insets)).toThrow();
  }
});
