#!/usr/bin/env node
// Offline stand-in for provider list-models endpoints, used by
// test-api-integrations.sh when a provider's API key secret is not set.
//
// The api-management collection's "Governance - VK List Models Restriction"
// folder asserts that GET /v1/models through a virtual key returns models from
// the VK's allowed providers and none from the others. That needs at least one
// provider whose list-models call succeeds. Without credentials every provider
// fails key selection, so the gateway has nothing to list (TXE-4950).
//
// Each stubbed provider's base_url is pointed at http://127.0.0.1:<port>/<provider>,
// so the provider's real client code issues GET /<provider>/v1/models here and
// parses an OpenAI-format list. Every other request gets a 404.
//
// Usage: node list-models-stub.js <port>

const http = require("http");

const MODELS = {
  openai: [
    { id: "gpt-4o", object: "model", created: 1715367049, owned_by: "system" },
    { id: "gpt-4o-mini", object: "model", created: 1721172741, owned_by: "system" },
  ],
  mistral: [
    { id: "mistral-small-latest", object: "model", created: 1727740800, owned_by: "mistralai" },
  ],
  groq: [
    { id: "llama-3.1-8b-instant", object: "model", created: 1693721698, owned_by: "Meta" },
  ],
};

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port <= 0) {
  console.error("usage: node list-models-stub.js <port>");
  process.exit(2);
}

const server = http.createServer((req, res) => {
  const path = (req.url || "").split("?")[0];
  const match = /^\/([a-z0-9-]+)\/v1\/models\/?$/.exec(path);
  const models = match && req.method === "GET" ? MODELS[match[1]] : undefined;
  res.setHeader("Content-Type", "application/json");
  if (!models) {
    res.statusCode = 404;
    res.end(JSON.stringify({ error: { message: `list-models stub: no route for ${req.method} ${path}` } }));
    return;
  }
  res.end(JSON.stringify({ object: "list", data: models }));
});

server.listen(port, "127.0.0.1", () => {
  console.log(`list-models stub listening on 127.0.0.1:${port} (${Object.keys(MODELS).join(", ")})`);
});
