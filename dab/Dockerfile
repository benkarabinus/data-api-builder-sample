# syntax=docker/dockerfile:1
#
# Step 5 — Data API Builder container image.
#
# We layer our config on top of the official DAB image so we don't have
# to maintain a .NET build. The config itself uses @env('SQL_CONNECTION_STRING')
# so the same image works against any SQL server — the secret-free
# connection string is supplied by the Azure Container App as an env var.

FROM mcr.microsoft.com/azure-databases/data-api-builder:latest

# /App is the working dir in the upstream image; dab-config.json there is
# the default config the entry point loads.
COPY dab-config.json /App/dab-config.json
