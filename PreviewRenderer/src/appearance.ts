export type RGB = [number, number, number];

export function contrastRatio(left: RGB, right: RGB): number {
  const luminance = (color: RGB) => color.map((channel) => {
    const value = channel / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
  const first = luminance(left);
  const second = luminance(right);
  return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

export interface Appearance {
  variables: Record<string, string>;
  increasedContrast: boolean;
  boldText: boolean;
  colorScheme: "light" | "dark";
}

export function setAppearance(appearance: Appearance) {
  for (const [name, value] of Object.entries(appearance.variables)) {
    document.documentElement.style.setProperty(name, value);
  }
  document.documentElement.dataset.contrast = appearance.increasedContrast ? "increased" : "normal";
  document.documentElement.dataset.boldText = appearance.boldText ? "true" : "false";
  document.documentElement.dataset.colorScheme = appearance.colorScheme;
  document.documentElement.style.colorScheme = appearance.colorScheme;
  window.dispatchEvent(new Event("gistpad-preview-appearance"));
}
