// String manipulation
const greeting = "Hello";
const target = "World";
const result = {
  concat: greeting + ", " + target + "!",
  upper: greeting.toUpperCase(),
  lower: target.toLowerCase(),
  length: greeting.length,
  includes: "Hello, World!".includes("World"),
  split: "a,b,c".split(","),
};
result;
