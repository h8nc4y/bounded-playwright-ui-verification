"use strict";

const http = require("node:http");

// test runnerが渡したloopback portと絶対寿命だけを受理する。
const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index], process.argv[index + 1]);
}

const port = Number.parseInt(args.get("--port"), 10);
const maxLifetimeMilliseconds = Number.parseInt(
  args.get("--max-lifetime-ms") ?? "15000",
  10,
);
if (
  !Number.isInteger(port) ||
  port < 1 ||
  port > 65535 ||
  !Number.isInteger(maxLifetimeMilliseconds) ||
  maxLifetimeMilliseconds < 1000 ||
  maxLifetimeMilliseconds > 60000
) {
  process.exitCode = 2;
  throw new Error("Invalid synthetic server arguments.");
}

// request内容を保存せず、固定health responseだけを返す。
const server = http.createServer((_request, response) => {
  response.writeHead(200, {
    "content-type": "text/plain; charset=utf-8",
    "content-length": "2",
    connection: "close",
  });
  response.end("ok");
});

const lifetimeTimer = setTimeout(() => {
  server.close(() => process.exit(0));
}, maxLifetimeMilliseconds);
lifetimeTimer.unref();

server.listen(port, "127.0.0.1", () => {
  process.stdout.write("synthetic-http-server-ready\n");
});
