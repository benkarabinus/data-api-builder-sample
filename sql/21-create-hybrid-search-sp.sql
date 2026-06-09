/*
=================================================================================
 Step 3 / SQL 02 — dbo.find_similar_reviews_hybrid stored procedure

 What this does:
   Takes a free-text query string. Returns the top-N matching reviews
   ranked by a hybrid (vector + keyword) score using Reciprocal Rank
   Fusion (RRF).

 How it works:
     1. Embed the query via AI_GENERATE_EMBEDDINGS(... USE MODEL EmbeddingModel).
   2. Compute the top-50 reviews by cosine vector distance.
   3. Compute the top-50 reviews by full-text rank (FREETEXTTABLE).
   4. FULL OUTER JOIN on ReviewID and combine with:
          rrf_score = 1 / (60 + vector_rank) + 1 / (60 + keyword_rank)
      The constant 60 is the standard RRF damping factor; rows missing
      from one ranking are treated as rank 1000 so they still get *some*
      mass but are dominated by rows that appear in both.
   5. Return the top-N with both component ranks/scores so callers can
      see WHY a row ranked highly.

 Why RRF over weighted-sum:
   Cosine similarity (~0.0–1.0) and FREETEXT rank (typically 0–1000+)
   are on wildly different scales. Trying to weight them directly forces
   you to pick magic numbers per dataset. RRF only cares about RANK
   order so it's robust without tuning.

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 (recommended).
   Option B — from your SQL Editor: connect to ProductsDB and run.
   (No tokens to edit.)
=================================================================================
*/

CREATE OR ALTER PROCEDURE dbo.find_similar_reviews_hybrid
    @queryText NVARCHAR(MAX),
    @top       INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @queryEmbedding VECTOR(1536);

    -- FREETEXTTABLE requires a non-MAX nvarchar/varchar argument; cap the input.
    DECLARE @keywordQuery NVARCHAR(4000) = LEFT(@queryText, 4000);

    SET @queryEmbedding = AI_GENERATE_EMBEDDINGS(@queryText USE MODEL EmbeddingModel);

    IF @queryEmbedding IS NULL
    BEGIN
        RAISERROR('AI_GENERATE_EMBEDDINGS returned NULL for the query text. Check EmbeddingModel definition and permissions.', 16, 1);
        RETURN;
    END

    ;WITH vector_results AS (
        SELECT TOP (50)
            pr.ReviewID,
            ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', pr.ReviewEmbedding, @queryEmbedding)) AS vector_rank,
            1.0 - VECTOR_DISTANCE('cosine', pr.ReviewEmbedding, @queryEmbedding) AS vector_score
        FROM dbo.ProductReviews pr
        WHERE pr.ReviewEmbedding IS NOT NULL
        ORDER BY VECTOR_DISTANCE('cosine', pr.ReviewEmbedding, @queryEmbedding)
    ),
    keyword_results AS (
        SELECT
            ft.[KEY] AS ReviewID,
            ROW_NUMBER() OVER (ORDER BY ft.[RANK] DESC) AS keyword_rank,
            ft.[RANK] AS keyword_score
        FROM FREETEXTTABLE(dbo.ProductReviews, ReviewText, @keywordQuery, 50) ft
    ),
    fused AS (
        SELECT
            COALESCE(v.ReviewID, k.ReviewID) AS ReviewID,
            v.vector_rank,
            v.vector_score,
            k.keyword_rank,
            k.keyword_score,
            (1.0 / (60 + COALESCE(v.vector_rank, 1000))) +
            (1.0 / (60 + COALESCE(k.keyword_rank, 1000))) AS rrf_score
        FROM vector_results v
        FULL OUTER JOIN keyword_results k ON v.ReviewID = k.ReviewID
    )
    SELECT TOP (@top)
        f.ReviewID,
        p.ProductID,
        p.Name AS ProductName,
        p.Category,
        pr.ReviewerName,
        pr.ReviewText,
        pr.Rating,
        f.vector_rank,
        f.keyword_rank,
        f.vector_score,
        f.keyword_score,
        f.rrf_score
    FROM fused f
    INNER JOIN dbo.ProductReviews pr ON pr.ReviewID = f.ReviewID
    INNER JOIN dbo.Products p ON p.ProductID = pr.ProductID
    ORDER BY f.rrf_score DESC;
END
GO

PRINT 'Created/updated stored procedure dbo.find_similar_reviews_hybrid';
GO
