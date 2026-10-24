const colorNames = [
  "page", "surface", "surface-raised", "text", "syntax-code", "text-secondary", "link",
  "separator", "boundary", "error", "success", "accent-text", "accent-fill", "on-accent", "selected-surface",
];
const metricNames = [
  "body-size", "body-line-height", "title1-size", "title1-line-height",
  "title2-size", "title2-line-height", "title3-size", "title3-line-height",
  "headline-size", "headline-line-height", "footnote-size", "footnote-line-height", "code-size",
];

export function validateAppearance(value: unknown): asserts value is {
  variables: Record<string, string>; increasedContrast: boolean; boldText: boolean; colorScheme: "light" | "dark";
} {
  if (!value || typeof value !== "object") throw new TypeError("Invalid preview appearance");
  const data = value as { variables?: Record<string, unknown>; increasedContrast?: unknown; boldText?: unknown; colorScheme?: unknown };
  if (!data.variables || typeof data.variables !== "object" ||
      typeof data.increasedContrast !== "boolean" || typeof data.boldText !== "boolean" ||
      (data.colorScheme !== "light" && data.colorScheme !== "dark")) {
    throw new TypeError("Invalid preview appearance");
  }
  for (const name of [...colorNames, ...metricNames]) {
    const entry = data.variables[`--gp-${name}`];
    if (typeof entry !== "string" ||
        (colorNames.includes(name)
          ? !/^(?:#[0-9a-f]{6}|rgba\(\d{1,3},\d{1,3},\d{1,3},(?:0(?:\.\d+)?|1(?:\.0+)?|\.\d+)\))$/i.test(entry)
          : !/^\d+(?:\.\d+)?px$/.test(entry) || parseFloat(entry) < 1 || parseFloat(entry) > 300)) {
      throw new TypeError(`Invalid preview appearance variable: ${name}`);
    }
  }
}

export function setAppearance(value: unknown) {
  validateAppearance(value);
  for (const name of [...colorNames, ...metricNames]) {
    document.documentElement.style.setProperty(`--gp-${name}`, value.variables[`--gp-${name}`]);
  }
  document.documentElement.dataset.contrast = value.increasedContrast ? "increased" : "normal";
  document.documentElement.dataset.boldText = value.boldText ? "true" : "false";
  document.documentElement.dataset.colorScheme = value.colorScheme;
  document.documentElement.style.colorScheme = value.colorScheme;
  window.dispatchEvent(new Event("gistpad-preview-appearance"));
}
