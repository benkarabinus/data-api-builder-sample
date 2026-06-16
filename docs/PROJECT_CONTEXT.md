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
- The agent (`chat-with-your-data`) is a Foundry **prompt agent** created with
  the `azure-ai-projects` SDK (`agents.create_version` + `PromptAgentDefinition`
  + `MCPTool`), so it appears in the new Foundry Agents experience. Its model
  is the `chat` deployment (`gpt-4.1`); its only tool is the hosted DAB `/mcp`
  endpoint.
- The Streamlit **Chat with Agent** tab connects with the Microsoft Agent
  Framework SDK (`agent_framework.foundry.FoundryAgent`) and authenticates as
  the UAMI (`AZURE_CLIENT_ID` is set on the web container; the UAMI holds
  **Foundry User** on the Foundry account).
- Default DAB ingress is **anonymous**. Entra protection for the MCP
  endpoint is a documented hardening step, not yet automated.
