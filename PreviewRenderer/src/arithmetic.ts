/** Evaluates only the web calculator's already-normalized arithmetic, without executable code. */
export function evaluateArithmetic(source: string): number {
  if (!/^[-+*/().\d\s]+$/.test(source)) {
    throw new SyntaxError("Unsupported arithmetic");
  }
  source = source.replace(/\/\*[\s\S]*?\*\//g, " ");
  source = source.replace(/\/\/[^\r\n]*(?=[\r\n])/g, " ");
  if (/\+\+|--|\/[*/]/.test(source)) throw new SyntaxError("Invalid arithmetic operator");
  const tokens = source.match(/\d+(?:\.\d*)?|\.\d+|\*\*|[-+*/()]/g) ?? [];
  if (tokens.join("") !== source.replace(/\s/g, "")) throw new SyntaxError("Invalid arithmetic");
  let index = 0;
  const peek = () => tokens[index];
  const take = () => tokens[index++];

  function primary(): number {
    const token = take();
    if (token === "(") {
      const value = sum();
      if (take() !== ")") throw new SyntaxError("Unclosed parenthesis");
      return value;
    }
    if (!token || !/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(token)) {
      throw new SyntaxError("Expected a number");
    }
    return Number(token);
  }

  function power(): number {
    const value = primary();
    if (peek() !== "**") return value;
    take();
    return value ** unary();
  }

  function unary(): number {
    if (peek() !== "+" && peek() !== "-") return power();
    const sign = take() === "-" ? -1 : 1;
    const value = peek() === "+" || peek() === "-" ? unary() : primary();
    if (peek() === "**") throw new SyntaxError("Unary expression before exponentiation");
    return sign * value;
  }

  function product(): number {
    let value = unary();
    while (peek() === "*" || peek() === "/") {
      const operator = take();
      const right = unary();
      value = operator === "*" ? value * right : value / right;
    }
    return value;
  }

  function sum(): number {
    let value = product();
    while (peek() === "+" || peek() === "-") {
      const operator = take();
      const right = product();
      value = operator === "+" ? value + right : value - right;
    }
    return value;
  }

  const value = sum();
  if (index !== tokens.length) throw new SyntaxError("Unexpected arithmetic token");
  return value;
}
