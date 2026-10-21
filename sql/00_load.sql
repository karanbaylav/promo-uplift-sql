-- =====================================================================
-- Promotion uplift (84.51° The Complete Journey 2.0)  |  00 — Load raw tables
-- Source: 84.51° "The Complete Journey" 2.0, as packaged in the R package
-- completejourney, via the completejourney-py wheel on PyPI. Parquet files in data/raw/.
-- =====================================================================
CREATE OR REPLACE TABLE transactions          AS SELECT * FROM read_parquet('data/raw/transactions.parquet');
CREATE OR REPLACE TABLE products              AS SELECT * FROM read_parquet('data/raw/products.parquet');
CREATE OR REPLACE TABLE promotions            AS SELECT * FROM read_parquet('data/raw/promotions.parquet');
CREATE OR REPLACE TABLE coupons               AS SELECT * FROM read_parquet('data/raw/coupons.parquet');
CREATE OR REPLACE TABLE coupon_redemptions    AS SELECT * FROM read_parquet('data/raw/coupon_redemptions.parquet');
CREATE OR REPLACE TABLE campaigns             AS SELECT * FROM read_parquet('data/raw/campaigns.parquet');
CREATE OR REPLACE TABLE campaign_descriptions AS SELECT * FROM read_parquet('data/raw/campaign_descriptions.parquet');
CREATE OR REPLACE TABLE demographics          AS SELECT * FROM read_parquet('data/raw/demographics.parquet');

-- Load audit
SELECT 'transactions' AS tbl, COUNT(*) AS n_rows FROM transactions
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'promotions', COUNT(*) FROM promotions
UNION ALL SELECT 'coupons', COUNT(*) FROM coupons
UNION ALL SELECT 'coupon_redemptions', COUNT(*) FROM coupon_redemptions
UNION ALL SELECT 'campaigns', COUNT(*) FROM campaigns
UNION ALL SELECT 'campaign_descriptions', COUNT(*) FROM campaign_descriptions
UNION ALL SELECT 'demographics', COUNT(*) FROM demographics;
