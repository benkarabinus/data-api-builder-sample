"""
Streamlit demo UI for the "chat with your data" stack.

This app is intentionally thin: it calls Data API Builder's REST endpoint
only. It never talks to SQL directly and never calls an LLM. Hybrid search
(vector + full-text) happens inside Azure SQL via the
dbo.find_similar_reviews_hybrid stored procedure, which DAB exposes as
POST /api/FindSimilarReviewsHybrid.

The DAB base URL is supplied by the container environment as DAB_BASE_URL.
"""

import os

import requests
import streamlit as st

DAB_BASE_URL = os.environ.get("DAB_BASE_URL", "http://localhost:5000").rstrip("/")
SEARCH_PATH = "/api/FindSimilarReviewsHybrid"
PRODUCTS_PATH = "/api/Product"
REQUEST_TIMEOUT = 30

st.set_page_config(page_title="Chat with your data", page_icon="🔎", layout="wide")
st.title("🔎 Hybrid search over your reviews")
st.caption(
    "Vector + full-text search fused with Reciprocal Rank Fusion, executed "
    "inside Azure SQL and served through Data API Builder."
)
st.caption(f"DAB endpoint: `{DAB_BASE_URL}`")


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
    resp = requests.get(f"{DAB_BASE_URL}{PRODUCTS_PATH}", timeout=REQUEST_TIMEOUT)
    resp.raise_for_status()
    return resp.json().get("value", [])


tab_search, tab_products = st.tabs(["Search", "Browse products"])

with tab_search:
    col_q, col_n = st.columns([4, 1])
    with col_q:
        query = st.text_input(
            "What are you looking for?",
            value="comfortable chair for long hours",
            placeholder="e.g. quiet keyboard, sturdy desk, good webcam",
        )
    with col_n:
        top_n = st.slider("Results", min_value=1, max_value=20, value=5)

    if st.button("Search", type="primary") and query.strip():
        try:
            with st.spinner("Searching…"):
                results = search_reviews(query.strip(), top_n)
        except requests.RequestException as exc:
            st.error(f"Search failed: {exc}")
        else:
            if not results:
                st.info("No matches found.")
            else:
                st.success(f"{len(results)} result(s)")
                st.dataframe(results, use_container_width=True, hide_index=True)

with tab_products:
    try:
        products = list_products()
    except requests.RequestException as exc:
        st.error(f"Could not load products: {exc}")
    else:
        st.dataframe(products, use_container_width=True, hide_index=True)
