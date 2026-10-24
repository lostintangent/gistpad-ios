import { useSyncExternalStore } from "react";
import type { MermaidConfig } from "mermaid";

type RGB = [number, number, number];

export function contrastRatio(left: RGB, right: RGB): number {
  const luminance = (color: RGB) => color.map((channel) => {
    const value = channel / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
  const first = luminance(left);
  const second = luminance(right);
  return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

function color(value: string, backdrop: RGB, dark: boolean): RGB {
  const fallback = /^light-dark\((#[a-f\d]{3,6}),\s*(#[a-f\d]{3,6})\)$/i.exec(value);
  if (fallback) return color(fallback[dark ? 2 : 1], backdrop, dark);
  const hex = /^#([a-f\d]{6}|[a-f\d]{3})$/i.exec(value);
  if (hex) {
    const expanded = hex[1].length === 3 ? [...hex[1]].map((digit) => digit + digit).join("") : hex[1];
    return [parseInt(expanded.slice(0, 2), 16), parseInt(expanded.slice(2, 4), 16), parseInt(expanded.slice(4, 6), 16)];
  }
  const rgba = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(value);
  if (!rgba) throw new TypeError(`Unsupported native diagram color: ${value}`);
  const alpha = Number(rgba[4] ?? 1);
  const channel = (index: number) =>
    Math.round(Number(rgba[index]) * alpha + backdrop[index - 1] * (1 - alpha));
  return [channel(1), channel(2), channel(3)];
}

function resolvedTheme() {
  const root = document.documentElement;
  const styles = getComputedStyle(root);
  const dark = root.dataset.colorScheme
    ? root.dataset.colorScheme === "dark"
    : window.matchMedia("(prefers-color-scheme: dark)").matches;
  const page = color(styles.backgroundColor, [255, 255, 255], dark);
  const read = (name: string, backdrop: RGB) => color(styles.getPropertyValue(name).trim(), backdrop, dark);
  const surface = read("--gp-surface", page);
  const text = read("--gp-text", surface);
  const separator = read("--gp-separator", surface);
  const edge = read("--gp-accent-text", page);
  const passes = (candidate: RGB) => [surface, page].every((background) => contrastRatio(candidate, background) >= 3);
  const mix = (amount: number): RGB => {
    const channel = (index: number) => Math.round(separator[index] * (1 - amount) + text[index] * amount);
    return [channel(0), channel(1), channel(2)];
  };
  let stroke = separator;
  if (!passes(stroke)) {
    if (!passes(text)) throw new RangeError("Native diagram ink cannot establish an accessible boundary.");
    let lower = 0;
    let upper = 1;
    for (let index = 0; index < 32; index++) {
      const middle = (lower + upper) / 2;
      if (passes(mix(middle))) upper = middle;
      else lower = middle;
    }
    stroke = mix(upper);
  }
  if (!passes(edge)) throw new RangeError("Native diagram edges do not meet the required 3:1 contrast.");
  return { dark, page, surface, text, stroke, edge };
}

const hex = (color: RGB) => "#" + color.map((value) => value.toString(16).padStart(2, "0")).join("");

export function nativeDiagramTheme(): Pick<MermaidConfig, "theme" | "themeVariables" | "themeCSS"> {
  const { dark, page, surface, text, stroke, edge } = resolvedTheme();
  return {
    theme: "base",
    themeCSS: ".node > rect:not([rx]):not([ry]) { rx: 10px; ry: 10px; }",
    themeVariables: {
      darkMode: dark,
      background: hex(page),
      primaryColor: hex(surface),
      primaryTextColor: hex(text),
      primaryBorderColor: hex(stroke),
      noteBkgColor: hex(surface),
      noteTextColor: hex(text),
      noteBorderColor: hex(stroke),
      secondaryColor: hex(surface),
      secondaryTextColor: hex(text),
      secondaryBorderColor: hex(stroke),
      tertiaryColor: hex(surface),
      tertiaryTextColor: hex(text),
      tertiaryBorderColor: hex(stroke),
      lineColor: hex(edge),
      textColor: hex(text),
      mainBkg: hex(surface),
      nodeBorder: hex(stroke),
      clusterBkg: hex(surface),
      clusterBorder: hex(stroke),
      edgeLabelBackground: hex(page),
      defaultLinkColor: hex(edge),
      arrowheadColor: hex(edge),
      actorBorder: hex(stroke),
      actorLineColor: hex(edge),
      actorTextColor: hex(text),
      signalColor: hex(edge),
      signalTextColor: hex(text),
      activationBorderColor: hex(stroke),
      labelBoxBorderColor: hex(stroke),
      labelTextColor: hex(text),
      loopTextColor: hex(text),
      fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
      fontSize: "16px",
    },
  };
}

export const nativeDiagramThemeKey = () => JSON.stringify(resolvedTheme());

export function useDiagramTheme() {
  return useSyncExternalStore((notify) => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    window.addEventListener("gistpad-preview-appearance", notify);
    media.addEventListener("change", notify);
    return () => {
      window.removeEventListener("gistpad-preview-appearance", notify);
      media.removeEventListener("change", notify);
    };
  }, nativeDiagramThemeKey, () => "native-diagram");
}
