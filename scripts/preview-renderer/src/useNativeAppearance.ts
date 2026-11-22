import { useSyncExternalStore } from "react";

const subscribe = (notify: () => void) => {
  window.addEventListener("gistpad-preview-appearance", notify);
  return () => window.removeEventListener("gistpad-preview-appearance", notify);
};
const snapshot = () => document.documentElement.dataset.colorScheme === "dark";

/** Keeps the unmodified web Mermaid component on the native host's resolved appearance. */
export const useIsDarkMode = () => useSyncExternalStore(subscribe, snapshot);
