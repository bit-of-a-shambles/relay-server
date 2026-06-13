import "dotenv/config";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createRelayRouterServer, defaultOptionsFromEnv } from "../dist/server.js";

if (!process.env.OPENROUTER_API_KEY) {
  console.log("Skipping OpenRouter smoke: OPENROUTER_API_KEY is not set.");
  process.exit(0);
}

// Use a free model for smoke so no paid credits are required.
const __dirname = dirname(fileURLToPath(import.meta.url));
process.env.RELAY_ROUTING_CONFIG ??= join(__dirname, "smoke-routing.json");

const options = defaultOptionsFromEnv();
const server = createRelayRouterServer(options);
await new Promise((resolve) => server.listen(options.port, options.host, resolve));

const cwd = await mkdtemp(join(tmpdir(), "relay-openrouter-smoke-"));
await writeFile(join(cwd, "README.md"), "# Relay smoke\n\nOpenRouter live smoke.\n", "utf8");

try {
  const child = spawn(
    "claude",
    [
      "--bare",
      "--print",
      "Read README.md using the Read tool, then reply with exactly: RELAY_SMOKE_OK",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      "default",
      "--include-partial-messages",
      "--no-session-persistence",
      "--allowedTools",
      "Read",
      "--model",
      "claude-3-5-haiku-20241022"
    ],
    {
      cwd,
      env: {
        ...process.env,
        ANTHROPIC_BASE_URL: `http://${options.host}:${options.port}/api`,
        ANTHROPIC_API_KEY: "dummy"
      },
      stdio: ["ignore", "pipe", "pipe"]
    }
  );

  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });

  const exitCode = await new Promise((resolve) => {
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      resolve("timeout");
    }, 120_000);
    child.on("exit", (code) => {
      clearTimeout(timeout);
      resolve(code);
    });
  });

  if (exitCode !== 0 || !stdout.includes("RELAY_SMOKE_OK")) {
    console.error(JSON.stringify({ exitCode, stdoutTail: stdout.slice(-2000), stderr }, null, 2));
    process.exit(1);
  }

  console.log("OpenRouter smoke passed.");
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(cwd, { recursive: true, force: true });
}
