# Changelog

## 2026-06-15 — Verify agent end-to-end, fix RBAC + UAMI auth, refresh docs

Hardening + verification pass on the new agent stack, plus a full documentation
refresh to match the new direction.

- **End-to-end verified.** The agent was confirmed live via three paths: the
  Foundry playground, the Responses API, and the local Agent Framework SDK
  (`agent.py --invoke`) — all returning grounded answers from the DAB tools.
- **Correct invoke role.** The UAMI now gets **Foundry User** on the Foundry
  account (the documented role for Responses-API/agent invocation), not
  `Azure AI User` (which no longer resolves in tenants that have completed the
  rename) nor the broader `Azure AI Developer`. `deploy.ps1` tries `Foundry User`
  first and falls back to the old `Azure AI User` name for not-yet-renamed
  tenants.
- **UAMI auth fix.** The web container sets `AZURE_CLIENT_ID` to the UAMI client
  ID so `DefaultAzureCredential` selects the user-assigned identity (without it,
  the chat tab failed with *Unable to load the proper Managed Identity*).
  Added a `uamiClientId` param to `webapp-aca.bicep` and passed it from
  `deploy.ps1`.
- **Missing runtime dep.** `aiohttp` is now pinned in `app/requirements.txt` and
  `agent/requirements.txt` — `agent-framework-foundry` needs it at runtime but
  doesn't pull it transitively.
- **app.py refactor.** Restructured the Streamlit app into clear sections
  (config → DAB client → agent client → UI tabs → `main()`), one function per
  tab, top-level imports, no module-scope side effects.
- **Docs refreshed for the new direction.** Updated `README.md`,
  `docs/PROJECT_CONTEXT.md`, `docs/ARCHITECTURE.md` (identity + topology mermaid,
  five-stage table, new agent/chat-tab section + sequence diagram), rewrote
  `agent/README.md` from a portal walkthrough to the SDK-orchestrated flow, and
  updated the `01-solution-overview` diagram (SVG + prose) to show the deployed
  agent and the web app's chat path.

## 2026-06-15 — Move to new Foundry agents runtime + Agent Framework SDK

Corrected the agent integration to the modern stack after the first pass used
the deprecated `azure.ai.projects` classic-agent API (which landed in the old
Agents UI and used non-existent SDK calls).

- **Prompt agent on the new runtime.** The agent `chat-with-your-data` is now
  defined with `azure-ai-projects` `agents.create_version(...)` +
  `PromptAgentDefinition` + `MCPTool`, so it appears in the new Foundry Agents
  experience. Its `model` references the **deployment name** (`chat`), not the
  model name (`gpt-4.1`) — the earlier mismatch caused `DeploymentNotFound`.
- **MCP URL fixed.** The tool now targets the current DAB `/mcp` endpoint from
  `outputs.json` (`dabAppUrl`), replacing a stale Container Apps host.
