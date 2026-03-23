// Async operations
const delay = (ms) => new Promise(resolve => setTimeout(resolve, ms));

await delay(10);

const results = await Promise.all([
  Promise.resolve(1),
  Promise.resolve(2),
  Promise.resolve(3),
]);

export default { sum: results.reduce((a, b) => a + b, 0), count: results.length };
