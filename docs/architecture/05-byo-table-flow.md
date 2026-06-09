# 05 — Bring Your Own table flow

How to plug a table you already own into the same hybrid-search +
DAB + MCP pipeline without changing any agent or client code.

![BYO table flow](05-byo-table-flow.svg)

## What you change vs what you reuse

| Layer | Reuse from the tutorial | Add per BYO table |
|---|---|---|
| UAMI, DSC, EXTERNAL MODEL | ✅ unchanged | — |
| Auth, role assignments | ✅ unchanged | — |
| Embedding pipeline | ✅ same `AI_GENERATE_EMBEDDINGS` call | — |
| Schema | — | `VECTOR(1536)` column on your table |
| Index | — | Full-text index on the text column |
| Search SP | — | `dbo.find_similar_<thing>_hybrid(@queryText, @top)` (copy + rename from step 3 upgrade) |
| DAB config | ✅ same `dab-config.json` | Add a table entity + an SP entity |
| Clients (MCP / REST / web) | ✅ unchanged | New entity name appears in `describe_entities` automatically |

## Step-by-step

1. **Add the vector column + populate it** —
   [step 2 BYO appendix](../../steps/02-embeddings-in-sql/byo/README.md).
   This `ALTER TABLE` adds `ContentEmbedding VECTOR(1536)` and runs the
   same backfill cursor over your rows. Optionally install the auto-
   embed trigger so future inserts are embedded automatically.
2. **Add the full-text index + the search SP** —
   [step 3 BYO appendix](../../steps/03-hybrid-search-sp/byo/README.md).
   Recipe is "copy `02-create-hybrid-search-sp-v2.sql`, rename, re-point
   at your table".
3. **Expose it through DAB** —
   [bring-your-own-data guide](../../byo/README.md).
   One JSON edit in [`dab/dab-config.json`](../../dab/dab-config.json).
4. **Re-publish DAB to ACA** — re-run
   `deploy.ps1 -SkipSqlScripts -DeployWebApp:$false`; ACA does a
   zero-downtime swap to the new image revision.

After that, every client (VS Code Copilot Chat, the optional web app,
the optional Foundry agent) sees the new entity through `describe_entities`
and can call it through `read_records` / `execute_entity` with no code
changes.

## Why this works

- **All the auth complexity is one-time.** The UAMI, the DSC, the
  EXTERNAL MODEL, the SQL grants are set up in steps 1–3 and never
  need to change as you add tables.
- **DAB is config-driven.** Adding a table or SP is a config edit, not
  a code change. DAB reflects the SP signature at runtime, so even
  signature evolution doesn't require a container rebuild — only a
  config redeploy.
- **MCP tools are introspectable.** Clients call `describe_entities`
  to discover what's there. New BYO entities show up automatically.

## Source

Diagram is hand-authored SVG ([`05-byo-table-flow.svg`](05-byo-table-flow.svg)). Original visual source kept at [`05-byo-table-flow.drawio`](05-byo-table-flow.drawio).
