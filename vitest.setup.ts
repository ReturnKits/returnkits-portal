// Loads .env.test.local (gitignored — local Supabase keys only, never
// committed) before the RLS suite runs. See .env.test.local.example.
import { config } from "dotenv";

config({ path: ".env.test.local" });
