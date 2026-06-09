/*
=================================================================================
 Step 2 / SQL 04 — Smoke-test AI_GENERATE_EMBEDDINGS on a single string

 If this succeeds you'll see one row whose json_string_length is ~30000
 (1536 floats serialized as JSON).

 If it fails, SQL raises an error from the model invocation path. Common
 causes:
   401 -> UAMI is missing 'Cognitive Services OpenAI User' on the
          Foundry account, or the role assignment hasn't propagated.
   404 -> Deployment name in EmbeddingModel doesn't match an actual
       deployment. Re-run script 03.
   400 -> Bad payload (input too long, etc.).

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 (recommended).
   Option B — from your SQL Editor: connect to ProductsDB and run.
   (No tokens to edit.)
=================================================================================
*/

SET NOCOUNT ON;
GO

DECLARE @v VECTOR(1536) = AI_GENERATE_EMBEDDINGS(
    N'A comfortable office chair for long work sessions.' USE MODEL EmbeddingModel
);

IF @v IS NULL
BEGIN
    RAISERROR('AI_GENERATE_EMBEDDINGS returned NULL. Check EmbeddingModel and credentials.', 16, 1);
    RETURN;
END

SELECT
    LEN(CAST(@v AS NVARCHAR(MAX))) AS json_string_length,
    LEFT(CAST(@v AS NVARCHAR(MAX)), 80) AS embedding_preview;
GO
