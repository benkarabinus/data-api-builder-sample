IF OBJECT_ID('dbo.ProductReviews', 'U') IS NOT NULL DROP TABLE dbo.ProductReviews;
IF OBJECT_ID('dbo.Products', 'U') IS NOT NULL DROP TABLE dbo.Products;

CREATE TABLE dbo.Products (
    ProductID INT IDENTITY(1,1) NOT NULL,
    Name NVARCHAR(150) NOT NULL,
    Category NVARCHAR(100) NOT NULL,
    Price DECIMAL(10,2) NOT NULL,
    Cost DECIMAL(10,2) NOT NULL,
    Inventory INT NOT NULL,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Products PRIMARY KEY (ProductID)
);

CREATE TABLE dbo.ProductReviews (
    ReviewID INT IDENTITY(1,1) NOT NULL,
    ProductID INT NOT NULL,
    ReviewerName NVARCHAR(120) NOT NULL,
    ReviewText NVARCHAR(MAX) NOT NULL,
    Rating TINYINT NOT NULL,
    ReviewEmbedding VECTOR(1536) NULL,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_ProductReviews PRIMARY KEY (ReviewID),
    CONSTRAINT FK_ProductReviews_Products FOREIGN KEY (ProductID) REFERENCES dbo.Products(ProductID)
);

CREATE INDEX IX_ProductReviews_ProductID ON dbo.ProductReviews(ProductID);
