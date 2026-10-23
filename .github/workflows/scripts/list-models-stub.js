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
// parses an OpenAI-format list.
//
// The governance suites run in the same job also send chat completions through
// openai (the time-of-day pricing collection prices the logged token counts), so
// POST /<provider>/v1/chat/completions answers a fixed, non-streaming OpenAI-format
// completion with a usage block (TXE-5026). A streaming request, and every other
// request, gets a 404.
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

// Fixed token counts, so a priced log row has non-zero prompt and completion tokens.
const USAGE = { prompt_tokens: 9, completion_tokens: 3, total_tokens: 12 };

function notFound(res, req, path) {
  res.statusCode = 404;
  res.end(JSON.stringify({ error: { message: `list-models stub: no route for ${req.method} ${path}` } }));
}

function chatCompletion(req, res, path) {
  let raw = "";
  req.setEncoding("utf8");
  req.on("data", (chunk) => {
    raw += chunk;
  });
  req.on("end", () => {
    let body;
    try {
      body = JSON.parse(raw);
    } catch (e) {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: { message: "list-models stub: request body is not JSON" } }));
      return;
    }
    if (body.stream) {
      notFound(res, req, `${path} (stream)`);
      return;
    }
    res.end(
      JSON.stringify({
        id: `chatcmpl-stub-${Date.now()}`,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: typeof body.model === "string" ? body.model : "stub",
        choices: [{ index: 0, message: { role: "assistant", content: "ok" }, finish_reason: "stop" }],
        usage: USAGE,
      }),
    );
  });
}

const server = http.createServer((req, res) => {
  const path = (req.url || "").split("?")[0];
  res.setHeader("Content-Type", "application/json");
  const chat = /^\/([a-z0-9-]+)\/v1\/chat\/completions\/?$/.exec(path);
  if (chat && req.method === "POST" && MODELS[chat[1]]) {
    chatCompletion(req, res, path);
    return;
  }
  const match = /^\/([a-z0-9-]+)\/v1\/models\/?$/.exec(path);
  const models = match && req.method === "GET" ? MODELS[match[1]] : undefined;
  if (!models) {
    notFound(res, req, path);
    return;
  }
  res.end(JSON.stringify({ object: "list", data: models }));
});

server.listen(port, "127.0.0.1", () => {
  console.log(`list-models stub listening on 127.0.0.1:${port} (${Object.keys(MODELS).join(", ")})`);
});
