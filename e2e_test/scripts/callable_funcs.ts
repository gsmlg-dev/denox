// TypeScript functions exposed to globalThis for calling from Elixir
(globalThis as any).shout = (s: string): string => s.toUpperCase();
(globalThis as any).isEven = (n: number): boolean => n % 2 === 0;
