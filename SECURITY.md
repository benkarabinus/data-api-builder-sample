# Security policy

This is a private learning repository for an end-to-end "chat with
your data" tutorial on Azure SQL + DAB + MCP. It still has rules.

## What is safe to commit

- Scripts (`deploy.ps1`, `*.sql`, Bicep) that **read** sensitive
  values at run time but don't hard-code them.
- Config templates with placeholders (e.g. `<SUBSCRIPTION_ID>`,
  `REPLACE_ME_WITH_acaAppUrl`).
- Documentation that *describes* what a value looks like without
  including a real one (e.g. "the FQDN looks like
  `<namePrefix>-dab-<env>.<envHash>.<region>.azurecontainerapps.io`").
- Tutorial sample data (`sql/00-create-schema.sql` + the `sql/01`/`sql/02` seed files, non-PII rows).

## What is NEVER safe to commit

| Class | Examples |
|---|---|
| Subscription / tenant IDs | `4810461e-…`, any `subscriptionId` / `tenantId` GUID |
| Managed-identity IDs | `uamiClientId`, `uamiPrincipalId`, full UAMI `resourceId` |
| Resource FQDNs that are publicly reachable | ACA `acaAppUrl`, ACR `loginServer`, SQL server FQDN |
| Secrets | SQL passwords, OpenAI/Foundry API keys, SAS tokens, bearer tokens, `.env` contents, `.pem`/`.pfx`/`.key` files |
| Generated deploy state | `outputs.json` (repo root) |

Everything in the second table is covered by [.gitignore](.gitignore).
If you find a file that should be ignored but isn't, add it there
**before** committing.

## What's committed vs. what the deploy writes locally

`deploy.ps1` writes a single `outputs.json` at the repo root. That
file is produced locally by your Azure CLI session, contains real
GUIDs and FQDNs, and is **gitignored**. The committed
[`outputs.template.json`](outputs.template.json) shows the schema.

The tracked workspace config [.vscode/mcp.json](.vscode/mcp.json)
ships with a placeholder URL for the hosted DAB MCP server:

```jsonc
"sql-mcp-hosted": {
  "type": "http",
  "url": "https://REPLACE_ME_WITH_acaAppUrl.azurecontainerapps.io/mcp"
}
```

After `deploy.ps1` finishes, replace that placeholder with the real
`dabAppUrl` from `outputs.json` (add `/mcp`). **Do not commit that
change.**

If you want to be extra-safe against an accidental commit, run:

```powershell
git update-index --skip-worktree .vscode/mcp.json
```

That tells git to ignore your local edits to the file until you
explicitly re-enable tracking with
`git update-index --no-skip-worktree .vscode/mcp.json`.

## If something sensitive does get committed

1. Don't push. Amend the commit or `git reset`.
2. If it has already been pushed, rotate the value (e.g. delete +
   redeploy the ACA app to get a new FQDN, regenerate any API key)
   then rewrite history with
   [git filter-repo](https://github.com/newren/git-filter-repo) and
   force-push.
3. Tell every collaborator to re-clone (this repo currently has one).

## Reporting

This is a personal learning repo. If you find leaked credentials in
it, open an issue or DM the owner; the values will be rotated and
purged.
