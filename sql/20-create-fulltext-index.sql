/*
=================================================================================
 Step 3 / SQL 01 — Full-text catalog + full-text index on dbo.ProductReviews

 Why:
   Step 2 made our reviews searchable by VECTOR similarity (semantic). That's
   great for "comfortable chair for back pain" matching a review that says
   "ergonomic support and lumbar cushion." But vector search is bad at
   exact-token recall — searching for "SKU-42" by semantics is a coin flip.

   Full-text search is the complement: it indexes words/lemmas and ranks
   results by token overlap. Step 3's hybrid SP fuses both rankings, so
   you get the best of each.

 What this script creates:
   * A full-text catalog called 'ftCatalog'.
   * A full-text index on dbo.ProductReviews(ReviewText) keyed on the
     primary key PK_ProductReviews.

 Idempotent: re-running this is a no-op.

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 (recommended).
   Option B — from your SQL Editor: connect to ProductsDB and run.
   (No tokens to edit.)
=================================================================================
*/

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'ftCatalog')
BEGIN
    CREATE FULLTEXT CATALOG ftCatalog;
    PRINT 'Created fulltext catalog ftCatalog';
END
ELSE
BEGIN
    PRINT 'Fulltext catalog ftCatalog already exists';
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.fulltext_indexes fi
    JOIN sys.tables t ON fi.object_id = t.object_id
    WHERE t.name = 'ProductReviews'
)
BEGIN
    CREATE FULLTEXT INDEX ON dbo.ProductReviews (ReviewText LANGUAGE 1033)
        KEY INDEX PK_ProductReviews
        ON ftCatalog;
    PRINT 'Created fulltext index on dbo.ProductReviews(ReviewText)';
END
ELSE
BEGIN
    PRINT 'Fulltext index on dbo.ProductReviews already exists';
END
GO
