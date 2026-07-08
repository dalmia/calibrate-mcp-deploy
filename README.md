# Deploy Calibrate MCP

Deploys the published npm package [`@dalmia/calibrate-mcp`](https://www.npmjs.com/package/@dalmia/calibrate-mcp)
as a **remote, multi-tenant** MCP server on GCP Cloud Run, so shell-less / non-CLI
clients (Claude Desktop, claude.ai, hosted assistants) can use Calibrate over a URL.

This folder is **only** a Docker build context — it holds the `Dockerfile` used to
build the image. It is not the MCP source (that lives in `dalmia/calibrate-mcp`) and
it is not the backend. The published npm package is the source of truth; this just
wraps it in a container.

## What it runs

| | |
|---|---|
| Command | `serve --port $PORT --disable-static-auth` (Streamable HTTP transport) |
| Tenancy | **Multi-tenant** — no key baked in; each request carries its own key |
| Auth header | `X-API-Key: sk_...` (per request) |
| MCP endpoint | `POST /mcp` |
| Health / landing | `GET /` (returns 200) |
| Backend API URL | baked into the package from the public OpenAPI spec (production) |
| Runtime | Node only (package ships prebuilt) |

You can deploy **automatically via GitHub Actions** (recommended) or **manually** with
`gcloud`. Both produce the same Cloud Run service.

## Automated deploy (GitHub Actions)

[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) builds the image, pushes
it to Artifact Registry, and deploys to Cloud Run. It authenticates to GCP with Workload
Identity Federation (GitHub OIDC), so there is no service-account key to store.

**One-time GCP setup:**

1. **Enable APIs:** `run.googleapis.com`, `artifactregistry.googleapis.com`,
   `iamcredentials.googleapis.com`.
2. **Create the Artifact Registry repo:**
   ```bash
   gcloud artifacts repositories create calibrate-mcp \
     --repository-format=docker --location=asia-south1
   ```
3. **Create a deployer service account** with roles `roles/run.admin`,
   `roles/artifactregistry.writer`, and `roles/iam.serviceAccountUser`.
4. **Set up Workload Identity Federation** for GitHub: a WIF pool + provider for
   `https://token.actions.githubusercontent.com`, with this repo allowed to impersonate
   the service account (`assertion.repository == "<org>/<repo>"`).
5. **Set repo secrets** `GCP_WIF_PROVIDER` (the provider resource name) and
   `GCP_SERVICE_ACCOUNT` (the deployer SA email).
6. **Set the workflow `env`:** `GCP_PROJECT`, and `GCP_REGION` if not `asia-south1`.

**Run:** Actions → **Build & deploy calibrate-mcp** → Run workflow (blank version = latest
published). Uncomment the `schedule:` block to deploy new npm releases daily.

## Manual deploy (local gcloud)

```bash
REGION=asia-south1
gcloud config set project <your-project-id>

# once: create the Artifact Registry repo
gcloud artifacts repositories create calibrate-mcp \
  --repository-format=docker --location=$REGION 2>/dev/null || true

# build (from the Dockerfile) + deploy in one step; Cloud Build does the build
gcloud run deploy calibrate-mcp \
  --source . \
  --region $REGION \
  --allow-unauthenticated \
  --port 8080
```

`--allow-unauthenticated` is required: MCP clients authenticate at the app layer with
`X-API-Key`, not GCP IAM, so the service must accept unauthenticated *invocations*.
To ship a specific npm version, edit `MCP_VERSION` in the `Dockerfile` (or use the
GitHub Action, which passes it as a build-arg).

Cloud Run returns an HTTPS URL like `https://calibrate-mcp-xxxx-el.a.run.app`.

## Point clients at it

Each user configures the URL + **their own** Calibrate API key:

```json
{
  "mcpServers": {
    "calibrate": {
      "url": "https://calibrate-mcp-xxxx-el.a.run.app/mcp",
      "headers": { "X-API-Key": "sk_theirOwnKey" }
    }
  }
}
```

Claude Code:

```bash
claude mcp add --transport http calibrate \
  https://calibrate-mcp-xxxx-el.a.run.app/mcp \
  --header "X-API-Key: sk_theirOwnKey"
```

## Verify

```bash
curl https://calibrate-mcp-xxxx-el.a.run.app/          # landing page → 200
```

Then connect a real MCP client to `/mcp` with an `X-API-Key` header and confirm the
tools list (list-agents, run-agent-tests, get-agent-test-run, ...).

## Notes

- **Scales to zero** when idle — near-zero cost, but the first request after idle has a
  cold-start delay (a container + `npx` boot). Set `--min-instances 1` to keep one warm
  if that latency matters.
- **Public endpoint.** The per-request `X-API-Key` is the auth (no key ⇒ 401), but
  anyone can reach the URL. Fine for a shared multi-tenant service; add Cloud Armor /
  rate limiting before wide exposure.
- **Bumping versions:** the GitHub Action ships the latest npm version on demand; for
  manual deploys, bump `MCP_VERSION` in the `Dockerfile`.
- **Single-tenant variant** (one org, no per-user key): drop `--disable-static-auth`
  and add `--api-key-auth sk_...` to the `ENTRYPOINT`; clients then need no key.
