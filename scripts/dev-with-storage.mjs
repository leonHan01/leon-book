import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const storageScript = path.join(projectRoot, "scripts", "local-storage-server.mjs");
const childEnv = { ...process.env };

const storage = spawn(process.execPath, [storageScript], {
  cwd: projectRoot,
  env: childEnv,
  stdio: "inherit",
});
const frontend = spawn("vinext", ["dev", ...process.argv.slice(2)], {
  cwd: projectRoot,
  env: childEnv,
  stdio: "inherit",
});

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  storage.kill(signal);
  frontend.kill(signal);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

frontend.on("exit", (code, signal) => {
  if (!shuttingDown) storage.kill("SIGTERM");
  process.exit(signal ? 1 : code ?? 0);
});

storage.on("exit", (code) => {
  if (code && !shuttingDown) console.error(`[blog-storage] exited with code ${code}`);
});

