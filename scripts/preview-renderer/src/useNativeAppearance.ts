import { useSyncExternalStore } from "react";

const media = () => window.matchMedia("(prefers-color-scheme: dark)");
const subscribe = (notify: () => void) => {
  const query = media();
  window.addEventListener("gistpad-preview-appearance", notify);
  query.addEventListener("change", notify);
  return () => {
    window.removeEventListener("gistpad-preview-appearance", notify);
    query.removeEventListener("change", notify);
  };
};
const snapshot = () => {
  const nativeScheme = document.documentElement.dataset.colorScheme;
  return nativeScheme ? nativeScheme === "dark" : media().matches;
};

/** Keeps the unmodified web Mermaid component on the native host's resolved appearance. */
export const useIsDarkMode = () => useSyncExternalStore(subscribe, snapshot, () => false);
