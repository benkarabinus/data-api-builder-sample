"""
Local management + smoke-test helper for the Foundry "chat-with-your-data" agent.

The agent is a Foundry **prompt agent**: its model, instructions, and DAB MCP
tool live in the Foundry project (visible in the Foundry Agents UI). This script
mirrors what deploy.ps1 Stage 5 does, so you can iterate locally.

  python agent.py --ensure                 # create/update the agent version
  python agent.py --invoke "your question" # chat with it (Agent Framework SDK)

Configuration is read from ../outputs.json (written by deploy.ps1). Auth uses
DefaultAzureCredential (az login locally, or the UAMI in Azure).
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path
from agent_framework.foundry import FoundryAgent
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
from azure.identity import DefaultAzureCredential

OUTPUTS_FILE = Path(__file__).parent.parent / "outputs.json"
AGENT_NAME = "chat-with-your-data"

INSTRUCTIONS = (
    "You answer questions about products and product reviews by calling the "
    "DAB MCP tools. Rules you must follow:\n\n"
    "1. Before any read_records, create_record, update_record, delete_record, "
    'or aggregate_records call, FIRST call describe_entities with the entities '
    'parameter for the specific entity (for example {"entities":["Product"]}) '
    "to get its real field list.\n"
    "2. NEVER call describe_entities with nameOnly: true for query planning - it "
    "omits the field names you need.\n"
    "3. Use field names EXACTLY as returned by describe_entities. They are "
    "case-sensitive (e.g. Category, not category). Never invent field names, and "
    "never pass * to select (omit select to return all fields).\n"
    "4. To search reviews by meaning, prefer the find_similar_reviews_hybrid tool "
    "with queryText and top.\n"
    "5. Ground every answer in the rows the tools return, and cite the review "
    "text you used.\n"
    "6. If a question cannot be answered from the connected tools, say you do not "
    "know."
)


def load_outputs() -> dict:
    if not OUTPUTS_FILE.exists():
        raise FileNotFoundError(
            f"outputs.json not found at {OUTPUTS_FILE}. Run deploy.ps1 first."
        )
    with open(OUTPUTS_FILE) as f:
        return json.load(f)


def ensure_agent(outputs: dict) -> tuple[str, str]:
    """Create or update the prompt agent version with the DAB MCP tool."""
    project = AIProjectClient(
        endpoint=outputs["foundryEndpoint"],
        credential=DefaultAzureCredential(),
    )
    tool = MCPTool(
        server_label="AzureSQLMCPServer",
        server_url=f"{outputs['dabAppUrl'].rstrip('/')}/mcp",
        require_approval="never",
    )
    agent = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=outputs.get("chatDeployment", "chat"),
            instructions=INSTRUCTIONS,
            tools=[tool],
        ),
    )
    return agent.name, str(agent.version)


async def _invoke(outputs: dict, message: str, version: str | None) -> str:
    """Invoke the agent with the Microsoft Agent Framework SDK (FoundryAgent)."""
    kwargs = {
        "project_endpoint": outputs["foundryEndpoint"],
        "agent_name": AGENT_NAME,
        "credential": DefaultAzureCredential(),
    }
    if version:
        kwargs["agent_version"] = version

    agent = FoundryAgent(**kwargs)
    result = await agent.run(message)
    return result.text


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage the chat-with-your-data agent")
    parser.add_argument("--ensure", action="store_true", help="Create/update the agent")
    parser.add_argument("--invoke", type=str, help="Send a message to the agent")
    parser.add_argument("--agent-version", type=str, help="Pin a specific agent version")
    args = parser.parse_args()

    try:
        outputs = load_outputs()

        if args.ensure:
            name, version = ensure_agent(outputs)
            print(json.dumps({"agentName": name, "agentVersion": version}))
        elif args.invoke:
            version = args.agent_version or outputs.get("agentVersion") or None
            print(asyncio.run(_invoke(outputs, args.invoke, version)))
        else:
            parser.print_help()
    except Exception as exc:  # noqa: BLE001
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
