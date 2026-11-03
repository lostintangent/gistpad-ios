import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { evaluateMathExpression as webEvaluate, extractVariableAssignments as webAssignments } from "../../../../gistpad.dev/src/shared/calculations";
import { adaptCalculations } from "../src/calculatorAdapter";

const source = readFileSync(new URL("../../../../gistpad.dev/src/shared/calculations.ts", import.meta.url), "utf8");
const transformed = new Bun.Transpiler({ loader: "ts" }).transformSync(
  adaptCalculations(source, fileURLToPath(new URL("../src/arithmetic.ts", import.meta.url))),
);
const native = await import(`data:text/javascript;base64,${Buffer.from(transformed).toString("base64")}`) as {
  evaluateMathExpression: typeof webEvaluate;
  extractVariableAssignments: typeof webAssignments;
};

describe("shared web calculator under a strict CSP", () => {
  test("matches web results and null cases", () => {
    const expressions = [
      "08", "010", "00.5", "--1", "1/0", "0/0", "1++2", "1--2", "-2",
      "2 ** 3", "-2 ** 2", "2 ** -2", "(-2) ** 2", "1 /*2*/ + 3",
      ".5 + 2.", "1,000 + $5", "$5 * 3", "2k * 3", "2M / 5",
      "(2 + 3) * 4", "1 - - 2", "1e3", "constructor", "alert(1)", "1;2",
      "_ + 2", "price * 3", "", "(", "2(3)", "1..2",
    ];
    for (const expression of expressions) {
      expect(native.evaluateMathExpression(expression, "15", new Map([["price", "$5.00"]]))).toBe(
        webEvaluate(expression, "15", new Map([["price", "$5.00"]])),
      );
    }
  });

  test("matches arithmetic combinations", () => {
    for (let left = -12; left <= 12; left++) {
      for (let right = -12; right <= 12; right++) {
        for (const operator of ["+", "-", "*", "/"]) {
          const expression = `(${left}) ${operator} (${right})`;
          expect(native.evaluateMathExpression(expression)).toBe(webEvaluate(expression));
        }
      }
    }
  });

  test("keeps assignment and currency formatting", () => {
    for (const line of ["rate := $5", "- daily rate := $1,200", "count := 2k", "a := 2 b := 3"]) {
      expect(native.extractVariableAssignments(line)).toEqual(webAssignments(line));
    }
  });

  test("fails closed when the upstream evaluation call changes", () => {
    expect(() => adaptCalculations("changed upstream source", "arithmetic.ts")).toThrow();
  });
});
