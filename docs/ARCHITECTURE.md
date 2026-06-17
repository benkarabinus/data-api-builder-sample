# Architecture

How the "chat with your data" stack is built and why. For the one-command
deploy and quick start, see the [root README](../README.md).

![Solution overview](architecture/01-solution-overview.svg)

---

## The identity model: one UAMI, no secrets

Every service-to-service call uses the same **User-Assigned Managed Identity
(UAMI)**. Nothing in this repo stores an API key, a SQL password, or a
connection secret in code.

```mermaid
flowchart TD
    UAMI["User-Assigned Managed Identity"]
    SQL["Azure SQL<br/>(Entra-only auth)"]
    FOUNDRY["Azure AI Foundry account<br/>(embedding + chat + agent)"]
    ACR["Azure Container Registry"]
    DAB["DAB container (ACA)"]
    WEB["Streamlit container (ACA)"]

    UAMI -->|"primary identity + DB user<br/>(db_datareader/writer, EXEC dbo)"| SQL
    UAMI -->|"Cognitive Services OpenAI User<br/>+ Foundry User (agent invoke)"| FOUNDRY
    UAMI -->|"AcrPull"| ACR
    UAMI -.attached to.-> DAB
    UAMI -.attached to.-> WEB
    DAB -->|"Active Directory Managed Identity"| SQL
    SQL -->|"EXTERNAL MODEL → embeddings,<br/>credential = Managed Identity"| FOUNDRY
    WEB -->|"FoundryAgent (Agent Framework SDK)<br/>AZURE_CLIENT_ID = UAMI"| FOUNDRY
```

- The **SQL server** has the UAMI as its primary identity, so SQL can mint
  tokens for that identity when it calls Foundry.
- A **database-scoped credential** named after the OpenAI endpoint, with
  `IDENTITY = 'Managed Identity'`, lets `EXTERNAL MODEL` calls authenticate
  as the UAMI — the UAMI holds **Cognitive Services OpenAI User** on the
  Foundry account.
- The **DAB container** has the UAMI attached and connects to SQL with
  `Authentication=Active Directory Managed Identity;User Id=<clientId>`.
  Step 2's `CREATE USER ... FROM EXTERNAL PROVIDER` mapped that identity to a
  database user with the rights DAB needs.
- The **Streamlit container** also has the UAMI attached. Its **Chat with
  Agent** tab invokes the Foundry prompt agent as that identity — `DefaultAzureCredential`
  is pointed at the UAMI via `AZURE_CLIENT_ID`, and the UAMI holds
  **Foundry User** on the Foundry account (the role that authorizes the
  Responses API / agent invocation).
- The same UAMI holds **AcrPull**, so Container Apps pulls the images without
  registry admin credentials.

The result: rotating or revoking one identity governs the entire stack.

---

## The data and embedding pipeline

![Data and embedding flow](architecture/02-data-and-embedding-flow.svg)

1. **Schema** ([`sql/00-create-schema.sql`](../sql/00-create-schema.sql)).
   `dbo.Products` and `dbo.ProductReviews`. The reviews table has a
   `ReviewEmbedding VECTOR(1536)` column, created up front but left `NULL`.
2. **External model** ([`sql/12-create-external-model.sql`](../sql/12-create-external-model.sql)).
   Registers `EXTERNAL MODEL EmbeddingModel` pointing at the Foundry
   `text-embedding-3-small` deployment, authenticating via the
   database-scoped credential (the UAMI).
3. **Backfill** ([`sql/14-backfill-embeddings.sql`](../sql/14-backfill-embeddings.sql)).
   Calls `AI_GENERATE_EMBEDDINGS(text USE MODEL EmbeddingModel)` for every
   row with a `NULL` embedding and stores the vector.
4. **Optional trigger** ([`sql/15-create-auto-embed-trigger.sql`](../sql/15-create-auto-embed-trigger.sql)).
   Re-embeds rows automatically on `INSERT`/`UPDATE` so embeddings never go
   stale. Off by default; enable with `-InstallAutoEmbedTrigger`.

`AI_GENERATE_EMBEDDINGS` + `EXTERNAL MODEL` is the modern, in-engine path.
(An older approach wrapped `sp_invoke_external_rest_endpoint` by hand; this
repo uses the newer `EXTERNAL MODEL` form throughout.)

---

## Hybrid search: vector + full-text, fused with RRF

