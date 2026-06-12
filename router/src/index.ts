import "dotenv/config";
import { createRelayRouterServer, defaultOptionsFromEnv } from "./server.js";

const options = defaultOptionsFromEnv();
const server = createRelayRouterServer(options);

server.listen(options.port, options.host, () => {
  console.log(
    `Relay router listening on http://${options.host}:${options.port}/api/v1/messages`
  );
});

function shutdown(): void {
  server.close(() => {
    process.exit(0);
  });
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
