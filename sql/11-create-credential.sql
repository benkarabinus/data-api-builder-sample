/*
=================================================================================
 Step 2 / SQL 02 — Database master key + DATABASE SCOPED CREDENTIAL (MI)

 Why:
     Script 03 registers EXTERNAL MODEL EmbeddingModel. That model needs a
     credential that tells SQL how to acquire a bearer token for the OpenAI
     endpoint. Because the target subscription forbids local auth, the only
     working option is the SQL server's User-Assigned Managed Identity (UAMI)
     we attached in step 1.

 How matching works:
     EXTERNAL MODEL references this credential by name, so we name it exactly
     the OpenAI account endpoint, e.g.
             https://sqlrag-ai-dev-xxx.openai.azure.com

 The SECRET is NOT a key. It's a JSON blob naming the AAD audience to
 request a token for: cognitiveservices.azure.com.

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 (recommended).
   Option B — from your SQL Editor: connect to ProductsDB, edit the one
              DECLARE line marked EDIT below, and run.

   Where to find the value:
       OpenAI endpoint -> steps/01-foundation/outputs.json field "openAiEndpoint"
       (strip any trailing slash; e.g. https://sqlrag-ai-dev-xxx.openai.azure.com)
=================================================================================
*/

SET NOCOUNT ON;
GO

-- ============ EDIT THIS IF RUNNING FROM YOUR SQL EDITOR ============
DECLARE @openAiEndpoint NVARCHAR(4000) = N'<<OPENAI_ENDPOINT>>';
-- ===================================================================

IF @openAiEndpoint LIKE N'%<<OPENAI[_]ENDPOINT>>%'
BEGIN
    RAISERROR('Set @openAiEndpoint above (or run via deploy.ps1).', 16, 1);
    RETURN;
END

-- Strip any trailing slash so the credential name matches the request URL prefix.
IF RIGHT(@openAiEndpoint, 1) = N'/'
    SET @openAiEndpoint = LEFT(@openAiEndpoint, LEN(@openAiEndpoint) - 1);

DECLARE @sql NVARCHAR(MAX);

-- 1. A database master key is required before any database scoped credential
--    can be created. Password is a random GUID-derived string we never
--    need to use again (Entra-only auth means we don't decrypt by password).
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    DECLARE @pwd NVARCHAR(128) = CONVERT(NVARCHAR(36), NEWID()) + N'!Aa1';
    SET @sql = N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''' + REPLACE(@pwd, N'''', N'''''') + N'''';
    EXEC sp_executesql @sql;
    PRINT 'Created database master key';
END
ELSE
BEGIN
    PRINT 'Database master key already exists';
END

DECLARE @credQ NVARCHAR(4000) = QUOTENAME(@openAiEndpoint);

-- 2. Drop any existing credential with this name so re-runs are idempotent.
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = @openAiEndpoint)
BEGIN
    SET @sql = N'DROP DATABASE SCOPED CREDENTIAL ' + @credQ;
    EXEC sp_executesql @sql;
END

-- 3. Create the credential. IDENTITY = 'Managed Identity' tells SQL to acquire
--    a token using the server's primary user-assigned managed identity. The
--    SECRET specifies the resource (audience) of the token.
SET @sql = N'CREATE DATABASE SCOPED CREDENTIAL ' + @credQ +
    N' WITH IDENTITY = ''Managed Identity'', ' +
    N'SECRET = ''{"resourceid":"https://cognitiveservices.azure.com"}''';
EXEC sp_executesql @sql;

PRINT 'Created database scoped credential ' + @credQ + ' using Managed Identity';
GO

-- 4. Grant REFERENCES on the new credential to every user that needs to call
--    AI_GENERATE_EMBEDDINGS via EXTERNAL MODEL against this endpoint. Without
--    this, hosted callers running as the UAMI (DAB on ACA in step 5) hit:
--      "Cannot find the credential '<endpoint>', because it does not exist
--       or you do not have permission."
--    db_owner has implicit access, which is why local admin testing works.
DECLARE @openAiEndpoint2 NVARCHAR(4000) = N'<<OPENAI_ENDPOINT>>';
DECLARE @uamiName2       SYSNAME       = N'<<UAMI_NAME>>';

IF @openAiEndpoint2 LIKE N'%<<OPENAI[_]ENDPOINT>>%' OR @uamiName2 LIKE N'%<<UAMI[_]NAME>>%'
BEGIN
    PRINT 'Skipping REFERENCES grant — placeholders not substituted (running standalone?). Re-run via deploy.ps1 to grant.';
    RETURN;
END

IF RIGHT(@openAiEndpoint2, 1) = N'/'
    SET @openAiEndpoint2 = LEFT(@openAiEndpoint2, LEN(@openAiEndpoint2) - 1);

DECLARE @grantSql NVARCHAR(MAX) =
    N'GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::' + QUOTENAME(@openAiEndpoint2) +
    N' TO ' + QUOTENAME(@uamiName2) + N';';
EXEC sp_executesql @grantSql;

PRINT 'Granted REFERENCES on credential to ' + QUOTENAME(@uamiName2);
GO
