/*
=================================================================================
 Step 2 / SQL 06 — (OPTIONAL) Auto-embed trigger on dbo.ProductReviews

 What it does:
   AFTER INSERT/UPDATE on dbo.ProductReviews, embed any rows whose
   ReviewText was just inserted or changed and write the result back
   into ReviewEmbedding.

 Why optional:
   * Triggers that call HTTP endpoints make INSERTs slower and harder
     to reason about (network errors propagate as INSERT errors).
   * If you only ever load reviews via a scheduled batch, just re-run
     script 05 instead of installing this trigger.

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 -InstallAutoEmbedTrigger (recommended).
   Option B — from your SQL Editor: connect to ProductsDB and run.
   (No tokens to edit.)
=================================================================================
*/

SET NOCOUNT ON;
GO

-- Any caller (DAB, ad-hoc T-SQL, an app) gets auto-embedding for free.
DECLARE @body NVARCHAR(MAX) = N'
CREATE OR ALTER TRIGGER dbo.trg_ProductReviews_AutoEmbed
ON dbo.ProductReviews
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(ReviewText) = 0
       AND NOT EXISTS (SELECT 1 FROM inserted i LEFT JOIN deleted d ON d.ReviewID = i.ReviewID WHERE d.ReviewID IS NULL)
        RETURN;

    DECLARE @id   INT;
    DECLARE @text NVARCHAR(MAX);
    DECLARE @v    VECTOR(1536);

    DECLARE c CURSOR FAST_FORWARD FOR
        SELECT i.ReviewID, i.ReviewText FROM inserted i;

    OPEN c;
    FETCH NEXT FROM c INTO @id, @text;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @v = AI_GENERATE_EMBEDDINGS(@text USE MODEL EmbeddingModel);

        IF @v IS NULL
        BEGIN
            RAISERROR(''AI_GENERATE_EMBEDDINGS returned NULL in trigger for ReviewID=%d.'', 16, 1, @id);
            RETURN;
        END

        UPDATE dbo.ProductReviews
        SET ReviewEmbedding = @v
        WHERE ReviewID = @id;

        FETCH NEXT FROM c INTO @id, @text;
    END;
    CLOSE c;
    DEALLOCATE c;
END;
';

EXEC sp_executesql @body;
PRINT 'Created/updated trigger dbo.trg_ProductReviews_AutoEmbed';
GO