![Hybrid search flow](architecture/03-hybrid-search-flow.svg)

Vector search finds *semantic* matches ("comfy seat" ≈ "comfortable chair");
full-text search nails *exact keywords* (model numbers, rare terms). Each
misses what the other catches, so
[`sql/21-create-hybrid-search-sp.sql`](../sql/21-create-hybrid-search-sp.sql)
runs both and combines them with **Reciprocal Rank Fusion**:

$$\text{RRF}(d) = \sum_{r \in \text{rankers}} \frac{1}{k + \text{rank}_r(d)}, \quad k = 60$$

`dbo.find_similar_reviews_hybrid(@queryText, @top)`:

1. Embeds `@queryText` with `EmbeddingModel`.
2. Takes the **top 50 by cosine distance** (`VECTOR_DISTANCE('cosine', …)`).
3. Takes the **top 50 by keyword rank** (`FREETEXTTABLE`, backed by the
   full-text index from [`sql/20-create-fulltext-index.sql`](../sql/20-create-fulltext-index.sql)).
4. `FULL OUTER JOIN`s the two lists and scores each row by the RRF formula.
5. Returns the top `@top` rows ordered by fused score.

RRF needs no score normalization between the two very different scales
(cosine distance vs. full-text rank) — it only uses each list's *rank
position*, which is why it's robust.

---

## Serving: Data API Builder on Container Apps

