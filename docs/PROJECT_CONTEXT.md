# Project context

Living reference for this repo. Keep resource names, endpoints, and status
current. **Never put real secrets or live URLs here** — placeholders only
(see [SECURITY.md](../SECURITY.md)). The real values live in the gitignored
`outputs.json`.

## What this is

A one-command Azure deployment of an "intelligent search over your own data"
stack: Azure SQL (data + vector embeddings) → hybrid search stored procedure
→ Data API Builder on Container Apps (REST + GraphQL + MCP) → Streamlit web UI
**and a Foundry prompt agent**. One User-Assigned Managed Identity
authenticates every hop; no keys or passwords. `deploy.ps1` creates the agent
end-to-end (no portal steps), and the Streamlit app has a **Chat with Agent**
tab that talks to it through the Microsoft Agent Framework SDK.

## Entry points

| Action | Command / file |
|---|---|
| Deploy everything | `.\deploy.ps1 -ResourceGroupName <rg> -NamePrefix <prefix>` |
| Tear down | `.\teardown.ps1 -ResourceGroupName <rg> -AutoApprove` |
| Bring your own data | [byo/README.md](../byo/README.md) |
| Connect a Foundry agent | [agent/README.md](../agent/README.md) |
| Deep design | [docs/ARCHITECTURE.md](ARCHITECTURE.md) |

## Structure

```
deploy.ps1   teardown.ps1   outputs.json (gitignored)
infra/   foundation.bicep · dab-aca.bicep · webapp-aca.bicep
sql/     00–02 schema+seed · 10–15 embeddings · 20–22 hybrid search
dab/     dab-config.json · Dockerfile
app/     app.py · Dockerfile · requirements.txt   (Streamlit UI + chat tab)
agent/   agent.py · requirements.txt · README.md  (Foundry prompt agent)
byo/     README.md   (bring your own data)
docs/    ARCHITECTURE.md · CHANGELOG.md · architecture/ (diagrams)
```

## Resource naming

Derived from `-NamePrefix` + `-EnvironmentName` + a 6-char hash of
(subscription, resource group):

| Resource | Pattern |
|---|---|
| UAMI | `<prefix>-uami-<env>` |
| SQL server | `<prefix>-sql-<env>-<uniq>` |
| SQL database | `ProductsDB` |
| Foundry account | `<prefix>-ai-<env>-<uniq>` |
| Foundry project | `<prefix>-proj-<env>` |
| Embedding deployment | `embedding` (`text-embedding-3-small`) |
| Chat deployment | `chat` (`gpt-4.1`) |
| Foundry agent | `chat-with-your-data` (prompt agent) |
| Container Registry | `<prefix>acr<env><uniq>` |
| ACA environment | `<prefix>-acaenv-<env>` |
| DAB app | `<prefix>-dab-<env>` |
| Web app | `<prefix>-web-<env>` |

## Status

- Foundation, SQL data plane, hosted DAB, the Streamlit web UI, **and the
  Foundry prompt agent** are all scripted and idempotent via `deploy.ps1`.
  Validated end-to-end on a fresh subscription.
- The agent (`chat-with-your-data`) is a Foundry **prompt agent** created with
  the `azure-ai-projects` SDK (`agents.create_version` + `PromptAgentDefinition`
  + `MCPTool`), so it appears in the new Foundry Agents experience. Its model
  is the `chat` deployment (`gpt-4.1`); its only tool is the hosted DAB `/mcp`
  endpoint.
- **Agent RBAC is declarative.** `foundation.bicep` (Stage 1) grants
  **Foundry User** (role GUID `53ca6127-…`, rename-proof) on the Foundry
  account to *both* the deploying user (agent authoring) and the UAMI (invoke).
  Granting at foundation time lets the roles propagate during the SQL +
  image-build window, so Stage 5 never races RBAC. `Foundry User`'s
  `Microsoft.CognitiveServices/*` data action covers both author and invoke;
  subscription Owner alone does not.
- **Cold-account settling**, not RBAC, was the real cause of earlier Stage 5
  failures: a freshly-created Foundry account's agent *write* endpoint takes a
  few minutes to become operational (reads work first). Stage 5 retries the
  agent upsert (~10 min) to absorb this.
- The Streamlit **Chat with Agent** tab connects with the Microsoft Agent
  Framework SDK (`agent_framework.foundry.FoundryAgent`) and authenticates as
  the UAMI (`AZURE_CLIENT_ID` is set on the web container). The tab can lag a
  refresh or two after deploy while the new web revision starts serving.
- **Agent instructions vs. tools.** A prompt agent's `MCPTool` is structural
  only (no per-tool instruction field); tool/column *meaning* lives on the DAB
  MCP server (`dab-config.json` `fields`/`parameters`), while *when/how to call*
  and output formatting live in the agent `instructions`. The same instruction
  text is kept in sync between `agent/agent.py` and `deploy.ps1` Stage 5.
- Default DAB ingress is **anonymous**. Entra protection for the MCP
  endpoint is a documented hardening step, not yet automated.
