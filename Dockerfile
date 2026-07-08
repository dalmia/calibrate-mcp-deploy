FROM node:22-slim

# The published @dalmia/calibrate-mcp package ships prebuilt JS, so the runtime
# needs only Node — no bun/tsc. Install at build time (not via `npx` at start)
# so cold starts are fast and the image is reproducible. Bump MCP_VERSION on
# each deliberate rollout:  docker build --build-arg MCP_VERSION=0.0.15 .
ARG MCP_VERSION=0.0.14

WORKDIR /app
RUN npm install "@dalmia/calibrate-mcp@${MCP_VERSION}"

# `serve` = Streamable HTTP transport (remote). Multi-tenant: no key is baked in
# (--disable-static-auth), so every request must carry its own `X-API-Key: sk_...`.
# Cloud Run injects $PORT (default 8080); honor it. `exec` so SIGTERM reaches node.
# MCP endpoint: POST /mcp   |   landing/health: GET /
ENTRYPOINT ["sh", "-c", "exec npx @dalmia/calibrate-mcp serve --port \"${PORT:-8080}\" --disable-static-auth"]
