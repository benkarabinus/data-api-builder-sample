# 01 — Solution overview

End-to-end picture of what the tutorial deploys. The same
**User-Assigned Managed Identity (UAMI)** is used by every Azure
service-to-service call — there are no keys or passwords anywhere in
the deployed system.

![Solution overview](01-solution-overview.svg)

## Reading this diagram

- **Three client paths, one server.** Whether you talk to the system
  from VS Code (MCP), the optional Streamlit app (REST), or a Foundry
  agent (MCP), every request lands at the same DAB instance.
- **DAB is the single front door.** It exposes the same data three
  ways — REST, GraphQL, and MCP — without any custom code.
- **Embeddings live next to the data.** The vector column, the
  full-text index, the search SP, and the registered embedding model
  are all inside Azure SQL. The application tier never touches the
  embeddings API directly.
- **One identity does everything.** The UAMI is attached to the ACA
  app (so DAB can log into SQL) and is mapped as a database user in
  SQL (so SQL can call Azure OpenAI). No keys, no secrets in env vars,
  no credential rotation.

## Where each layer lives in the repo

| Layer in diagram                | Built by |
|---------------------------------|----------|
| UAMI, SQL, Foundry, embedding deployment | [`infra/foundation.bicep`](../../infra/foundation.bicep) |
| `EXTERNAL MODEL` + credential   | [`sql/11`–`sql/12`](../../sql) |
| Hybrid search SP                | [`sql/20`–`sql/21`](../../sql) |
| DAB on ACA (this diagram)       | [`infra/dab-aca.bicep`](../../infra/dab-aca.bicep) + [`dab/`](../../dab) |
| VS Code MCP wire-up             | [`.vscode/mcp.json`](../../.vscode/mcp.json) |

## Source

Diagram is hand-authored SVG ([`01-solution-overview.svg`](01-solution-overview.svg)) so it renders inline in VS Code's built-in markdown preview, on GitHub, and anywhere else. The original visual source ([`01-solution-overview.drawio`](01-solution-overview.drawio)) is kept as a convenience for slide-deck exports.
