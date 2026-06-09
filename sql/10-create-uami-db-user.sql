/*
=================================================================================
 Step 2 / SQL 01 — Create a contained database user for the UAMI

 Why now:
   Later in the tutorial (step 5), Data API Builder running in Azure Container
   Apps will connect to this database AS the same User-Assigned Managed Identity
   we created in step 1. SQL needs a database user that maps to that UAMI before
   it can authenticate.

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 (recommended). The wrapper substitutes the
   <<UAMI_NAME>> placeholder below for you. Just run:
       .\steps\02-embeddings-in-sql\deploy.ps1

   Option B — from the VS Code SQL Editor / SSMS / Azure Data Studio.
   Make sure your editor is connected to the ProductsDB database (NOT
   master), then edit the one DECLARE line marked EDIT below and run.

   Where to find the value:
       UAMI name -> steps/01-foundation/outputs.json field "uamiName"
=================================================================================
*/

SET NOCOUNT ON;
GO

-- ============ EDIT THIS IF RUNNING FROM YOUR SQL EDITOR ============
DECLARE @uamiName SYSNAME = N'<<UAMI_NAME>>';   -- e.g. 'sqlrag-uami-dev'
-- ===================================================================

IF @uamiName LIKE N'%<<UAMI[_]NAME>>%'
BEGIN
    RAISERROR('Set @uamiName above (or run via deploy.ps1).', 16, 1);
    RETURN;
END

DECLARE @uamiQ NVARCHAR(258) = QUOTENAME(@uamiName);
DECLARE @sql   NVARCHAR(MAX);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @uamiName)
BEGIN
    SET @sql = N'CREATE USER ' + @uamiQ + N' FROM EXTERNAL PROVIDER;';
    EXEC sp_executesql @sql;
    PRINT 'Created database user ' + @uamiQ;
END
ELSE
BEGIN
    PRINT 'Database user ' + @uamiQ + ' already exists';
END

-- Least-privilege role memberships:
--   db_datareader: SELECT on all tables (DAB read entities + ad-hoc queries)
--   db_datawriter: INSERT/UPDATE/DELETE (in case DAB exposes write entities)
SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + @uamiQ + N';';
EXEC sp_executesql @sql;

SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + @uamiQ + N';';
EXEC sp_executesql @sql;

-- EXECUTE on the dbo schema so the UAMI can call any SP we create
-- (find_similar_reviews_hybrid in step 3).
SET @sql = N'GRANT EXECUTE ON SCHEMA::dbo TO ' + @uamiQ + N';';
EXEC sp_executesql @sql;

PRINT 'Granted db_datareader + db_datawriter + EXECUTE on schema::dbo to ' + @uamiQ;
GO
