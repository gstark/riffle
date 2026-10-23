// Helpers shared by the Lambda entry points and scripts.

export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

export function log(message: string): void {
  console.log(`${new Date().toISOString()} ${message}`);
}
