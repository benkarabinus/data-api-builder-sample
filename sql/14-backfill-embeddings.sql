/*
=================================================================================
 Step 2 / SQL 05 — Backfill ReviewEmbedding for every review where it's NULL

 Strategy:
   For each row in dbo.ProductReviews where ReviewEmbedding IS NULL:
         * Call AI_GENERATE_EMBEDDINGS(... USE MODEL EmbeddingModel)
     * UPDATE the row with the resulting VECTOR(1536)

 Notes:
   * Idempotent: rows that already have an embedding are skipped on re-runs.
     To force a full re-embed, run before this script:
        UPDATE dbo.ProductReviews SET ReviewEmbedding = NULL;
   * Token cost: text-embedding-3-small is ~$0.02 per 1M tokens. The 18
     seeded reviews cost fractions of a cent.

 RUNNING THIS SCRIPT
     Option A — via deploy.ps1 (recommended).
     Option B — from your SQL Editor: connect to ProductsDB and run.
     (No tokens to edit.)
=================================================================================
*/

SET NOCOUNT ON;
GO

DECLARE @id    INT;
DECLARE @text  NVARCHAR(MAX);
DECLARE @v     VECTOR(1536);
DECLARE @done  INT = 0;
DECLARE @total INT;

SELECT @total = COUNT(*) FROM dbo.ProductReviews WHERE ReviewEmbedding IS NULL;
PRINT CONCAT('Rows to embed: ', @total);

DECLARE c CURSOR FAST_FORWARD FOR
    SELECT ReviewID, ReviewText
    FROM dbo.ProductReviews
    WHERE ReviewEmbedding IS NULL
    ORDER BY ReviewID;

OPEN c;
FETCH NEXT FROM c INTO @id, @text;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @v = AI_GENERATE_EMBEDDINGS(@text USE MODEL EmbeddingModel);

    IF @v IS NULL
    BEGIN
        RAISERROR('AI_GENERATE_EMBEDDINGS returned NULL during backfill for ReviewID=%d.', 16, 1, @id);
        RETURN;
    END

    UPDATE dbo.ProductReviews
    SET ReviewEmbedding = @v
    WHERE ReviewID = @id;

    SET @done += 1;
    PRINT CONCAT('  embedded ReviewID=', @id, '  (', @done, '/', @total, ')');

    FETCH NEXT FROM c INTO @id, @text;
END;

CLOSE c;
DEALLOCATE c;

DECLARE @remaining INT;
SELECT @remaining = COUNT(*) FROM dbo.ProductReviews WHERE ReviewEmbedding IS NULL;
PRINT CONCAT('Done. Rows still NULL: ', @remaining);
GO
