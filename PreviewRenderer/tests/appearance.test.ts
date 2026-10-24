import { expect, test } from "bun:test";
import { validateAppearance } from "../src/appearance";

function nativeAppearance(alpha = "1.0") {
  const colors = ["page", "surface", "surface-raised", "text", "syntax-code", "text-secondary", "link",
    "separator", "boundary", "error", "success", "accent-text", "accent-fill", "on-accent", "selected-surface"];
  const metrics = ["body-size", "body-line-height", "title1-size", "title1-line-height",
    "title2-size", "title2-line-height", "title3-size", "title3-line-height",
    "headline-size", "headline-line-height", "footnote-size", "footnote-line-height", "code-size"];
  return {
    variables: Object.fromEntries([
      ...colors.map((name) => [`--gp-${name}`, `rgba(255,255,255,${alpha})`]),
      ...metrics.map((name) => [`--gp-${name}`, "22.5px"]),
    ]),
    boldText: false,
    increasedContrast: false,
    colorScheme: "light",
  };
}

test("accepts native CGFloat opacity serialization", () => {
  for (const alpha of ["1", "1.0", "0", "0.0", "0.22"]) {
    expect(() => validateAppearance(nativeAppearance(alpha))).not.toThrow();
  }
});

test("rejects incomplete or executable appearance values", () => {
  expect(() => validateAppearance({})).toThrow();
  expect(() => validateAppearance(nativeAppearance("2.0"))).toThrow();
  const appearance = nativeAppearance();
  appearance.variables["--gp-page"] = "url(https://example.com)";
  expect(() => validateAppearance(appearance)).toThrow();
  const incomplete = nativeAppearance();
  delete incomplete.variables["--gp-syntax-code"];
  expect(() => validateAppearance(incomplete)).toThrow();
});
