# Connect a Foundry agent to your data (optional)

`deploy.ps1` gives you a hosted MCP server: the DAB container exposes
`tools/list` and `tools/call` at `https://<your-dab-app>/mcp`. Any
MCP-aware client can use it. This guide wires it into an **Azure AI Foundry
agent** so you can chat with your data in the Foundry playground.

This is a **portal walkthrough on purpose.** The Foundry agent SDK surface
for custom MCP tools has been moving quickly; the portal path is the most
reliable today. The orchestrator does **not** create the agent for you.

---

## Prerequisites

- You ran [`deploy.ps1`](../deploy.ps1). Your hosted DAB URL is in
  [`outputs.json`](../outputs.json) as `dabAppUrl`.
- The Foundry **account** and **project** created by the foundation deploy
  (`foundryAccountName` / `foundryProjectName` in `outputs.json`).
- Your hosted DAB `/mcp` endpoint is reachable over the public internet.
  By default it's **anonymous** — fine for a demo, but see
  [SECURITY.md](../SECURITY.md) before exposing it more widely.

---

## 1. Deploy a chat model

The foundation deploy only created the **embedding** model. The agent needs
a **chat** model that supports tool calling.

1. Open [https://ai.azure.com](https://ai.azure.com) and select your project
   (`foundryProjectName`).
2. **Models + endpoints → Deploy model → Deploy base model.**
3. Pick a tool-calling chat model (e.g. `gpt-4o` or `gpt-4o-mini`), accept
   the defaults, and deploy.

---

## 2. Create the agent

1. In the project, go to **Agents → New agent**.
2. Give it a name and select the chat model you just deployed.
3. Add instructions. **Use the block below** — it prevents the most common
   failures with DAB's table tools (see
   [Working with the DAB tools](#working-with-the-dab-tools) for why):

   > You answer questions about products and product reviews by calling the
   > DAB MCP tools. Rules you must follow:
   >
   > 1. Before any `read_records`, `create_record`, `update_record`,
   >    `delete_record`, or `aggregate_records` call, FIRST call
   >    `describe_entities` with the `entities` parameter for the specific
   >    entity (for example `{"entities":["Product"]}`) to get its real
   >    field list.
   > 2. NEVER call `describe_entities` with `nameOnly: true` for query
   >    planning — it omits the field names you need.
   > 3. Use field names EXACTLY as returned by `describe_entities`. They are
   >    case-sensitive (e.g. `Category`, not `category`). Never invent field
   >    names, and never pass `*` to `select` (omit `select` to return all
   >    fields).
   > 4. To search reviews by meaning, prefer the
   >    `find_similar_reviews_hybrid` tool with `queryText` and `top`.
   > 5. Ground every answer in the rows the tools return, and cite the
   >    review text you used.

---

## 3. Add your hosted DAB as a Custom MCP tool

1. On the agent, open **Tools → Add tool → Custom (MCP)**.
2. **Server URL:** your DAB MCP endpoint — `dabAppUrl` + `/mcp`:

   ```
   https://<your-dab-app>.<region>.azurecontainerapps.io/mcp
   ```

3. Leave auth as **anonymous** (matches the default DAB config).
4. Save. Foundry calls `tools/list` and should discover:
   - `Product`, `ProductReview` (DML over the tables)
   - `FindSimilarReviewsHybrid` (the hybrid search stored procedure)

---

## 4. Chat with your data

In the agent playground, ask something the data can answer:

> *Which products do reviewers say are good for long hours of use?*

The agent calls `find_similar_reviews_hybrid`, gets the top reviews ranked by
Reciprocal Rank Fusion, and answers from them. If you added your own table
via [byo/README.md](../byo/README.md), its tools appear here automatically.

---

## Working with the DAB tools

DAB's MCP server exposes a generic CRUD surface (`describe_entities`,
`read_records`, `aggregate_records`, …) plus the named
`find_similar_reviews_hybrid` tool. The generic table tools have two sharp
edges that trip up agents — both are handled by the instruction block in
[step 2](#2-create-the-agent), but it helps to understand them:

**1. The agent must discover fields before reading them.** DAB only knows a
column exists if it's declared in the entity's `fields` array in
[`dab/dab-config.json`](../dab/dab-config.json) (this repo declares them all).
The agent learns those names by calling `describe_entities` — but only if it
calls it **with detail**. A call like `describe_entities({ "nameOnly": true })`
returns entity names *without* fields, and an agent that stops there will
**guess** column names (often inventing generic ones like `productName` or
`unitPrice` that don't exist here). Always have it call
`describe_entities({ "entities": ["Product"] })` first.

**2. Field names are case-sensitive.** DAB matches `Category` exactly; a
filter on `category` returns *"Could not find a property named 'category'"*.
The real column names in this dataset are:

| Entity | Fields |
|---|---|
| `Product` | `ProductID`, `Name`, `Category`, `Price`, `Cost`, `Inventory`, `CreatedAt` |
| `ProductReview` | `ReviewID`, `ProductID`, `ReviewerName`, `ReviewText`, `Rating`, `CreatedAt` |

`Category` valid values: `Furniture`, `Electronics`, `Office Supplies`,
`Accessories`.

The `find_similar_reviews_hybrid` tool has neither problem — it takes only
`queryText` and `top`, so there are no field names or wildcards for the agent
to get wrong. It's the most reliable entry point and the point of this
accelerator.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Tool list is empty | Open `https://<your-dab-app>/mcp` directly; if it doesn't respond, check `az containerapp logs show -g <rg> -n <dabAppName> --follow`. |
| Agent can't reach the server | The DAB app must have **external** ingress (it does by default). Confirm `dabAppUrl` loads in a browser. |
| Model has no "Tools" option | You deployed an embedding or non-tool-calling model. Deploy a chat model that supports function/tool calling. |
| 401/403 from the tool | If you added Entra auth to DAB, the anonymous MCP config no longer applies — configure the tool's auth to match. |
| *"Could not find a property named 'category'"* | The agent used the wrong casing. Field names are case-sensitive (`Category`). Use the step-2 instruction block so the agent reads names from `describe_entities`. |
| *"Invalid field to be returned requested: \*"* | The agent sent `select: "*"`. DAB rejects `*`; omit `select` to return all fields, or list real field names. |
| Agent invents fields like `productName`, `unitPrice` | It called `describe_entities` with `nameOnly: true` (or skipped it) and guessed. Add the step-2 instructions forcing a detailed `describe_entities` call first. |
| Tools/fields look stale after a redeploy | Foundry caches the tool list per agent. **Remove and re-add** the Custom (MCP) tool, or create a new agent, so it re-reads `describe_entities`. |