- **Streamlit chat tab (real, not stubbed).** `app/app.py` adds a "Chat with
  Agent" tab that connects with the **Microsoft Agent Framework SDK**
  (`agent_framework.foundry.FoundryAgent`) via `DefaultAzureCredential` (the web
  container's UAMI), with `st.session_state` history. The tab shows only when
  `FOUNDRY_PROJECT_ENDPOINT` and `FOUNDRY_AGENT_NAME` are set.
- **deploy.ps1 Stage 5 rewritten.** Upserts the prompt agent with the real SDK,
  grants the UAMI **Azure AI User** on the Foundry account (needed to invoke the
  agent), then patches the web app with `FOUNDRY_PROJECT_ENDPOINT`,
  `FOUNDRY_AGENT_NAME`, `FOUNDRY_AGENT_VERSION`.
- **Env/params.** `webapp-aca.bicep` swaps the old
  `foundryProjectConnection`/`agentId` for `foundryProjectEndpoint`,
  `foundryAgentName`, `foundryAgentVersion`. `outputs.template.json` tracks
  `agentName`/`agentVersion`.
- **agent.py** is now a real local helper: `--ensure` (upsert via
  `create_version`) and `--invoke` (chat via `FoundryAgent`).
- **Dependencies.** `app/requirements.txt` and `agent/requirements.txt` use
  `agent-framework-foundry` + `azure-ai-projects>=2.1.0` + `azure-identity`.

## 2026-06-15 — Automated Foundry agent deployment + Streamlit chat UI

Full end-to-end orchestration for Foundry agents with gpt-4.1 model and Streamlit integration.

- **Automated agent deployment.** `deploy.ps1` Stage 5 now programmatically creates a Foundry agent using the Azure AI SDK (Python). The agent:
  - Connects to the DAB MCP endpoint at `{dabAppUrl}/mcp`
  - Uses `gpt-4.1` as the chat model (deployed in foundation stage)
  - Auto-updates the Streamlit web app with the agent ID after creation
  - Falls back gracefully to manual creation if SDK fails
- **GPT-4.1 chat model.** `foundation.bicep` now deploys `gpt-4.1` (in addition to the embedding model) to support agentic tool calling.
- **Streamlit chat tab.** `app/app.py` adds a new "Chat with Agent" tab that:
  - Uses `st.session_state` for stateful conversation history (in-memory, lost on refresh)
  - Authenticates via UAMI (managed identity) to Foundry
  - Invokes the agent and streams responses in a chat UI
  - Only visible if `FOUNDRY_AGENT_ID` and `FOUNDRY_PROJECT_CONNECTION` env vars are set
- **Streamlit container identity.** `webapp-aca.bicep` now passes Foundry configuration to the Streamlit container via environment variables, which runs as the UAMI for seamless authentication.
- **Local agent testing.** `agent/agent.py` is a standalone script for local development:
  - Create agents: `python agent.py --create`
  - Test invoke: `python agent.py --invoke "your question"`
  - Loads outputs.json for configuration
- **Dependencies.** Updated `app/requirements.txt` and created `agent/requirements.txt` with `azure-ai-projects`, `azure-identity`, `python-dotenv` for Azure SDK support.

## 2026-06-06 — DAB MCP field metadata + digest deploys + agent guidance

Fixes found while wiring the hosted DAB into a Foundry agent.

- **DAB entity `fields` metadata.** `dab-config.json` now declares a `fields`
  array (name + description, with `primary-key` and enum valid-values) on
  `Product` and `ProductReview`, and `parameters` on the search proc. DAB's
  MCP `describe_entities` only reports column names when they're declared
  here — without it, `describe_entities` returned `"fields": []` and agents
  guessed (wrong casing like `category`, or invented Northwind-style names
  like `productName`/`unitPrice`). Removed the earlier `mappings` attempt,
  which does column aliasing and does **not** feed `describe_entities`.
- **`custom-tool` on the search proc.** `FindSimilarReviewsHybrid` now sets
  `"mcp": { "custom-tool": true }`, so it registers as the named MCP tool
  `find_similar_reviews_hybrid` agents can call directly.
- **Deploy by digest, not `:latest`.** `deploy.ps1` resolves each image's
  immutable `@sha256:` digest after `az acr build` and deploys that. Re-pushing
  the same `:latest` tag left the Bicep image parameter unchanged, so Azure
  Container Apps kept the old revision and silently ignored config edits —
  every "redeploy" was a no-op. Digest references force a new revision only
  when image content actually changes.
- **Agent guidance.** `agent/README.md` ships a recommended agent-instruction
  block (force a detailed `describe_entities` before reads; never
  `nameOnly:true` for planning; case-sensitive field names; no `*`; prefer the
  hybrid tool), a "Working with the DAB tools" section, and troubleshooting
  rows for the casing / `*` / invented-field / stale-cache errors.
- **BYO guide.** `byo/README.md` config example now includes `fields`,
  stored-proc `parameters`, and `custom-tool` so user tables work with agents
  from the start.

## 2026-06-06 — Local web-UI dev loop + Python prerequisite

- Default region changed to `westus` (`deploy.ps1`, README,
  `outputs.template.json`).
- Added **Python 3.12+** to the prerequisites table — needed only to run
  the Streamlit web UI locally, not to deploy.
- README: restructured the local web-UI section into a clear
  test-before-deploy loop (deploy core with `-DeployWebApp:$false` → run
  `streamlit run app/app.py` against the hosted DAB → ship the web
  container with `-SkipSqlScripts`). Added a quick-start callout linking
  to Prerequisites + switches.

## 2026-06-06 — Flatten repo into a one-command deployment

Major compaction. The eight numbered `steps/` learning folders are
replaced by a flat structure and a single root orchestrator.

**New structure**

- `deploy.ps1` (repo root) — one idempotent orchestrator that runs
  foundation → SQL data plane → hosted DAB on ACA → optional Streamlit
  web UI. Switches: `-SeedSampleData`, `-InstallAutoEmbedTrigger`,
  `-DeployWebApp`, `-SkipSqlScripts`, `-SkipImageBuild`, `-ImageTag`.
- `infra/` — `foundation.bicep`, `dab-aca.bicep`, and new
  `webapp-aca.bicep` (Streamlit container app on the shared ACA env).
- `sql/` — renumbered: `00`–`02` schema+seed, `10`–`15` embeddings
  (UAMI db user, credential, external model, test, backfill, optional
  trigger), `20`–`22` hybrid search. Token placeholders
  (`<<UAMI_NAME>>`, `<<OPENAI_ENDPOINT>>`, `<<EMBEDDING_DEPLOYMENT>>`)
  substituted at deploy time.
- `dab/` — `dab-config.json`, `Dockerfile`.
- `app/` — new Streamlit web UI (`app.py`, `Dockerfile`,
  `requirements.txt`) that calls the hosted DAB REST endpoints.
- `agent/README.md` — Foundry agent portal walkthrough (not
  orchestrated by `deploy.ps1`).
- `byo/README.md` — consolidated bring-your-own-data guide.
- `teardown.ps1` moved to repo root.
- Single root `outputs.json` (gitignored) + `outputs.template.json`.

**Docs**

- `README.md` rewritten around the one-command quick start.
- New `docs/ARCHITECTURE.md` (deep dive) and `docs/PROJECT_CONTEXT.md`.
- Architecture companion docs and `SECURITY.md` re-pointed from
  `steps/*` paths to the flat layout.

**Removed**

- The entire `steps/` tree (per-step `.md` narratives, per-step
  `deploy.ps1`/`outputs.json`, step BYO appendices, the
  `upgrade-external-model` branch).
- Legacy v1 `sql/sample/` (superseded `sp_invoke_external_rest_endpoint`
  approach).
- `scripts/` (teardown promoted to root).
- Orphans: `.vscode/launch.json` (pointed at a nonexistent
  `agent/agent.py`), `.vscode/settings.json` (personal skill-folder
  config), and `dab/dab-config.template.json` (no consumer — the image
  bakes `dab/dab-config.json`). Dropped the matching
  `dab/dab-config.local.json` ignore rule.

## 2026-06-05 — Security: stop tracking outputs.json and ACA FQDN

Audit found that `outputs.json` files and `.vscode/mcp.json` were
committing subscription IDs, UAMI client/principal IDs, SQL FQDN,
Foundry/OpenAI endpoints, ACR login server, and the public ACA URL
of the hosted (anonymous) DAB MCP server. Tightened what's tracked.

- `.gitignore`:
  - Added `steps/*/outputs.json`.
  - Existing `steps/04-dab-local/dab-config.json` rule unchanged.
- Untracked (file kept locally, generated by `deploy.ps1`):
  - `steps/01-foundation/outputs.json`
  - `steps/05-dab-on-aca/outputs.json`
- New committed templates documenting the schema with placeholders:
  - `steps/01-foundation/outputs.template.json`
  - `steps/05-dab-on-aca/outputs.template.json`
- `.vscode/mcp.json` — `sql-mcp-hosted.url` scrubbed from the real
  ACA FQDN to `https://REPLACE_ME_WITH_acaAppUrl.azurecontainerapps.io/mcp`.
  The `sql-mcp-local-http` entry is unchanged (always
  `http://localhost:5000/mcp`).
- New top-level `SECURITY.md` listing what is and isn't safe to
  commit, how to substitute the `mcp.json` placeholder without
  re-committing it (`git update-index --skip-worktree`), and what
  to do if something sensitive does get committed.
- Root `README.md` "Repository layout" paragraph and
  `steps/01-foundation/step1.md` script-step table updated to note
  that `outputs.json` is gitignored and refers to the template
  sibling + SECURITY.md.
- `steps/05-dab-on-aca/step5.md` substep B updated to explain the
  placeholder and link SECURITY.md.

Note: the previously-tracked values (subscription/UAMI GUIDs, SQL
FQDN, ACA URL) are still in commits before this one. A follow-up
history rewrite with `git filter-repo` will purge them and require a
force-push of `main` and `benk_dev`.

## 2026-06-05 — Step 5 Verify section restructured to mirror step 4

The MCP testing flow in step 5 now follows the same sequence as
step 4 — VS Code Copilot Chat is the primary path, raw PowerShell
is demoted to advanced/troubleshooting.

- `steps/05-dab-on-aca/step5.md` Verify section reorganised:
  - **MCP in VS Code (recommended)** moved up to sit immediately
    after the REST checks, with the same `#### A/B/C/D` substep
    structure as step 4 (A — confirm endpoint reachable, B — add
    server entry, C — `MCP: List Servers`, D — Copilot Chat agent
    mode prompt).
  - The raw PowerShell `tools/list` handshake demoted to
    **"Advanced (optional): raw MCP protocol `tools/list` test"`**
    after the VS Code section, framed as "use this only if you want
    to learn the transport details or debug client/protocol
    behavior". Code block itself unchanged.
  - Tail logs section kept at the end.
- Troubleshooting table gained two new rows: hosted MCP unhealthy
  in `MCP: List Servers`, and the "healthy server but empty Tools
  picker" gotcha (new chat + Agent mode). The old single MCP row
  was rewritten to point at step 4's table for the advanced/raw
  PowerShell errors.

## 2026-06-05 — Reorder: Entra-auth add-on moved to last (step 8)

Auth hardening is orthogonal to the "chat with your data" path, so
the placeholder now sits **after** the optional web UI and Foundry
agent steps instead of breaking the flow between step 5 and the
optional steps.

- Folder renames (git mv, history preserved):
  - `steps/06-calling-hosted-dab/` → `steps/08-optional-entra-auth/`
  - `steps/07-optional-webapp/` → `steps/06-optional-webapp/`
  - `steps/08-optional-foundry-agent/` → `steps/07-optional-foundry-agent/`
- Inner doc renames to match new step numbers:
  - `step6.md` → `step8.md` in the Entra-auth folder
  - `README.md` → `step6.md` in the web-app folder
  - `README.md` → `step7.md` in the Foundry-agent folder
- Step 8 (Entra add-on) header/intro/folder block now reference its
  new step number and folder path, and reframe steps 1–7 as the core
  path with auth as the final optional add-on.
- Step 6 and step 7 placeholders gained top-nav lines (back/up/next).
- Step 5 nav links, "If it's red" hint, "Locking it down" pointer,
  and the entire "What's next" section repointed to the new
  6 → 7 → 8 ordering and new folder paths.
- Root `README.md` step table reordered (5 → 6 web app → 7 agent →
  8 Entra add-on); folder tree updated.
- `docs/architecture/01-solution-overview.md` "VS Code MCP wire-up"
  row now points at step 5's new anchor, since that's where the
  chat wiring lives.

## 2026-06-05 — Step 6 folded into step 5; Entra auth deferred to add-on

Chat-testing the hosted DAB MCP endpoint duplicated the step 4 flow,
so the practical instructions moved into step 5 and step 6 became a
placeholder for the still-to-be-written Entra auth hardening.

- `steps/05-dab-on-aca/step5.md`:
  - Fixed broken top-nav link (`06-calling-hosted-dab/README.md` →
    `step6.md`) and repointed it as "add-on → Entra auth (planned)".
  - Added a new subsection **"Wire the hosted MCP endpoint into VS
    Code Copilot Chat"** under Verify, with three substeps
    (mcp.json paste, `MCP: List Servers` check, agent-mode prompt)
    that mirror step 4's flow but enable the hosted server instead.
  - Reworked the "Locking it down" paragraph and "What's next"
    section to point at steps 7/8 next and treat step 6 as the
    deferred Entra add-on.
- `steps/06-calling-hosted-dab/step6.md` rewritten as an add-on
  placeholder. Explains where chat testing lives now (step 5),
  outlines what the future Entra-auth add-on will cover (app reg,
  `runtime.host.authentication`, entity role flip, `auth` block in
  `mcp.json`, CORS/ingress lockdown), and links the upstream DAB
  Entra docs for anyone who needs it today.
- Root `README.md` table row 6 relabelled as *(add-on, planned)*
  "Entra auth for hosted DAB"; row 5 now mentions the Copilot Chat
  wiring as part of step 5. Prereq G no longer references step 6.

## 2026-06-05 — Docs: clarify DAB MCP display name in VS Code Tools picker

- `steps/04-dab-local/step4.md` — Added a note in the "Test from Copilot
  Chat (agent mode)" subsection clarifying that DAB advertises itself
  in the picker with its own display name (`SQL MCP Server`), not the
  `sql-mcp-local-http` key from `mcp.json`. Lists the six tools that
  appear inside that group.
- `steps/06-calling-hosted-dab/step6.md` — Added a callout in section 4
  noting both hosted and local DAB entries appear as `SQL MCP Server`
  groups in the picker; distinguish them by the URL in the tooltip.

## 2026-06-05 — Step 2 switched to GA `AI_GENERATE_EMBEDDINGS` path

Refactored the staged tutorial so step 2 now creates and uses
`EXTERNAL MODEL EmbeddingModel` directly, and step 3+ assume the
v2 SP shape by default.

- Step 2 SQL refactor:
  - Replaced `sql/03-create-get-embedding-sp.sql` with
    `sql/03-create-external-model.sql`.
  - `sql/04-test-embedding.sql`, `sql/05-backfill-embeddings.sql`, and
    `sql/06-create-auto-embed-trigger.sql` now call
    `AI_GENERATE_EMBEDDINGS(... USE MODEL EmbeddingModel)` directly.
  - Removed `EXECUTE ANY EXTERNAL ENDPOINT` from
    `sql/01-create-uami-db-user.sql` (no longer needed by the main flow).
- Step 2 deploy + docs updated to the new model-first flow.
- Step 3 SQL refactor:
  - `dbo.find_similar_reviews_hybrid` now uses parameters
    `(@queryText, @top)` in `sql/02-create-hybrid-search-sp.sql`.
  - `sql/03-test-hybrid-search.sql` updated to the same shape.
  - `deploy.ps1` no longer substitutes endpoint/deployment tokens.
- Downstream docs/config updated for consistency:
  - Root `README.md` step summaries
  - Step 1 next-step text
  - Step 2/3 BYO appendices
  - Step 4 DAB template and troubleshooting notes
  - Step 5 troubleshooting row for embedding/model failures
  - Step 6 hosted MCP call-shape explanation
  - Architecture docs under `docs/architecture/`.
- `steps/03-hybrid-search-sp/upgrade-external-model/` is now described
  as a legacy/recovery path rather than a required migration.

## 2026-05-11 — Inline SVG diagrams in primary docs

Embedded the architecture SVGs directly into the top-level README and
the relevant step / BYO markdowns, replacing the old ASCII-art boxes:

- `README.md` — "What you will build" now shows `01-solution-overview.svg`.
- `steps/02-embeddings-in-sql/step2.md` — "How embedding-in-SQL works" now shows `02-data-and-embedding-flow.svg`.
- `steps/03-hybrid-search-sp/step3.md` — "How it flows" now shows `03-hybrid-search-flow.svg`.
- `steps/03-hybrid-search-sp/upgrade-external-model/README.md` — adds `04-auth-v1-v2.svg` at the top.
- `steps/02-embeddings-in-sql/byo/README.md` and `steps/04-dab-local/byo/README.md` — both show `05-byo-table-flow.svg`.

## 2026-05-10 — Architecture diagrams: hand-authored SVGs

Mermaid blocks don't render in VS Code's built-in markdown preview
without an extension. Replaced them with hand-authored SVG files that
render inline in any markdown viewer (VS Code default preview, GitHub,
anywhere).

- New: `docs/architecture/0[1-5]-*.svg` (5 files). Plain SVG, no JS,
  consistent palette (Azure blue / SQL red / AI teal / UAMI amber).
- Updated each `docs/architecture/0[1-5]-*.md` to embed the SVG via
  `![](file.svg)` and removed the corresponding ```mermaid``` blocks.
  Surrounding prose retained.
- `docs/architecture/README.md` updated: each diagram now exists in
  three forms (md page, svg image, drawio source). SVG is the rendered
  source of truth; drawio is kept for visual editing convenience.

## 2026-05-10 — Architecture diagrams rewritten in Mermaid + v2 sweep

End-of-night documentation pass. Architecture pages now render inline
on GitHub and in VS Code's markdown preview, and the last few stale v1
SP-shape examples in the step docs are gone.

- `docs/architecture/*.md` rewritten with rich Mermaid diagrams
  reflecting the v2 architecture (UAMI, `EXTERNAL MODEL`, single-front-
  door DAB, MCP wiring). The `.drawio` files are kept as visual editing
  source but Mermaid is the source of truth.
- `docs/architecture/README.md` rewritten to explain the
  Mermaid-as-source-of-truth + drawio-as-convenience model and to map
  diagrams to the steps that build them.
- `steps/04-dab-local/step4.md` REST smoke test body trimmed to v2
  shape `{ queryText, top }`; troubleshooting row about
  `embeddingDeployment` rewritten to point at the EXTERNAL MODEL.
- `steps/04-dab-local/byo/README.md` `curl` example trimmed to v2.
- `steps/03-hybrid-search-sp/byo/README.md` updated to teach the v2 SP
  shape (uses `AI_GENERATE_EMBEDDINGS USE MODEL EmbeddingModel`); added
  a heads-up callout pointing at the upgrade.
- The step 2 docs that still mention `@openAiEndpoint` /
  `@deploymentName` are intentionally left as-is — those are parameters
  on `dbo.get_embedding`, which is still part of step 2 and unaffected
  by the v2 SP signature change.

## 2026-05-10 — Step 3 external-model upgrade is now required

Promoted the `upgrade-external-model/` follow-on from optional to required, and propagated the simpler v2 SP signature into downstream docs.

- `step3.md` final section reworded as a required next step before step 4.
- `upgrade-external-model/README.md` reworded ("Optional" → "Required"), explanation reframed around "why it's split out and required."
- Root `README.md` step 3 row updated to call the upgrade required.
- `steps/04-dab-local/dab-config.json` `FindSimilarReviewsHybrid` description updated to list only `queryText, top`.
- `steps/05-dab-on-aca/step5.md` REST smoke test rewritten to use the v2 body (`{ queryText, top }`).
- `steps/06-calling-hosted-dab/step6.md` agent walkthrough and troubleshooting updated to the v2 shape; removed the "agent needs to know the endpoint and deployment" callouts.

## 2026-05-10 — Step 3 optional upgrade fix

- Removed the `IF @x = N'<<TOKEN>>'` placeholder guards in `01-create-external-model.sql`. PowerShell's `.Replace` substitutes inside string literals too, which made the guards always fire after substitution.

## 2026-05-10 — Step 3 optional upgrade: `CREATE EXTERNAL MODEL` + `AI_GENERATE_EMBEDDINGS`

Added a follow-on under `steps/03-hybrid-search-sp/upgrade-external-model/` that swaps the embedding pipeline from `sp_invoke_external_rest_endpoint` + `dbo.get_embedding` to the native Azure SQL primitives. The original step 3 content is untouched — the upgrade is opt-in.

- New folder: `upgrade-external-model/` with `README.md`, `deploy.ps1`, and three SQL scripts (`01-create-external-model.sql`, `02-create-hybrid-search-sp-v2.sql`, `03-test-hybrid-search-v2.sql`).
- `EmbeddingModel` is registered against the **existing** DSC from step 2 (no new credential, no new auth flow). The UAMI gets `EXECUTE` on the model.
- New SP signature: `dbo.find_similar_reviews_hybrid(@queryText, @top)` — `@openAiEndpoint` and `@embeddingDeployment` are gone. RRF body is unchanged.
- DAB / MCP impact: zero rebuild. DAB reflects the SP signature at runtime, so step 4, 5, and 6 keep working. The MCP `execute_entity` shape collapses to `{ entity: "FindSimilarReviewsHybrid", parameters: { queryText, top } }` after the upgrade.
- Step 3 main doc gets an "Optional follow-up" section that links to the upgrade. Root README step 3 row mentions the upgrade.

## 2026-05-10 — Step 6 simplified to VS Code Copilot Chat only

After getting step 6 working with REST + MCP scripts in PowerShell and Python, decided those overlapped too much with the step 5 verification. Step 6 is now exclusively about wiring the hosted DAB `/mcp` endpoint into **GitHub Copilot Chat agent mode** in VS Code.

- Removed `steps/06-calling-hosted-dab/scripts/` (the four PowerShell + Python smoke tests).
- `steps/06-calling-hosted-dab/step6.md` rewritten: prereqs (VS Code 1.99+, Copilot Chat agent mode), where `mcp.json` lives (user vs workspace scope), how to substitute the step-5 `acaAppUrl` into `vscode/mcp.template.json`, how to verify with `MCP: List Servers`, example natural-language prompts that exercise `describe_entities`, `read_records`, and `execute_entity` against `FindSimilarReviewsHybrid`. Troubleshooting matrix focused on VS Code-side issues (red dot on the server, JSON parse errors, missing `/mcp` suffix, the two `execute_entity` argument-shape gotchas).
- `vscode/mcp.template.json` unchanged.
- Root README link unchanged at `step6.md`; description shortened to "Wire the hosted `/mcp` endpoint into VS Code GitHub Copilot Chat".

## 2026-05-10 — Step 6 (calling hosted DAB) built + verified

- `steps/06-calling-hosted-dab/scripts/Test-DabRest.ps1` + `test_dab_rest.py` — REST smoke tests (list `Product`, list 3 `ProductReview`, POST `FindSimilarReviewsHybrid`). Both auto-discover the DAB URL from `steps/05-dab-on-aca/outputs.json`; `-DabUrl` / `--dab-url` override available.
- `steps/06-calling-hosted-dab/scripts/Test-DabMcp.ps1` + `test_dab_mcp.py` — MCP smoke tests (full Streamable-HTTP handshake → `tools/list` → `tools/call execute_entity`). PowerShell version is hand-rolled with the SSE parser and session-id-array-unwrap gotchas from step 4; Python version uses the official `mcp` SDK's `streamablehttp_client` so the same plumbing is hidden by the library.
- `steps/06-calling-hosted-dab/vscode/mcp.template.json` — drop-in template for VS Code's MCP user/workspace config (`Command Palette → MCP: Open User Configuration`). Replace the placeholder URL with the `acaAppUrl` from step 5 outputs and Copilot Chat agent mode can drive the hosted DAB end-to-end.
- `steps/06-calling-hosted-dab/step6.md` — lesson with two surfaces × two languages table, run-it sections, VS Code wire-up, an Entra "locking it down" preview, and a troubleshooting matrix.
- Placeholder `README.md` removed; root README link updated to `step6.md`.
- **MCP `execute_entity` argument shape gotcha discovered and documented:** SP params go in a nested `parameters` object (mirroring the REST POST body), not flat next to `entity`. Both the PowerShell and Python scripts use the correct shape; troubleshooting table calls this out.
- End-to-end verified against the live ACA FQDN: REST script prints 5 products / 3 reviews / 5 RRF rows; MCP script prints the 6-tool catalog and 5 RRF rows from `tools/call execute_entity`.

## 2026-05-10 — Step 5 verified + three UAMI/ACA hardening fixes

After a fresh ACA deploy, three issues surfaced that local-admin testing in step 4 had hidden. All three are now baked into the per-step SQL/Bicep so a clean re-run of steps 2 and 5 is sufficient.

1. **`You do not have permission to run 'sys.sp_invoke_external_rest_endpoint'`** — the UAMI database user only had `EXECUTE ON SCHEMA::dbo`, but `sp_invoke_external_rest_endpoint` lives in `sys`. Local admin sessions have it implicitly. Fix: `GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [<uami>]` — added to `steps/02-embeddings-in-sql/sql/01-create-uami-db-user.sql`.
2. **`Cannot find the credential '<endpoint>', because it does not exist or you do not have permission`** — same admin-vs-UAMI cliff for the database-scoped credential. Fix: `GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[<endpoint>] TO [<uami>]` — added as a new section at the end of `steps/02-embeddings-in-sql/sql/02-create-credential.sql` (uses the existing `<<UAMI_NAME>>` and `<<OPENAI_ENDPOINT>>` placeholders, prints a skip notice if run standalone without substitution).
3. **`Invoke-RestMethod: Cannot follow an insecure redirection`** on SP POST — DAB returned a 301 with an `http://` Location because ACA's edge does TLS termination and Kestrel wasn't honoring `X-Forwarded-Proto`. Fix: added `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true` to the container env vars in `steps/05-dab-on-aca/bicep/main.bicep`.

`steps/05-dab-on-aca/step5.md` troubleshooting matrix updated with all three rows.

End-to-end verified against the public ACA FQDN: `GET /api/Product` returns rows; `POST /api/FindSimilarReviewsHybrid` (with `openAiEndpoint`, `embeddingDeployment`, `queryText`, `top`) returns the same RRF-ranked review list as step 3's local smoke test.

## 2026-05-10 — Step 5 (DAB on ACA) built

- `steps/05-dab-on-aca/docker/Dockerfile` — `FROM mcr.microsoft.com/azure-databases/data-api-builder:latest`, copies `dab-config.json` into `/App/`.
- `steps/05-dab-on-aca/docker/dab-config.json` — same three entities as step 4 (`Product`, `ProductReview`, `FindSimilarReviewsHybrid`) but `connection-string` is `@env('SQL_CONNECTION_STRING')`; `host.mode: production`; MCP enabled.
- `steps/05-dab-on-aca/bicep/main.bicep` — Log Analytics workspace, ACA managed environment, container app with the step-1 UAMI attached, external ingress on port 5000, secret-backed `SQL_CONNECTION_STRING`, AcrPull role assignment for the UAMI on the ACR. The ACR itself is created by `deploy.ps1` (not Bicep) so the image build can precede the app.
- `steps/05-dab-on-aca/deploy.ps1` — reads step-1 `outputs.json`, derives ACR `uniqSuffix` from the SQL server name, registers `Microsoft.App` / `ContainerRegistry` / `OperationalInsights` providers, idempotent `az acr create` (Basic, admin disabled), `az acr build` via ACR Tasks (no local Docker required), builds the AAD-MI connection string (`Authentication=Active Directory Managed Identity;User Id=<UAMI clientId>`), deploys the Bicep, writes `outputs.json`. Params: `-ImageTag`, `-SkipBuild`.
- `steps/05-dab-on-aca/step5.md` — full lesson: architecture, resource table, prereqs, run-it, verify (REST + MCP `tools/list` against the public FQDN), "how auth works in production" (IMDS → UAMI token → SQL OID claim), "locking it down" recommendations, troubleshooting matrix (provider registration, `acr build` throttling, AcrPull propagation lag → ImagePullBackOff, `Login failed for token-identified principal`, credential trailing slash, MCP gotchas linking back to step 4).
- `steps/05-dab-on-aca/byo/README.md` — BYO appendix: edit `docker/dab-config.json`, rerun `deploy.ps1` (or `-ImageTag v2`), grant EXECUTE/SELECT on non-`dbo` schemas to the UAMI.
- Placeholder `steps/05-dab-on-aca/README.md` removed; root README link updated to `step5.md`.

## 2026-05-10 — Consolidate gitignore

- Removed `steps/04-dab-local/.gitignore`; moved its `dab-config.json` rule into the repo-root `.gitignore` so all ignore rules live in one place.
- Updated the "What's in this folder" tree in `step4.md` accordingly.

## 2026-05-10 — Step 4 verified + DAB MCP handshake docs

- Confirmed step 4 end-to-end: REST `/api/Product`, REST POST `/api/FindSimilarReviewsHybrid`, GraphQL, **and** MCP `tools/list` all working against `dab start` on `localhost:5000`. MCP returned `describe_entities`, `execute_entity`, `read_records`, `update_record`.
- `steps/04-dab-local/step4.md` MCP section rewritten with the full Streamable-HTTP handshake (`initialize` → capture `Mcp-Session-Id` → `notifications/initialized` → `tools/list`) and an SSE parser, plus two PowerShell-specific footguns documented in the troubleshooting table:
  - `Invoke-WebRequest` returns headers as string arrays — must index `[0]` or the next request gets `Session not found`.
  - MCP responses are `text/event-stream` (not JSON), so `Invoke-RestMethod` is replaced with `Invoke-WebRequest` plus a one-liner `Read-McpSse` helper.
- Added `Cannot find the credential '...openai.azure.com/'` row covering the trailing-slash fix.

## 2026-05-10 — Fix: `get_embedding` trailing-slash credential lookup

- `steps/02-embeddings-in-sql/sql/03-create-get-embedding-sp.sql` — strip any trailing `/` from `@openAiEndpoint` before using it as both the URL base and the `@credential` name. Symptom (surfaced when calling `dbo.find_similar_reviews_hybrid` via DAB REST in step 4): `Cannot find the credential 'https://....openai.azure.com/', because it does not exist or you do not have permission.` Step 1's `outputs.json` writes the endpoint with a trailing `/`, but step 2's `02-create-credential.sql` creates the DSC with the slash stripped — so the names mismatched. SP now normalizes internally so every caller (REST body, SQL Editor, trigger) is safe.

## 2026-05-10 — Step 4 (DAB local) built

- New folder `steps/04-dab-local/` with:
  - `dab-config.template.json` — `data-source` (MSSQL, `Authentication=Active Directory Default`), `runtime` enabling REST + GraphQL + MCP in `development` host mode, three entities: `Product` (table `dbo.Products`), `ProductReview` (table `dbo.ProductReviews`), `FindSimilarReviewsHybrid` (stored procedure `dbo.find_similar_reviews_hybrid`, REST POST, GraphQL mutation). All permissions `anonymous` for local dev — locked down in step 5.
  - `deploy.ps1` — reads `steps/01-foundation/outputs.json`, verifies `dotnet`, `dab`, `az login`, substitutes `<<SQL_FQDN>>` / `<<SQL_DB>>` into the template, writes `dab-config.json`. Does NOT start the server by default; optional `-LaunchDab` switch runs `dab start` inline.
  - `.gitignore` for the generated `dab-config.json`.
  - `step4.md` — full lesson: what DAB is, how local auth via `DefaultAzureCredential` + `az login` works, run/verify (REST `/api/Product`, REST POST `/api/FindSimilarReviewsHybrid`, GraphQL, MCP `tools/list`), troubleshooting matrix, transition to step 5.
  - `byo/README.md` — adding a custom entity for a BYO table or SP (both JSON-edit and `dab add` paths).
- Removed `steps/04-dab-local/README.md` placeholder.
- Root README link for step 4 updated to `step4.md` and updated description to mention GraphQL + BYO appendix.

## 2026-05-10 — Step 3 (Hybrid search SP) built

- New folder `steps/03-hybrid-search-sp/` with:
  - `sql/01-create-fulltext-index.sql` — idempotent `ftCatalog` + `CREATE FULLTEXT INDEX ON dbo.ProductReviews(ReviewText)` keyed on `PK_ProductReviews`. Adapted from legacy `sql/sample/06`.
  - `sql/02-create-hybrid-search-sp.sql` — `dbo.find_similar_reviews_hybrid`: embeds the query via `dbo.get_embedding`, takes top-50 by vector + top-50 by `FREETEXTTABLE`, fuses with RRF ($k=60$), returns top-N with both component ranks/scores. Adapted from legacy `sql/sample/07`.
  - `sql/03-test-hybrid-search.sql` — three demo queries (semantic-leaning, keyword-leaning, mixed). Uses the same `<<TOKEN>>` placeholder pattern as step 2 scripts so it's runnable from the SQL Editor.
  - `deploy.ps1` — reads `outputs.json`, substitutes tokens, pipes each script through `sqlcmd -G`. Same pattern as step 2.
  - `step3.md` — full lesson (RRF math, flow diagram, run/verify/troubleshoot, BYO link).
  - `byo/README.md` — copy-and-rename recipe for `dbo.find_similar_<your_table>_hybrid`.
- Root README link for step 3 updated to `step3.md`.

## 2026-05-10 — Step 2 fixes after first end-to-end run

- **`dbo.get_embedding` now passes `@credential` explicitly** to `sp_invoke_external_rest_endpoint` instead of relying on URL-prefix auto-resolution. Auto-resolution silently failed in our environment — Foundry returned 401 "Access denied due to invalid subscription key" because no bearer token was being attached. Forcing `@credential = @openAiEndpoint` (which is the credential's name) made the call succeed.
- **`dbo.get_embedding` now surfaces failures via `RAISERROR`** with the HTTP status code and raw response body, instead of silently returning NULL. This is what let us catch the 401 above on the very next run; the previous version had been quietly leaving every row's `ReviewEmbedding` as NULL.
- **Inline `EXEC(string + var + ...)` replaced with `SET @sql = ...; EXEC sp_executesql @sql;`** in scripts 01 and 02. T-SQL doesn't allow concatenation inside `EXEC()`; it produced `Incorrect syntax near 'REPLACE'`.
- Verified end-to-end: 18 of 18 reviews embedded.

## 2026-05-10 — Step 2 SQL scripts made editor-runnable

- Replaced the `sqlcmd`-only `:setvar` / `$(VAR)` pattern in scripts 01, 02, 04, 05, 06 with a small editable `DECLARE` block at the top of each file using `<<TOKEN>>` placeholders. Users can now run any script directly from the VS Code MSSQL extension, SSMS, or Azure Data Studio after editing two lines (or one).
- `deploy.ps1` now reads each `.sql` file, substitutes the placeholders against `outputs.json` values, writes the result to a temp file, runs it via `sqlcmd -G -i`, then deletes the temp file. No more `-v VAR=value` plumbing.
- Each script raises a clear `RAISERROR` and stops if the placeholder wasn't replaced — replacing the cryptic `failed to parse url. HRESULT: 0x80072ee6`.
- Trigger script 06 builds the trigger body via `REPLACE` rather than literal interpolation, so editor users get the same behavior.
- `step2.md` "Run it" section restructured into "Option A — deploy.ps1" and "Option B — your SQL Editor", with a token-to-outputs.json field table and an explicit reminder to connect to `ProductsDB` (not `master`). Verify section 2 rewritten to use a `sqlcmd -Q` here-string instead of `-v`+`-i`.

## 2026-05-11 — Step 2 (Embeddings in SQL) built

- **Step 2 added.** Folder `steps/02-embeddings-in-sql/` now contains a full lesson, deploy script, six numbered SQL files, and a BYO appendix.
- **SQL artifacts** (`sql/01-create-uami-db-user.sql` … `sql/06-create-auto-embed-trigger.sql`):
  1. Contained DB user for the step-1 UAMI with `db_datareader` + `db_datawriter` + `EXECUTE ON SCHEMA::dbo` (sets up DAB login for step 5 too).
  2. Database master key + `DATABASE SCOPED CREDENTIAL` named after the OpenAI endpoint, `IDENTITY = 'Managed Identity'`. Replaces `sql/sample/03`.
  3. `dbo.get_embedding` SP wrapping `sp_invoke_external_rest_endpoint` against `…/openai/deployments/{name}/embeddings?api-version=2024-06-01`. Replaces `sql/sample/04`.
  4. Smoke-test script that calls the SP on a single string and returns the JSON-serialized vector for inspection.
  5. Idempotent backfill cursor over `dbo.ProductReviews WHERE ReviewEmbedding IS NULL`.
  6. Optional auto-embed trigger created via dynamic SQL so the endpoint + deployment are baked into the trigger body — replaces the `SESSION_CONTEXT` pattern in legacy `sql/sample/08`.
- **`deploy.ps1`** reads `steps/01-foundation/outputs.json` so the learner doesn't retype anything; strips the trailing `/` off the OpenAI endpoint so the DSC name and request URL match; switches `-InstallAutoEmbedTrigger` and `-SkipBackfill`.
- **`step2.md`** lesson follows the step-1 naming convention; contains the runtime diagram, what-gets-created table, run/verify/troubleshoot, BYO link, and next-step pointer.
- **`byo/README.md`** walks through making any user-supplied table embeddable using the same SP and credential.
- **Root README** link for step 2 updated from `README.md` to `step2.md`.
- Legacy `sql/sample/03`, `04`, and `08` are now superseded by the step-2 versions; will be deleted when step 3 lands (which absorbs `sql/sample/06` + `07`).

## 2026-05-10 — Tutorial reset

- **Project reframed as a step-by-step tutorial.** The previous "deploy everything at once" structure (single Bicep, monolithic deploy scripts, Foundry agent baked in) made it hard for a learner to understand what each piece did and why. New structure: numbered `steps/NN-…/` folders, each self-contained with its own README + Bicep + deploy script, deployed in order by the reader.
- **Hard reset of obsolete artifacts.** Resource group `rg-sql-rag-dev` deleted by user before the reset. Removed from the repo: `agent/` (Foundry SDK agent — moved to a portal-only walkthrough in step 8), `bicep/` (monolithic), `infra/` (Terraform mirror, not maintained going forward), `webapp/` and `dab/` (will be reintroduced in steps 7 and 4 respectively as they're taught), `scripts/00..03` and `add-byo-entity.ps1` and `diag-mcp.ps1`, the old root `README.md`, `docs/PROJECT_CONTEXT.md` (parked-agent narrative is no longer accurate), `docs/cost-breakdown.md` (will be re-written per-step), `sql/user/` and `sql/README.md`.
- **New scaffold:**
  ```
  README.md                     ← tutorial TOC
  scripts/teardown.ps1          ← retained
  steps/01-foundation/ … 08-optional-foundry-agent/
  docs/architecture/            ← retained
  docs/CHANGELOG.md             ← this file
  ```
  Steps 02–08 contain placeholder READMEs only; each will be built in turn after the previous one is verified by the learner.
- **Single-UAMI design.** The whole tutorial uses one User-Assigned Managed Identity for all service-to-service calls (SQL → Foundry, DAB → SQL, ACA → ACR). Required because the target subscription forbids local-auth on Azure SQL and on Cognitive Services. Permissions are accumulated step-by-step and documented in each step's README.
- **Bicep-only IaC**, parameterized on `-NamePrefix`, `-EnvironmentName`, `-Location`, `-ResourceGroupName`. Globally-unique names use `uniqueString(sub, rg)` for stability across re-runs.
- **Sample data is opt-out, not opt-in.** Step 1's deploy script seeds 10 products and 18 reviews by default; pass `-SeedSampleData:$false` to skip. Step 2 will include a "bring your own table" appendix that can be used at any time, with or without the sample data.
- **Step 1 built and ready to test.** Bicep compiles clean; deploy script + lesson README in place. Steps 2–8 are placeholder READMEs only.

## 2026-05-10 — (superseded by reset above)
- **Documentation overhaul** to make the repo usable and maintainable by a human operator without context from the build session:
  - Rewrote `README.md` from a 25-line stub to a comprehensive operator-grade guide. Sections: TOC, "What this project is", "What you get end-to-end", "What is deployed and why", architecture data flow, repository layout, prerequisites, fast-path deploy, local development and testing (sqlcmd smoke test, Streamlit local, DAB local with `--mcp-stdio`, Python agent local), Foundry agent path / current status, BYO tables, maintenance and operations, troubleshooting table, cost considerations, tear down, reference docs index.
  - Expanded `docs/PROJECT_CONTEXT.md` from 41 lines to a deep technical reference covering: design decisions and why, naming convention, repository layout reference, per-component "what / why / SKU" deep dive, three explicit auth flows (dev → SQL, SQL → OpenAI, agent → Foundry), SQL artifacts script-by-script, annotated DAB config, live deployment table, Foundry agent gap with options A–D, operational runbooks (logs, force-revision, MCP probe, schema redeploy, etc.), known limitations, future enhancements.
  - Replaced stub READMEs in `agent/`, `dab/`, `webapp/`, `sql/`, `sql/user/`, `infra/`. Each now covers: file inventory, env vars, run-locally, run-in-cloud, troubleshooting. `infra/README.md` is explicitly flagged as legacy (Terraform retained for reference; Bicep is the active path).
  - Added `scripts/README.md` (previously missing): inventory, common parameters, recipes (full deploy / schema-only / image-refresh / BYO entity / teardown), conventions (`$ErrorActionPreference = "Stop"`, UTF-8 forcing, ipify-based firewall), troubleshooting.
  - Refreshed `docs/cost-breakdown.md` with concrete SKU-level dev-baseline figures: Azure SQL `GP_S_Gen5_2` serverless (~$5–15/mo idle, ~$70/mo always-on), ACR Basic (~$5/mo), Log Analytics (~$2–5/mo), ACA Consumption (scales to zero), OpenAI `gpt-4.1-mini` + `text-embedding-3-small` (<$1/mo for demo). Total dev idle ~$15–35/mo. Documented variability levers and cost-saving tips.
  - No code or infrastructure changes this session.

## 2026-05-09
- Validated Foundry agent path end-to-end and identified a documented Foundry/DAB compatibility gap.
  - Upgraded `agent/requirements.txt` from `azure-ai-projects>=1.0.0b10` to `>=2.1.0` (GA). The 1.x preview was missing `MCPTool` and `PromptAgentDefinition`. Pinned `openai>=2.0.0` for the new `responses.create` + `extra_body={"agent_reference":...}` invocation pattern.
  - Refactored `agent/agent.py` for the 2.1 SDK: `project.agents.create_version` + `PromptAgentDefinition(...tools=[MCPTool(...)])`, then `openai = project.get_openai_client(); openai.responses.create(...)` and `project.agents.delete_version` for cleanup. Set `MCPTool(require_approval="never")` because DAB's anonymous perms already gate destructive ops.
  - Confirmed Foundry hosted-MCP works for this project: created a control agent against the public `https://learn.microsoft.com/api/mcp` server and got a 3-bullet summary of "Azure Data API Builder" returned through `responses.create`.
  - Confirmed DAB's MCP endpoint is reachable and functional via direct `Invoke-WebRequest` JSON-RPC `initialize` (returns `Mcp-Session-Id` header + SSE body). Subsequent `tools/list` requires the same `Mcp-Session-Id` header echoed back; without it DAB returns `400 Bad Request: Mcp-Session-Id header is required`.
  - **Compatibility gap documented**: Foundry hosted MCP requires **stateless** MCP servers. Per [MS Learn — Foundry MCP authentication, "Host a local MCP server" table](https://learn.microsoft.com/azure/foundry/agents/how-to/mcp-authentication#host-a-local-mcp-server): both Azure Container Apps and Azure Functions hosting rows list **State: Stateless only**. DAB's MCP is stateful (server-managed sessions keyed by `Mcp-Session-Id`). DAB exposes no stateless toggle in CLI/config schema; nothing was found in `Azure/data-api-builder` repo issues or `src/Service/Startup.cs` (`AddDabMcpServer` / `MapDabMcp`) to disable session affinity. Project connections (`project_connection_id`) only inject auth headers and don't change transport semantics.
  - Independent validation that the rest of the chain is healthy: `EXEC dbo.find_similar_reviews_hybrid 'comfortable chair for long workdays', 5, 5, 60, 1.0, 0.5` over `sqlcmd ActiveDirectoryDefault` returns Ergo Chair Pro at RRF 0.0173 plus two more rows. SQL → MI → OpenAI embeddings → vector + full-text + RRF is end-to-end working.
  - Decision: park the hosted-agent-over-MCP path for now. `agent/agent.py` is functionally correct against the SDK; it cannot complete a tool call against DAB until either (a) DAB ships a stateless MCP mode, (b) we put a stateless MCP shim in front of DAB, or (c) we move the agent to use `OpenApiTool` against DAB's REST surface. See `docs/PROJECT_CONTEXT.md` "Foundry agent path" for the documented options.
  - No infrastructure changes this session. All deployed resources in `rg-sql-rag-dev` remain healthy.

## 2026-05-08
- Switched OpenAI access from API keys to managed identity to satisfy subscription Entra-only auth policy:
  - `bicep/modules/sql.bicep`: added `identity: SystemAssigned` to the SQL server and exposed `principalId` output.
  - `bicep/modules/foundry.bicep`: re-enabled `disableLocalAuth: true` and added a role-assignment loop granting **Cognitive Services User** to a list of caller principal IDs (SQL MI, DAB MI, webapp MI).
  - `bicep/modules/aca-app-webapp.bicep`: added `OPENAI_ENDPOINT` / `OPENAI_EMBEDDING_DEPLOYMENT` env vars; both ACA apps already had system-assigned MIs.
  - `bicep/resources.bicep`: passes the three principals into `foundry`; computes deterministic OpenAI endpoint locally to avoid module cycle (`foundry → webapp → foundry`).
  - `sql/sample/03-store-openai-credentials.sql`: rewritten to create a database master key (if missing) and a `DATABASE SCOPED CREDENTIAL` named after `OPENAI_ENDPOINT` with `IDENTITY = 'Managed Identity'` (resourceid = `https://cognitiveservices.azure.com`).
  - `sql/sample/04-create-get-embedding-sp.sql`: precomputes `@url` so `sp_invoke_external_rest_endpoint` resolves the credential by URL prefix without an explicit `@credential` parameter.
  - `sql/sample/08-embedding-trigger.sql`: explicit `CONVERT(NVARCHAR(...), SESSION_CONTEXT(...))` to satisfy implicit-conversion rules.
  - `scripts/01-deploy-sql-schema.ps1`: removed `OpenAiApiKey` parameter; trimmed trailing slash on endpoint; added `99-create-aca-users.sql` to the ordered execution list.
- Deployed Foundry model deployments (`chat` = `gpt-4.1-mini` 2025-04-14 GlobalStandard, `embedding` = `text-embedding-3-small` 1 GlobalStandard); replaces deprecated `gpt-4o-mini` 2024-07-18.
- Hardened deploy scripts (`02-deploy-dab.ps1`, `03-deploy-webapp.ps1`):
  - Force `PYTHONIOENCODING=utf-8` and UTF-8 console output to avoid `colorama` charmap crashes when `az acr build` streams non-cp1252 bytes.
  - Replaced silent `| Out-Null` with explicit `$LASTEXITCODE` checks so failures surface immediately.
- Modernized `webapp/Dockerfile`: replaced deprecated `apt-key add -` (removed in Debian 13) with `gpg --dearmor` keyring layout, fixing build failures on `python:3.12-slim`.
- Re-added `FindSimilarReviewsHybrid` stored-procedure entity to `dab/dab-config.json` (anonymous execute, POST).
- Populated `agent/.env` with the deployed `FOUNDRY_PROJECT_ENDPOINT` and DAB MCP URL.
- Verified end-to-end: schema 00–08 + 99 deployed cleanly; embeddings populated for all 18 reviews; DAB and webapp ACA revisions report `Healthy`.

## 2026-05-07 (In Progress)
- Parameterized `scripts/00-bootstrap.ps1` to accept PowerShell parameters for `NamePrefix`, `NameSuffix`, `Location`, and `ResourceGroupName` instead of requiring manual `terraform.tfvars` edits.
- Migrated infrastructure from Terraform to Bicep due to azapi schema validation issues with `Microsoft.CognitiveServices/accounts.allowProjectManagement` (required for Foundry project creation).
- Added `bicep/main.bicep`, `bicep/resources.bicep`, and modules: `sql.bicep`, `acr.bicep`, `aca-environment.bicep`, `aca-app-dab.bicep`, `aca-app-webapp.bicep`, `foundry.bicep`.
- Updated `00-bootstrap.ps1` to invoke `az deployment sub create`/`what-if` with auto-resolved Entra admin login from `az ad signed-in-user show`.
- Updated `teardown.ps1` to delete the resource group via `az group delete --name <ResourceGroupName>`.
- Added placeholder public image `mcr.microsoft.com/k8se/quickstart:latest` for both ACA apps so initial provisioning succeeds before container build/push; deploy scripts replace it with the real image.
- Successfully deployed full infrastructure stack (SQL, ACR, ACA env+apps, Foundry account+project) to `rg-sql-rag-dev` in West US 2.
- Rewrote `scripts/01-deploy-sql-schema.ps1` to use go-sqlcmd (`sqlcmd` v1.9+) with `--authentication-method ActiveDirectoryDefault` instead of `Invoke-Sqlcmd` (which threw `Microsoft.Data.SqlClient.TdsParser` initializer errors on PowerShell 7).
- Added auto-firewall-rule registration in `01-deploy-sql-schema.ps1` (uses `Invoke-RestMethod https://api.ipify.org`) and a serverless cold-start warmup loop (12×15s retries on `SELECT 1`).
- Added skip logic for OpenAI-dependent SQL scripts (03/04/05/07/08) so the base schema, seed data, and full-text catalog deploy successfully without OpenAI credentials.
- Fixed `sql/sample/07-create-find-similar-hybrid-sp.sql`: declared a fixed-size `@keywordQuery NVARCHAR(4000)` because `FREETEXTTABLE` rejects `nvarchar(max)` arguments.
- Successfully deployed schema (00, 01, 02, 06) to `ProductsDB` on `sqlrag-sql-dev.database.windows.net`.

## 2026-05-07
- Initialized repository structure for Terraform, SQL, DAB, web app, and agent.
- Added bootstrap context files and Copilot session instructions.
- Added Terraform root files and modules for SQL, OpenAI, ACR, Container Apps, and Foundry project provisioning.
- Added SQL scripts for schema creation, seed data, OpenAI credential storage, embedding generation, hybrid search SP, and embedding trigger.
- Added DAB configuration and Dockerfile for SQL MCP hosting.
- Added Streamlit app and container scaffolding for standalone vector search without agent dependency.
- Added Python Foundry agent scaffold with MCP tool integration.
- Added deployment helper PowerShell scripts for bootstrap, SQL deployment, DAB deployment, web app deployment, BYO entity, and teardown.
- Added editable color architecture diagrams in draw.io format with companion documentation.
- Switched SQL provisioning to Entra-only authentication and removed SQL login/password dependency from deployment inputs.
- Updated naming to `{prefix}-{resource-type}` with a required user-supplied `name_suffix` for globally unique resources (SQL server, ACR, AI Services).
- Added `deploy_model_deployments` toggle to allow infrastructure deployment when subscription model quota/access is unavailable.
- Updated Foundry account provisioning to set `allowProjectManagement = true` for project creation compatibility.
