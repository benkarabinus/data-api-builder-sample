/*
=================================================================================
 Step 2 / SQL 03 — Register EXTERNAL MODEL EmbeddingModel

 Why:
   This is the GA Azure SQL path for embeddings. Instead of passing endpoint
   and deployment on every call, we register a reusable named model once and
   call AI_GENERATE_EMBEDDINGS(... USE MODEL EmbeddingModel) everywhere else.

 Prereqs (created in scripts 01/02):
   - UAMI database user exists.
   - Database scoped credential exists with name = OpenAI endpoint and
     IDENTITY = 'Managed Identity'.

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 (recommended).
   Option B — from your SQL Editor: connect to ProductsDB, edit the three
              DECLARE lines below, and run.
=================================================================================
*/

SET NOCOUNT ON;
GO

-- ============ EDIT THESE IF RUNNING FROM YOUR SQL EDITOR ============
DECLARE @openAiEndpoint NVARCHAR(4000) = N'<<OPENAI_ENDPOINT>>';
DECLARE @deployment     NVARCHAR(200)  = N'<<EMBEDDING_DEPLOYMENT>>';
DECLARE @uamiName       SYSNAME        = N'<<UAMI_NAME>>';
-- ====================================================================

IF @openAiEndpoint LIKE N'%<<OPENAI[_]ENDPOINT>>%'
   OR @deployment LIKE N'%<<EMBEDDING[_]DEPLOYMENT>>%'
   OR @uamiName LIKE N'%<<UAMI[_]NAME>>%'
BEGIN
    RAISERROR('Set @openAiEndpoint, @deployment, and @uamiName above (or run via deploy.ps1).', 16, 1);
    RETURN;
END

IF RIGHT(@openAiEndpoint, 1) = N'/'
    SET @openAiEndpoint = LEFT(@openAiEndpoint, LEN(@openAiEndpoint) - 1);

IF NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = @openAiEndpoint)
BEGIN
    RAISERROR('Database scoped credential [%s] was not found. Run script 02 first.', 16, 1, @openAiEndpoint);
    RETURN;
END

DECLARE @location NVARCHAR(4000) =
    @openAiEndpoint + N'/openai/deployments/' + @deployment + N'/embeddings?api-version=2024-02-01';

IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'EmbeddingModel')
BEGIN
    DROP EXTERNAL MODEL EmbeddingModel;
    PRINT 'Dropped existing EXTERNAL MODEL EmbeddingModel.';
END

DECLARE @sql NVARCHAR(MAX) = N'
CREATE EXTERNAL MODEL EmbeddingModel
WITH (
    LOCATION   = ''' + @location + N''',
    API_FORMAT = ''Azure OpenAI'',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = ''' + @deployment + N''',
    CREDENTIAL = ' + QUOTENAME(@openAiEndpoint) + N'
);';

EXEC sp_executesql @sql;
PRINT 'Created EXTERNAL MODEL EmbeddingModel.';

SET @sql = N'GRANT EXECUTE ON EXTERNAL MODEL :: EmbeddingModel TO ' + QUOTENAME(@uamiName) + N';';
EXEC sp_executesql @sql;
PRINT 'Granted EXECUTE on EXTERNAL MODEL::EmbeddingModel to ' + QUOTENAME(@uamiName);
GO
