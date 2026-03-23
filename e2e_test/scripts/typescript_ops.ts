// TypeScript with type annotations
interface User {
  name: string;
  age: number;
  active: boolean;
}

const users: User[] = [
  { name: "Alice", age: 30, active: true },
  { name: "Bob", age: 25, active: false },
  { name: "Charlie", age: 35, active: true },
];

const activeUsers: User[] = users.filter((u: User) => u.active);
const names: string[] = activeUsers.map((u: User) => u.name);
const totalAge: number = users.reduce((sum: number, u: User) => sum + u.age, 0);

const result = { activeNames: names, totalAge, count: users.length };
result;
