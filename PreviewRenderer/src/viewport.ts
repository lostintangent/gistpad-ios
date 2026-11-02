export interface ViewportInsets {
  top: number;
  bottom: number;
}

export function setViewportInsets(insets: ViewportInsets) {
  document.documentElement.style.scrollPaddingTop = `${insets.top}px`;
  document.documentElement.style.scrollPaddingBottom = `${insets.bottom}px`;
}
