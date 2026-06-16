"""Streamlit demo UI for the "chat with your data" stack.

Three tabs, three independent concerns:

* Search          - hybrid (vector + full-text) review search via Data API
                    Builder's REST endpoint.
* Browse products - lists products via the same DAB REST endpoint.
* Chat with Agent - talks to a Foundry prompt agent (Microsoft Agent Framework
                    SDK). Only shown when the agent env vars are present.

The app never talks to SQL or an LLM directly. Hybrid search runs inside Azure
SQL (dbo.find_similar_reviews_hybrid, exposed by DAB); the agent's model,
instructions, and DAB MCP tool live in the Foundry agent definition.

Configuration (all via environment, supplied by the container):
    DAB_BASE_URL              base URL of the hosted DAB app
    FOUNDRY_PROJECT_ENDPOINT  Foundry project endpoint   (agent tab)
    FOUNDRY_AGENT_NAME        Foundry prompt agent name  (agent tab)
    FOUNDRY_AGENT_VERSION     pinned agent version        (optional)
"""

from __future__ import annotations

import asyncio
import os

import requests
import streamlit as st
from agent_framework.foundry import FoundryAgent
from azure.identity import DefaultAzureCredential

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

DAB_BASE_URL = os.environ.get("DAB_BASE_URL", "http://localhost:5000").rstrip("/")
REQUEST_TIMEOUT = 30

SEARCH_PATH = "/api/FindSimilarReviewsHybrid"
PRODUCTS_PATH = "/api/Product"

FOUNDRY_PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "")
FOUNDRY_AGENT_NAME = os.environ.get("FOUNDRY_AGENT_NAME", "")
FOUNDRY_AGENT_VERSION = os.environ.get("FOUNDRY_AGENT_VERSION", "")
AGENT_ENABLED = bool(FOUNDRY_PROJECT_ENDPOINT and FOUNDRY_AGENT_NAME)


# --------------------------------------------------------------------------- #
# Data API Builder client
# --------------------------------------------------------------------------- #


def search_reviews(query_text: str, top: int) -> list[dict]:
    """Call the hybrid-search stored procedure through DAB."""
    resp = requests.post(
        f"{DAB_BASE_URL}{SEARCH_PATH}",
        json={"queryText": query_text, "top": top},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json().get("value", [])


def list_products() -> list[dict]:
    """List products through DAB's REST endpoint."""
    resp = requests.get(f"{DAB_BASE_URL}{PRODUCTS_PATH}", timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    return resp.json().get("value", [])


# --------------------------------------------------------------------------- #
# Foundry agent client (Microsoft Agent Framework SDK)
# --------------------------------------------------------------------------- #


async def _run_agent(user_message: str) -> str:
    """Send one turn to the Foundry prompt agent and return its text.

    Auth uses DefaultAzureCredential, which resolves to the container's
    User-Assigned Managed Identity in Azure Container Apps.
    """
    kwargs = {
        "project_endpoint": FOUNDRY_PROJECT_ENDPOINT,
        "agent_name": FOUNDRY_AGENT_NAME,
        "credential": DefaultAzureCredential(),
    }
    if FOUNDRY_AGENT_VERSION:
        kwargs["agent_version"] = FOUNDRY_AGENT_VERSION

    agent = FoundryAgent(**kwargs)
    try:
        result = await agent.run(user_message)
        return result.text
    finally:
        close = getattr(agent, "close", None)
        if close is not None:
            maybe = close()
            if asyncio.iscoroutine(maybe):
                await maybe


def ask_agent(user_message: str) -> str:
    """Synchronous wrapper around the async agent call for Streamlit."""
    try:
        return asyncio.run(_run_agent(user_message))
    except Exception as exc:  # noqa: BLE001 - surface any failure in the UI
        return f"Error calling agent: {exc}"


# --------------------------------------------------------------------------- #
# UI tabs
# --------------------------------------------------------------------------- #


def render_search_tab() -> None:
    col_query, col_count = st.columns([4, 1])
    with col_query:
        query = st.text_input(
            "What are you looking for?",
            value="comfortable chair for long hours",
            placeholder="e.g. quiet keyboard, sturdy desk, good webcam",
        )
    with col_count:
        top_n = st.slider("Results", min_value=1, max_value=20, value=5)

    if not (st.button("Search", type="primary") and query.strip()):
        return

    try:
        with st.spinner("Searching…"):
            results = search_reviews(query.strip(), top_n)
    except requests.RequestException as exc:
        st.error(f"Search failed: {exc}")
        return

    if not results:
        st.info("No matches found.")
    else:
        st.success(f"{len(results)} result(s)")
        st.dataframe(results, use_container_width=True, hide_index=True)


def render_products_tab() -> None:
    try:
        products = list_products()
    except requests.RequestException as exc:
        st.error(f"Could not load products: {exc}")
        return
    st.dataframe(products, use_container_width=True, hide_index=True)


def render_agent_tab() -> None:
    st.markdown(
        "Chat with the Foundry agent about products and reviews. "
        "The agent calls the Data API Builder tools to answer your questions."
    )

    history = st.session_state.setdefault("chat_history", [])
    for message in history:
        with st.chat_message(message["role"]):
            st.markdown(message["content"])

    user_input = st.chat_input("Ask about products or reviews...")
    if not user_input:
        return

    history.append({"role": "user", "content": user_input})
    with st.chat_message("user"):
        st.markdown(user_input)

    with st.chat_message("assistant"):
        with st.spinner("Agent is thinking..."):
            answer = ask_agent(user_input)
        st.markdown(answer)
    history.append({"role": "assistant", "content": answer})


# --------------------------------------------------------------------------- #
# Page
# --------------------------------------------------------------------------- #


def main() -> None:
    st.set_page_config(page_title="Chat with your data", page_icon="🔎", layout="wide")
    st.title("🔎 Hybrid search over your reviews")
    st.caption(
        "Vector + full-text search fused with Reciprocal Rank Fusion, executed "
        "inside Azure SQL and served through Data API Builder."
    )
    st.caption(f"DAB endpoint: `{DAB_BASE_URL}`")

    tab_names = ["Search", "Browse products"]
    if AGENT_ENABLED:
        tab_names.append("Chat with Agent")

    renderers = {
        "Search": render_search_tab,
        "Browse products": render_products_tab,
        "Chat with Agent": render_agent_tab,
    }
    for tab, name in zip(st.tabs(tab_names), tab_names):
        with tab:
            renderers[name]()


if __name__ == "__main__":
    main()
