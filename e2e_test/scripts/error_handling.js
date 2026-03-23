// Error handling with try/catch
function safeDivide(a, b) {
  if (b === 0) throw new Error("Division by zero");
  return a / b;
}

let caught = false;
try {
  safeDivide(10, 0);
} catch (e) {
  caught = true;
}

const result = {
  normalDivision: safeDivide(10, 2),
  caughtError: caught,
};
result;
