import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import * as schema from "./schema";

export function getDb(database: Parameters<typeof drizzle>[0] = env.DB) {
  if (!database) {
    throw new Error("Cloudflare D1 binding `DB` is unavailable.");
  }
  return drizzle(database, { schema });
}
