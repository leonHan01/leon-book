import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const storageScript = path.join(projectRoot, "scripts", "local-storage-server.mjs");
const nextExecutable = path.join(projectRoot, "node_modules", ".bin", "next");
const production = process.argv[2] === "--production";
const forwardedArguments = process.argv.slice(production ? 3 : 2);
const storagePort = Number(process.env.BLOG_STORAGE_PORT ?? 8787);
const storageURL = process.env.BLOG_STORAGE_URL ?? `http://127.0.0.1:${storagePort}`;
const childEnv = {
  ...process.env,
  BLOG_STORAGE_HOST: "127.0.0.1",
  BLOG_STORAGE_PORT: String(storagePort),
  BLOG_STORAGE_URL: storageURL,
};

const storage = spawn(process.execPath, [storageScript], {
  cwd: projectRoot,
  env: childEnv,
  stdio: "inherit",
});

let frontend;
let shuttingDown = false;

async function waitForStorage() {
  const statusURL = new URL("/api/status", storageURL);
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (storage.exitCode !== null) throw new Error("Local storage service stopped before startup");
    try {
      const response = await fetch(statusURL, { signal: AbortSignal.timeout(500) });
      if (response.ok) return;
    } catch {
      // The service normally needs a few attempts to create its local folders.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Local storage service did not become ready");
}

function shutdown(signal = "SIGTERM") {
  if (shuttingDown) return;
  shuttingDown = true;
  frontend?.kill(signal);
  storage.kill(signal);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

try {
  await waitForStorage();
  frontend = spawn(nextExecutable, [production ? "start" : "dev", ...forwardedArguments], {
    cwd: projectRoot,
    env: childEnv,
    stdio: "inherit",
  });
  frontend.on("exit", (code, signal) => {
    if (!shuttingDown) storage.kill("SIGTERM");
    process.exit(signal ? 1 : code ?? 0);
  });
} catch (error) {
  console.error("[notebook36] failed to start local services", error);
  shutdown();
  process.exitCode = 1;
}

storage.on("exit", (code) => {
  if (code && !shuttingDown) {
    console.error(`[blog-storage] exited with code ${code}`);
    frontend?.kill("SIGTERM");
  }
});
