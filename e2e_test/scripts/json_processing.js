// JSON parse and stringify round-trip
const input = '{"items":[{"id":1,"value":"a"},{"id":2,"value":"b"}]}';
const parsed = JSON.parse(input);
const transformed = {
  ...parsed,
  items: parsed.items.map(item => ({ ...item, value: item.value.toUpperCase() })),
  count: parsed.items.length,
};
const roundTripped = JSON.parse(JSON.stringify(transformed));
roundTripped;
