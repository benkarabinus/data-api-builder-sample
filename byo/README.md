# Bring your own data

Everything below assumes you've already run [`deploy.ps1`](../deploy.ps1)
once, so these already exist in `ProductsDB`:

- `EXTERNAL MODEL EmbeddingModel` (the embedding endpoint, called as the UAMI)
- the UAMI database user with `db_datareader`, `db_datawriter`, and
  `EXECUTE ON SCHEMA::dbo`
- the full-text catalog `ftCatalog`

You can point the whole stack at **your own table** without redeploying any
Azure infrastructure — it's just SQL plus one DAB config edit. The sample
`Products`/`ProductReviews` data can stay; your table lives alongside it.

> Run the SQL below with the same Entra login you deployed with:
> `sqlcmd -S <sqlServerFqdn> -d ProductsDB -G -i <file>.sql`
> (your `sqlServerFqdn` is in [`outputs.json`](../outputs.json)).

![BYO table flow](../docs/architecture/05-byo-table-flow.svg)

---

## 1. Add a vector column to your table

Assume your table is `dbo.MyDocs` with a text column `Content` and primary
key `PK_MyDocs`:

```sql
ALTER TABLE dbo.MyDocs ADD ContentEmbedding VECTOR(1536) NULL;
```

---

## 2. Backfill embeddings

`AI_GENERATE_EMBEDDINGS` uses the same `EmbeddingModel` registered at deploy
time — no new credentials needed.

```sql
SET NOCOUNT ON;

DECLARE @id INT, @text NVARCHAR(MAX), @v VECTOR(1536);

DECLARE c CURSOR FAST_FORWARD FOR
    SELECT MyDocId, Content FROM dbo.MyDocs WHERE ContentEmbedding IS NULL;

OPEN c;
FETCH NEXT FROM c INTO @id, @text;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @v = AI_GENERATE_EMBEDDINGS(@text USE MODEL EmbeddingModel);
    UPDATE dbo.MyDocs SET ContentEmbedding = @v WHERE MyDocId = @id;
    FETCH NEXT FROM c INTO @id, @text;
END;
CLOSE c;
DEALLOCATE c;
```

*(Optional)* To auto-embed new/changed rows, adapt
[`sql/15-create-auto-embed-trigger.sql`](../sql/15-create-auto-embed-trigger.sql)
to target `dbo.MyDocs` / `Content` / `ContentEmbedding`.

---

## 3. Add a full-text index on your text column

```sql
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'ftCatalog')
    CREATE FULLTEXT CATALOG ftCatalog;

IF NOT EXISTS (
    SELECT 1 FROM sys.fulltext_indexes fi
    JOIN sys.tables t ON fi.object_id = t.object_id
    WHERE t.name = 'MyDocs'
)
    CREATE FULLTEXT INDEX ON dbo.MyDocs (Content LANGUAGE 1033)
        KEY INDEX PK_MyDocs ON ftCatalog;
```

---

## 4. Create a hybrid search SP for your table

This mirrors [`sql/21-create-hybrid-search-sp.sql`](../sql/21-create-hybrid-search-sp.sql),
re-pointed at your table/columns. It fuses top-50 vector and top-50 keyword
matches with Reciprocal Rank Fusion ($k = 60$).

```sql
CREATE OR ALTER PROCEDURE dbo.find_similar_mydocs_hybrid
    @queryText NVARCHAR(MAX),
    @top       INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @queryEmbedding VECTOR(1536);
    DECLARE @keywordQuery NVARCHAR(4000) = LEFT(@queryText, 4000);
    SET @queryEmbedding = AI_GENERATE_EMBEDDINGS(@queryText USE MODEL EmbeddingModel);

    ;WITH vector_results AS (
        SELECT TOP (50)
            d.MyDocId,
            ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', d.ContentEmbedding, @queryEmbedding)) AS vector_rank
        FROM dbo.MyDocs d
        WHERE d.ContentEmbedding IS NOT NULL
        ORDER BY VECTOR_DISTANCE('cosine', d.ContentEmbedding, @queryEmbedding)
    ),
    keyword_results AS (
        SELECT ft.[KEY] AS MyDocId,
               ROW_NUMBER() OVER (ORDER BY ft.[RANK] DESC) AS keyword_rank
        FROM FREETEXTTABLE(dbo.MyDocs, Content, @keywordQuery, 50) ft
    ),
    fused AS (
        SELECT COALESCE(v.MyDocId, k.MyDocId) AS MyDocId,
               (1.0 / (60 + COALESCE(v.vector_rank, 1000))) +
               (1.0 / (60 + COALESCE(k.keyword_rank, 1000))) AS rrf_score
        FROM vector_results v
        FULL OUTER JOIN keyword_results k ON v.MyDocId = k.MyDocId
    )
    SELECT TOP (@top) f.MyDocId, d.Content, f.rrf_score
    FROM fused f
    INNER JOIN dbo.MyDocs d ON d.MyDocId = f.MyDocId
    ORDER BY f.rrf_score DESC;
END
```

