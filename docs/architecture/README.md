# Architecture diagrams

Each diagram lives in **three files**:

- a **`.md`** file with prose + the diagram embedded as `![](file.svg)` — the page you read.
- a **`.svg`** file — hand-authored SVG, the **rendered source of truth**. Renders inline in VS Code's built-in markdown preview, on GitHub, in any markdown viewer.
- a **`.drawio`** file — the original visual source, kept as a convenience for slide-deck exports. Open with the VS Code drawio extension (`hediet.vscode-drawio`) if you need a visual edit.

## Diagrams

| # | Topic | Read |
|---|---|---|
| 01 | Solution overview — clients, DAB, SQL, OpenAI, the UAMI | [01-solution-overview.md](01-solution-overview.md) |
| 02 | Data + embedding flow — insert path (trigger) and query path (SP) | [02-data-and-embedding-flow.md](02-data-and-embedding-flow.md) |
| 03 | Hybrid search flow — vector + full-text, fused with RRF | [03-hybrid-search-flow.md](03-hybrid-search-flow.md) |
| 04 | Auth: v1 (per-call endpoint params) vs v2 (registered `EXTERNAL MODEL`) | [04-auth-v1-v2.md](04-auth-v1-v2.md) |
| 05 | Bring-your-own-table flow | [05-byo-table-flow.md](05-byo-table-flow.md) |

## Conventions

Color palette (kept consistent across both SVG and drawio sources):

| Class | Color | Used for |
|---|---|---|
| Compute | `#0078D4` (Azure blue) | DAB, ACA, clients |
| Data | `#CC2927` (SQL red) | Azure SQL, tables, SPs |
| AI | `#10A37F` (teal) | Azure OpenAI, EXTERNAL MODEL, AI_GENERATE_EMBEDDINGS |
| Identity | `#FFB900` (amber) | UAMI, DSC, role assignments |
| Neutral | `#605E5C` | Edges, captions |

Font: Segoe UI (system), with Consolas for monospace labels.
