# The Foundry agent

`deploy.ps1` creates a **Foundry prompt agent** named `chat-with-your-data`
end-to-end — no portal steps. The agent's model, instructions, and tool all
live in the Foundry agent definition, and its only tool is the hosted DAB
`/mcp` endpoint. You can chat with it three ways:

- the **Chat with Agent** tab in the Streamlit web app,
- the Foundry **playground** (it appears in the new Agents experience), and
- locally with [`agent.py`](agent.py).

This used to be a manual portal walkthrough. It is now fully orchestrated by
[Stage 5 of `deploy.ps1`](../deploy.ps1), using the `azure-ai-projects` SDK
to create the agent and the **Microsoft Agent Framework SDK**
(`agent_framework.foundry.FoundryAgent`) to invoke it.

---

## What the deploy creates

| Piece | Detail |
|---|---|
| **Chat model** | `gpt-4.1`, deployed in Stage 1 as the **`chat`** deployment (alongside the embedding model). |
| **Prompt agent** | `chat-with-your-data`, created in Stage 5 via `agents.create_version(...)` + `PromptAgentDefinition`. `create_version` is an upsert, so re-running `deploy.ps1` rolls a new version instead of duplicating. |
| **Tool** | One `MCPTool` pointing at your DAB `/mcp` endpoint (`dabAppUrl` + `/mcp`), `require_approval: never`. |
| **RBAC** | The UAMI is granted **Foundry User** on the Foundry account — the role that authorizes agent/Responses-API invocation. |
| **Chat tab wiring** | The web app gets `FOUNDRY_PROJECT_ENDPOINT`, `FOUNDRY_AGENT_NAME`, `FOUNDRY_AGENT_VERSION`, and `AZURE_CLIENT_ID` (the UAMI) so the tab can invoke the agent as the managed identity. |

> The agent references the model by its **deployment name** (`chat`), not the
> model name (`gpt-4.1`). The Responses API resolves the deployment name; using
> the model name returns `DeploymentNotFound`.

---

## Use it

### Chat tab in the web app

Open `webAppUrl` from [`outputs.json`](../outputs.json) and pick the
**Chat with Agent** tab (it only appears when the agent env vars are set).
Ask something the data can answer:

> *Which products do reviewers say are good for long hours of use?*

The agent calls `find_similar_reviews_hybrid`, gets the top reviews ranked by
Reciprocal Rank Fusion, and answers from them. History persists for the
session (Streamlit session state).

### Foundry playground

Open [https://ai.azure.com](https://ai.azure.com), select your project
(`foundryProjectName` in `outputs.json`), and open the `chat-with-your-data`
agent under **Agents**. If the playground shows a transient *"Project not
found"*, hard-refresh — it's a portal context cache, not a real error.

### Locally with `agent.py`

```powershell
pip install -r agent/requirements.txt
az login   # DefaultAzureCredential uses your CLI login locally

# Create or update the agent definition (same call deploy.ps1 makes)
python agent/agent.py --ensure

# Chat with it through the Agent Framework SDK
python agent/agent.py --invoke "Which products are good for long hours of use?"
```

`agent.py` reads [`outputs.json`](../outputs.json) for the project endpoint,
DAB URL, and chat deployment name.

---

## How invocation works

The web app and `agent.py` both use the **Microsoft Agent Framework SDK**:

```python
from agent_framework.foundry import FoundryAgent
from azure.identity import DefaultAzureCredential

agent = FoundryAgent(
    project_endpoint=FOUNDRY_PROJECT_ENDPOINT,
    agent_name="chat-with-your-data",
    agent_version="9",            # optional; omit for latest
    credential=DefaultAzureCredential(),
)
result = await agent.run("…")     # result.text holds the answer
```

In Azure, `DefaultAzureCredential` resolves to the container's UAMI because
`AZURE_CLIENT_ID` is set to the UAMI's client ID. Locally it falls back to
your `az login`. Either principal needs **Foundry User** on the Foundry
account.

---

## Working with the DAB tools

DAB's MCP server exposes a generic CRUD surface (`describe_entities`,
`read_records`, `aggregate_records`, …) plus the named
`find_similar_reviews_hybrid` tool. The generic table tools have two sharp
edges that trip up agents — both are handled by the agent's built-in
instructions (set in Stage 5 / [`agent.py`](agent.py)), but it helps to
understand them:

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
| `DefaultAzureCredential failed to retrieve a token` / *Unable to load the proper Managed Identity* | The web container needs `AZURE_CLIENT_ID` set to the UAMI client ID so `DefaultAzureCredential` targets the user-assigned identity. `deploy.ps1` sets this; if you see it after a manual change, re-apply the env var. |
| 403 / *PermissionDenied* invoking the agent | The calling identity (UAMI in Azure, or your `az login` locally) needs **Foundry User** on the Foundry account. Role propagation can take a minute or two. |
| `DeploymentNotFound` | The agent's `model` must be the **deployment** name (`chat`), not the model name (`gpt-4.1`). |
| *Project not found* in the Foundry playground | Portal context cache — hard-refresh (Ctrl+F5) or re-select the project. The agent still works via SDK. |
| `No module named 'aiohttp'` | `agent-framework-foundry` does not pull `aiohttp` automatically; it's pinned in [`app/requirements.txt`](../app/requirements.txt) and [`agent/requirements.txt`](requirements.txt). Reinstall requirements. |
| Tool list is empty | Open `https://<your-dab-app>/mcp` directly; if it doesn't respond, check `az containerapp logs show -g <rg> -n <dabAppName> --follow`. |
| Agent can't reach the server | The DAB app must have **external** ingress (it does by default). Confirm `dabAppUrl` loads in a browser. |
| 401/403 from the MCP tool | If you added Entra auth to DAB, the anonymous MCP config no longer applies — configure the tool's auth to match. |
| *"Could not find a property named 'category'"* | The agent used the wrong casing. Field names are case-sensitive (`Category`). The agent's instructions force a detailed `describe_entities` first — re-`--ensure` if you edited them. |
| *"Invalid field to be returned requested: \*"* | The agent sent `select: "*"`. DAB rejects `*`; omit `select` to return all fields, or list real field names. |
| Agent invents fields like `productName`, `unitPrice` | It called `describe_entities` with `nameOnly: true` (or skipped it) and guessed. The shipped instructions prevent this; re-`--ensure` to restore them. |
| Tools/fields look stale after a redeploy | Foundry caches the tool list per agent version. Re-run `deploy.ps1` (or `agent.py --ensure`) to roll a new version that re-reads `describe_entities`. |