[Data API Builder](https://learn.microsoft.com/azure/data-api-builder/)
turns SQL objects into REST, GraphQL, and **MCP** endpoints from a single
config file ([`dab/dab-config.json`](../dab/dab-config.json)):

| Entity | Source | Exposed as |
|---|---|---|
| `Product` | `dbo.Products` (table) | REST/GraphQL read |
| `ProductReview` | `dbo.ProductReviews` (table) | REST/GraphQL read |
| `FindSimilarReviewsHybrid` | `dbo.find_similar_reviews_hybrid` (stored proc) | REST `POST` / GraphQL mutation / MCP tool |

- The connection string is `@env('SQL_CONNECTION_STRING')`, injected by the
  Container App from a secret — so the **same image** runs against any SQL
  server without rebuilding.
- The image is built in the cloud with `az acr build` (no local Docker) and
  layered on `mcr.microsoft.com/azure-databases/data-api-builder`.
- `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true` makes Kestrel honor ACA's
  `X-Forwarded-Proto: https`, so DAB builds `https://` redirect URLs (needed
  for stored-procedure `201` responses).

The MCP runtime block (`"mcp": { "enabled": true }`) is what makes the
stored procedure callable as a tool by Copilot Chat and Foundry agents.

---

## Deployment topology

```mermaid
flowchart LR
    subgraph RG["Resource group"]
      UAMI["UAMI"]
      SQLSRV["SQL server + ProductsDB"]
      FND["Foundry account + project<br/>embedding + chat deployments<br/>chat-with-your-data agent"]
      ACR["Container Registry"]
      ENV["Container Apps env + Log Analytics"]
      DABAPP["DAB container app"]
      WEBAPP["Streamlit container app"]
    end

    UAMI --- SQLSRV
    UAMI --- FND
    UAMI --- ACR
    ACR --> DABAPP
    ACR --> WEBAPP
    ENV --> DABAPP
    ENV --> WEBAPP
    DABAPP --> SQLSRV
    WEBAPP -->|REST| DABAPP
    WEBAPP -->|agent invoke| FND
    FND -->|agent's MCP tool| DABAPP
```

[`deploy.ps1`](../deploy.ps1) provisions this in five stages, each
idempotent:

| Stage | Template / scripts | Produces |
|---|---|---|
| 1. Foundation | [`infra/foundation.bicep`](../infra/foundation.bicep) | UAMI, SQL, Foundry, **embedding + chat deployments**, role assignments (UAMI → Cognitive Services OpenAI User; **deployer + UAMI → Foundry User** for agent author/invoke) |
| 2. SQL data plane | [`sql/*.sql`](../sql) via `sqlcmd -G` | schema, embeddings, hybrid search SP |
| 3. Hosted DAB | `az acr build` + [`infra/dab-aca.bicep`](../infra/dab-aca.bicep) | ACR, image, ACA env, DAB app |
| 4. Web UI | `az acr build` + [`infra/webapp-aca.bicep`](../infra/webapp-aca.bicep) | Streamlit app (with the Chat tab) in the same ACA env |
| 5. Foundry agent | `azure-ai-projects` SDK (`agents.create_version`) | `chat-with-your-data` prompt agent + DAB MCP tool; wires the agent into the web app |

ACR is created by the script (not Bicep) so images exist before the apps
reference them. Both container apps share one ACA environment and one
registry. Stage 4 reuses the AcrPull grant from stage 3, so it adds no role
assignment. Stage 5 needs no role assignment either: the **Foundry User**
grants it relies on are created in Stage 1, so they have the whole SQL +
image-build window (~10 min) to propagate — and the agent's authoring endpoint,
on a freshly-created account, has the same window to become operational. Stage 5
runs after the web app exists so it can patch the agent's project endpoint,
name, and version into the running container, and retries the agent upsert to
absorb any remaining cold-account settling.

---

## The Foundry agent and the chat tab

![Solution overview](architecture/01-solution-overview.svg)

The accelerator ships a **Foundry prompt agent** named `chat-with-your-data`,
created end-to-end by `deploy.ps1` (no portal clicks):

1. **Chat model.** Stage 1 deploys `gpt-4.1` as the **`chat`** deployment
   alongside the embedding model. The agent references the *deployment* name
   (`chat`), not the model name — the Responses API resolves by deployment.
2. **Agent definition.** Stage 5 calls
   `project.agents.create_version(agent_name="chat-with-your-data", definition=PromptAgentDefinition(model="chat", instructions=…, tools=[MCPTool(server_url=<dabAppUrl>/mcp)]))`
   from the `azure-ai-projects` SDK. `create_version` is an upsert, so re-runs
   roll a new version rather than duplicating the agent. The agent shows up in
   the **new** Foundry Agents experience.
3. **The agent's only tool** is the hosted DAB `/mcp` endpoint
   (`require_approval: never`), so it can call `describe_entities`,
   `read_records`, `aggregate_records`, and the named
   `find_similar_reviews_hybrid` tool. Its instructions enforce the DAB tool
   contract (detailed `describe_entities` first, case-sensitive fields, no
   `select: "*"`) — see [agent/README.md](../agent/README.md).

   > **Where guidance lives.** A prompt agent's `MCPTool` is structural only
   > (`server_label`, `server_url`, `require_approval`, `allowed_tools`) — there
   > is no per-tool instruction field. So tool/column *meaning* lives on the DAB
   > MCP server (the `fields`/`parameters` descriptions in `dab-config.json`),
   > while *when and how to call* tools and how to format output live in the
   > agent `instructions`. The instruction text is kept identical in
   > [`agent/agent.py`](../agent/agent.py) and [`deploy.ps1`](../deploy.ps1)
   > Stage 5 so a redeploy doesn't drift from local iteration.
4. **The Streamlit Chat tab** ([`app/app.py`](../app/app.py)) connects with the
   **Microsoft Agent Framework SDK** (`agent_framework.foundry.FoundryAgent`).
   It runs as the web container's UAMI (via `AZURE_CLIENT_ID`), which holds
   **Foundry User** on the Foundry account. Conversation history lives in
   Streamlit session state — there is no separate chat database.

```mermaid
sequenceDiagram
    participant U as User
    participant W as Streamlit (UAMI)
    participant A as Foundry agent (chat)
    participant D as DAB /mcp
    participant S as Azure SQL
    U->>W: "good for long hours?"
    W->>A: FoundryAgent.run() (Responses API)
    A->>D: find_similar_reviews_hybrid(queryText, top)
    D->>S: EXEC dbo.find_similar_reviews_hybrid
    S-->>D: top RRF-ranked reviews
    D-->>A: rows
    A-->>W: grounded answer (cites reviews)
    W-->>U: rendered in chat
```

You can iterate on the agent locally with
[`agent/agent.py`](../agent/agent.py): `--ensure` upserts the definition and
`--invoke "…"` chats with it through the same Agent Framework SDK.

---

## Bring your own data

The sample products/reviews are a demo. The same machinery —
`EmbeddingModel`, the full-text catalog, the UAMI's DB rights — works for any
table with a text column. [`byo/README.md`](../byo/README.md) walks through
adding a `VECTOR(1536)` column, backfilling, building a table-specific hybrid
SP, and exposing it through DAB without redeploying infrastructure.

![BYO table flow](architecture/05-byo-table-flow.svg)
