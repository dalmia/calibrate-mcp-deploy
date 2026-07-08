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

### One-time GCP setup

Run once, as a project owner/admin. Set the variables first:

```bash
PROJECT_ID=<your-project-id>
REGION=asia-south1
GH_REPO=dalmia/calibrate-mcp-deploy          # owner/repo of THIS repo
SA=calibrate-mcp-deployer
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SA_EMAIL="$SA@$PROJECT_ID.iam.gserviceaccount.com"
```

```bash
# 1. Enable APIs
gcloud services enable \
  run.googleapis.com artifactregistry.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com --project "$PROJECT_ID"

# 2. Create the Artifact Registry image repo the workflow pushes images to
#    ("repository" here = a Docker image store in GCP, not a git repo)
gcloud artifacts repositories create calibrate-mcp \
  --repository-format=docker --location="$REGION" --project "$PROJECT_ID" || true

# 3. Deployer service account + roles
gcloud iam service-accounts create "$SA" \
  --display-name="calibrate-mcp GitHub deployer" --project "$PROJECT_ID"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/run.admin"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/artifactregistry.writer"
gcloud iam service-accounts add-iam-policy-binding \
  "$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/iam.serviceAccountUser" \
  --project "$PROJECT_ID"

# 4. Workload Identity Federation (OIDC trust), restricted to this repo
gcloud iam workload-identity-pools create github \
  --location=global --display-name="GitHub Actions" --project "$PROJECT_ID"
gcloud iam workload-identity-pools providers create-oidc github \
  --location=global --workload-identity-pool=github --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='$GH_REPO'" --project "$PROJECT_ID"

# 5. Let only this repo impersonate the SA
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/$GH_REPO" \
  --project "$PROJECT_ID"

# 6. Store the values GitHub Actions needs (secrets = credentials, vars = config)
gh secret set GCP_WIF_PROVIDER --repo "$GH_REPO" \
  --body "projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github"
gh secret set GCP_SERVICE_ACCOUNT --repo "$GH_REPO" --body "$SA_EMAIL"
gh variable set GCP_PROJECT --repo "$GH_REPO" --body "$PROJECT_ID"
# only if not asia-south1:
# gh variable set GCP_REGION --repo "$GH_REPO" --body "$REGION"
```

### Run it

GitHub → **Actions** → **Build & deploy calibrate-mcp** → **Run workflow**.

The workflow has one optional input, **version** (the npm version of
`@dalmia/calibrate-mcp` to deploy):

- Leave it empty to deploy the **latest published** version.
- Or type a specific version, e.g. `0.0.14`.

To deploy new npm releases automatically once a day, uncomment the `schedule:` block
at the top of `deploy.yml`.

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

## Custom domain (HTTPS load balancer)

`asia-south1` does not support Cloud Run domain mappings, so front the service with a
global external HTTPS load balancer. Run once (each command is one line; replace the
domain if yours differs). "already exists" on any line = that piece is done, skip it.

```bash
gcloud compute addresses create calibrate-mcp-ip --global
gcloud compute network-endpoint-groups create calibrate-mcp-neg --region=asia-south1 --network-endpoint-type=serverless --cloud-run-service=calibrate-mcp
gcloud compute backend-services create calibrate-mcp-backend --global --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services add-backend calibrate-mcp-backend --global --network-endpoint-group=calibrate-mcp-neg --network-endpoint-group-region=asia-south1
gcloud compute url-maps create calibrate-mcp-urlmap --default-service=calibrate-mcp-backend
gcloud compute ssl-certificates create calibrate-mcp-cert --domains=mcp.calibrate.artpark.ai
gcloud compute target-https-proxies create calibrate-mcp-https-proxy --url-map=calibrate-mcp-urlmap --ssl-certificates=calibrate-mcp-cert
gcloud compute forwarding-rules create calibrate-mcp-fr --global --load-balancing-scheme=EXTERNAL_MANAGED --network-tier=PREMIUM --address=calibrate-mcp-ip --target-https-proxy=calibrate-mcp-https-proxy --ports=443
```

Get the load balancer IP, then check the cert:

```bash
gcloud compute addresses describe calibrate-mcp-ip --global --format='value(address)'
gcloud compute ssl-certificates describe calibrate-mcp-cert --global --format='value(managed.status)'
```

Add a DNS record `A  mcp.calibrate  → <that IP>` (under `artpark.ai`). The managed cert
only validates after DNS points at the IP: `PROVISIONING` → wait 15–60 min, `ACTIVE` →
`https://mcp.calibrate.artpark.ai/mcp` is live. The load balancer has a small always-on
cost (~$18/mo).

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
