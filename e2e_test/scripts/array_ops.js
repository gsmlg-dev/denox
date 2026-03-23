// Array operations
const numbers = [1, 2, 3, 4, 5];
const result = {
  map: numbers.map(n => n * 2),
  filter: numbers.filter(n => n > 3),
  reduce: numbers.reduce((a, b) => a + b, 0),
  flat: [[1, 2], [3, 4]].flat(),
  find: numbers.find(n => n === 3),
};
result;
