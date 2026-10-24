export interface ViewportInsets {
  top: number;
  bottom: number;
}

export function validateViewportInsets(value: unknown): ViewportInsets {
  if (!value || typeof value !== "object") throw new TypeError("Invalid preview viewport insets");
  const data = value as Partial<ViewportInsets>;
  if (typeof data.top !== "number" || !Number.isFinite(data.top) || data.top < 0 || data.top > 10_000 ||
    typeof data.bottom !== "number" || !Number.isFinite(data.bottom) || data.bottom < 0 || data.bottom > 10_000) {
    throw new TypeError("Invalid preview viewport insets");
  }
  return { top: data.top, bottom: data.bottom };
}

export function setViewportInsets(value: unknown) {
  const insets = validateViewportInsets(value);
  document.documentElement.style.scrollPaddingTop = `${insets.top}px`;
  document.documentElement.style.scrollPaddingBottom = `${insets.bottom}px`;
}
