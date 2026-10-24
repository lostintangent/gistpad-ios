import { useSyncExternalStore } from "react";

let enabled = true;
const listeners = new Set<() => void>();

export const isTaskEditingEnabled = () => enabled;

export function setTaskEditingEnabled(value: unknown) {
  if (typeof value !== "boolean") throw new TypeError("Invalid task editing capability");
  if (enabled === value) return;
  enabled = value;
  for (const notify of listeners) notify();
}

function subscribe(notify: () => void) {
  listeners.add(notify);
  return () => { listeners.delete(notify); };
}

export function useTaskEditingEnabled() {
  return useSyncExternalStore(subscribe, isTaskEditingEnabled, isTaskEditingEnabled);
}
