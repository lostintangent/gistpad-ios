export function adaptCalculations(source: string, arithmeticModule: string): string {
  const unsafeEvaluation = 'Function(`"use strict"; return (${normalized})`)()';
  if (source.split(unsafeEvaluation).length !== 2) {
    throw new Error("Web calculator changed. Review its CSP adapter before rebuilding.");
  }
  return `import { evaluateArithmetic } from ${JSON.stringify(arithmeticModule)};\n` +
    source.replace(unsafeEvaluation, "evaluateArithmetic(normalized)");
}
