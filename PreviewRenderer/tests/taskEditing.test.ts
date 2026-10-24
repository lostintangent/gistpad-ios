import { expect, test } from "bun:test";
import { isTaskEditingEnabled, setTaskEditingEnabled } from "../src/taskEditing";

test("task editing capability accepts only explicit booleans", () => {
  setTaskEditingEnabled(false);
  expect(isTaskEditingEnabled()).toBe(false);
  for (const value of [undefined, null, 0, 1, "true", {}, []]) {
    expect(() => setTaskEditingEnabled(value)).toThrow(TypeError);
    expect(isTaskEditingEnabled()).toBe(false);
  }
  setTaskEditingEnabled(true);
  expect(isTaskEditingEnabled()).toBe(true);
});
