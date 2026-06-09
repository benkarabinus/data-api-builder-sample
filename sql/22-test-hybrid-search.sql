/*
=================================================================================
 Step 3 / SQL 03 — Smoke-test dbo.find_similar_reviews_hybrid

 Sends three demo queries to the hybrid SP and prints the ranked results.
 Each result row includes vector_rank, keyword_rank, and rrf_score so you
 can see WHY each row landed where it did.

 RUNNING THIS SCRIPT
   Option A — via deploy.ps1 (recommended).
   Option B — from your SQL Editor: connect to ProductsDB and run.
   (No tokens to edit.)
=================================================================================
*/

SET NOCOUNT ON;
GO

PRINT '----- Query 1: semantic-leaning -----';
PRINT '"comfortable seating for long workdays"';
EXEC dbo.find_similar_reviews_hybrid
    @queryText = N'comfortable seating for long workdays',
    @top       = 5;

PRINT '----- Query 2: keyword-leaning -----';
PRINT '"battery life"';
EXEC dbo.find_similar_reviews_hybrid
    @queryText = N'battery life',
    @top       = 5;

PRINT '----- Query 3: mixed -----';
PRINT '"quiet keyboard for office"';
EXEC dbo.find_similar_reviews_hybrid
    @queryText = N'quiet keyboard for office',
    @top       = 5;
GO