Test it:

```sql
EXEC dbo.find_similar_mydocs_hybrid @queryText = N'your query', @top = 5;
```

---

## 5. Expose your table + SP through DAB

Edit [`dab/dab-config.json`](../dab/dab-config.json) and add two entities
under `entities` (leave `connection-string` as `@env('SQL_CONNECTION_STRING')`):

```jsonc
"MyDoc": {
  "source": { "object": "dbo.MyDocs", "type": "table" },
  "permissions": [ { "role": "anonymous", "actions": ["read"] } ],
  // Declare fields so the agent learns real column names + casing via
  // describe_entities. Without this, agents guess and calls fail. List
  // valid values for any category/enum column.
  "fields": [
    { "name": "MyDocId", "description": "Unique identifier (integer primary key).", "primary-key": true },
    { "name": "Content", "description": "Free-text body of the document." }
  ],
  "description": "Your documents table."
},
"FindSimilarMyDocsHybrid": {
  "source": {
    "object": "dbo.find_similar_mydocs_hybrid",
    "type": "stored-procedure",
    "parameters": [
      { "name": "queryText", "description": "Natural-language search text.", "required": true },
      { "name": "top", "description": "Maximum number of results (integer).", "required": true }
    ]
  },
  "rest":    { "methods": ["POST"] },
  "graphql": { "operation": "mutation" },
  "mcp":     { "custom-tool": true },
  "permissions": [ { "role": "anonymous", "actions": ["execute"] } ],
  "description": "Hybrid search over MyDocs."
}
```

> **Why `fields` matters.** DAB's MCP `describe_entities` only reports column
> names if you declare them here. Omit them and agents fall back to guessing
> (often inventing column names), and reads fail. The `custom-tool` flag
> registers the stored procedure as a named MCP tool agents can call
> directly. See [agent/README.md](../agent/README.md#working-with-the-dab-tools).

Rebuild and roll the hosted DAB to a new revision. Re-running the
orchestrator is idempotent and picks up the edited config; skip the SQL
and web stages to make it fast:

```powershell
.\deploy.ps1 -ResourceGroupName <rg> -NamePrefix <prefix> -SkipSqlScripts -DeployWebApp:$false
```

Verify:

```powershell
$dab = (Get-Content .\outputs.json | ConvertFrom-Json).dabAppUrl
curl "$dab/api/MyDoc"
curl -X POST "$dab/api/FindSimilarMyDocsHybrid" -H "Content-Type: application/json" -d '{ "queryText": "your query", "top": 5 }'
```

The MCP `tools/list` at `$dab/mcp` now includes `MyDoc` and the SP-backed
tool, so Copilot Chat and any Foundry agent see them automatically.

---

## 6. Permissions for a non-`dbo` schema

The UAMI was granted rights on `dbo` at deploy time. If your table or SP
lives in another schema, grant the matching rights (UAMI name is in
[`outputs.json`](../outputs.json)):

```sql
GRANT EXECUTE ON SCHEMA::yourschema TO [<uamiName>];
-- or for one object:
GRANT EXECUTE ON OBJECT::yourschema.find_similar_mydocs_hybrid TO [<uamiName>];
```

Without it, DAB's call returns *"The EXECUTE permission was denied on the
object …"* in the container logs:

```powershell
az containerapp logs show -g <rg> -n <dabAppName> --follow
```
