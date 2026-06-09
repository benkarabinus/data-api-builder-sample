# syntax=docker/dockerfile:1
#
# Streamlit demo UI for the "chat with your data" stack.
# Calls Data API Builder's REST endpoint only (no SQL, no LLM).

FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8501

# DAB_BASE_URL is injected by the Container App at runtime.
ENV DAB_BASE_URL="http://localhost:5000"

CMD ["streamlit", "run", "app.py", \
     "--server.port=8501", \
     "--server.address=0.0.0.0", \
     "--server.headless=true", \
     "--browser.gatherUsageStats=false"]
