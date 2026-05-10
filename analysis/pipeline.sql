-- Annie's Magic Numbers — analytical pipeline
--
-- Runs in three logical stages: ingest, transform, report.
-- We persist tables to a DuckDB file so re-runs are cheap; only the first
-- run pays the CSV-parse cost (the sales file alone is ~1.7 GB).
--
-- The orchestrator substitutes the placeholders __SRC__ (input CSV dir)
-- and __OUT__ (where reports land) before this script reaches DuckDB.
-- That keeps the SQL portable while sidestepping the fact that DuckDB's
-- COPY ... TO does not accept variable-bound paths.

-- ---------------------------------------------------------------------------
-- 1. Ingest
-- ---------------------------------------------------------------------------
-- Only the three files we actually need for product/brand P&L:
--   * 2017PurchasePricesDec.csv  — fallback unit cost when a SKU was sold
--                                  but never purchased in-period
--   * PurchasesFINAL12312016.csv — actual 2016 purchases (line level)
--   * SalesFINAL12312016.csv     — actual 2016 sales      (line level)
--
-- Beg/End inventory tables are loaded too, but only as a sanity check at
-- the end — they are not on the critical path of the per-SKU calculation.

CREATE OR REPLACE TABLE catalog AS
    SELECT * FROM read_csv_auto('__SRC__/2017PurchasePricesDec.csv', header=true);

CREATE OR REPLACE TABLE purchases AS
    SELECT * FROM read_csv_auto('__SRC__/PurchasesFINAL12312016.csv', header=true, parallel=true);

CREATE OR REPLACE TABLE sales AS
    SELECT * FROM read_csv_auto('__SRC__/SalesFINAL12312016.csv', header=true, parallel=true);

CREATE OR REPLACE TABLE beg_inv AS
    SELECT * FROM read_csv_auto('__SRC__/BegInvFINAL12312016.csv', header=true);

CREATE OR REPLACE TABLE end_inv AS
    SELECT * FROM read_csv_auto('__SRC__/EndInvFINAL12312016.csv', header=true);


-- ---------------------------------------------------------------------------
-- 2. Transform
-- ---------------------------------------------------------------------------
-- Cost per (Brand, Size).  Preferred source is the weighted-average price
-- Annie actually paid in 2016; fall back to the catalog's PurchasePrice if
-- a SKU was sold but never purchased in-period (happens when a SKU sells
-- down from beginning inventory and is not re-ordered).
CREATE OR REPLACE TABLE cost_lookup AS
WITH purchased_avg AS (
    SELECT Brand,
           Size,
           SUM(Dollars) / NULLIF(SUM(Quantity), 0) AS avg_unit_cost
    FROM   purchases
    GROUP  BY Brand, Size
),
catalog_cost AS (
    SELECT Brand,
           Size,
           MAX(PurchasePrice) AS catalog_cost
    FROM   catalog
    GROUP  BY Brand, Size
)
SELECT
    COALESCE(pa.Brand, cc.Brand)                             AS Brand,
    COALESCE(pa.Size,  cc.Size)                              AS Size,
    COALESCE(pa.avg_unit_cost, cc.catalog_cost)              AS unit_cost,
    pa.avg_unit_cost IS NOT NULL                             AS cost_from_purchases
FROM purchased_avg pa
FULL OUTER JOIN catalog_cost cc
       ON cc.Brand = pa.Brand
      AND cc.Size  = pa.Size;


-- Per-SKU P&L (a "product" is a Brand + Size combination — that is the
-- actual stocking unit).
CREATE OR REPLACE TABLE product_pnl AS
SELECT
    s.Brand,
    s.Size,
    ANY_VALUE(s.Description)                                                                AS Description,
    SUM(s.SalesQuantity)                                                                    AS units_sold,
    ROUND(SUM(s.SalesDollars), 2)                                                           AS revenue,
    ROUND(SUM(s.SalesQuantity * cl.unit_cost), 2)                                           AS cogs,
    ROUND(SUM(s.ExciseTax), 2)                                                              AS excise_tax,
    ROUND(SUM(s.SalesDollars) - SUM(s.SalesQuantity * cl.unit_cost), 2)                     AS gross_profit,
    ROUND(SUM(s.SalesDollars) - SUM(s.SalesQuantity * cl.unit_cost) - SUM(s.ExciseTax), 2)  AS net_profit,
    ROUND(100.0 * (SUM(s.SalesDollars) - SUM(s.SalesQuantity * cl.unit_cost))
                 / NULLIF(SUM(s.SalesDollars), 0), 2)                                       AS gross_margin_pct,
    ROUND(100.0 * (SUM(s.SalesDollars) - SUM(s.SalesQuantity * cl.unit_cost) - SUM(s.ExciseTax))
                 / NULLIF(SUM(s.SalesDollars), 0), 2)                                       AS net_margin_pct,
    -- bool_or is true if any sales row had no matching cost — flags that
    -- the COGS for this SKU is understated.
    BOOL_OR(cl.unit_cost IS NULL)                                                           AS has_missing_cost
FROM sales s
LEFT JOIN cost_lookup cl
       ON cl.Brand = s.Brand
      AND cl.Size  = s.Size
GROUP BY s.Brand, s.Size;


-- "Brand" in this dataset is actually a SKU identifier: e.g. Brand=58
-- maps 1:1 to "Gekkeikan Black & Gold Sake".  When Annie says "brand" she
-- almost certainly means the product family across pack sizes (e.g. "Jim
-- Beam" 750mL + 1.75L combined).  We roll up by Brand id, ignoring Size,
-- and pick a representative description.
CREATE OR REPLACE TABLE brand_pnl AS
SELECT
    Brand,
    ANY_VALUE(Description)                                          AS Description,
    SUM(units_sold)                                                 AS units_sold,
    ROUND(SUM(revenue), 2)                                          AS revenue,
    ROUND(SUM(cogs), 2)                                             AS cogs,
    ROUND(SUM(excise_tax), 2)                                       AS excise_tax,
    ROUND(SUM(gross_profit), 2)                                     AS gross_profit,
    ROUND(SUM(net_profit), 2)                                       AS net_profit,
    ROUND(100.0 * SUM(gross_profit) / NULLIF(SUM(revenue), 0), 2)   AS gross_margin_pct,
    ROUND(100.0 * SUM(net_profit)   / NULLIF(SUM(revenue), 0), 2)   AS net_margin_pct,
    BOOL_OR(has_missing_cost)                                       AS has_missing_cost
FROM product_pnl
GROUP BY Brand;


-- ---------------------------------------------------------------------------
-- 3. Report — write the four ranking tables and the two drop lists
-- ---------------------------------------------------------------------------
-- Margin rankings carry a minimum-revenue filter so that a single $20 sale
-- with a fluky 95 % margin does not crowd out genuinely profitable SKUs.
-- They also exclude SKUs where any sales row had no cost match
-- (has_missing_cost) and where the resulting COGS rounds to zero — both
-- are almost always cost-lookup holes masquerading as 99 % margins, not
-- actual home-run products.  The thresholds are deliberately conservative
-- — Annie can relax them.

COPY (
    SELECT Brand, Size, Description, units_sold, revenue, cogs,
           gross_profit, net_profit, gross_margin_pct, net_margin_pct
    FROM   product_pnl
    ORDER  BY net_profit DESC
    LIMIT  10
) TO '__OUT__/top10_products_by_profit.csv' (HEADER, DELIMITER ',');

COPY (
    SELECT Brand, Size, Description, units_sold, revenue, cogs,
           gross_profit, net_profit, gross_margin_pct, net_margin_pct
    FROM   product_pnl
    WHERE  revenue >= 10000
      AND  cogs    >  0
      AND  NOT has_missing_cost
    ORDER  BY net_margin_pct DESC
    LIMIT  10
) TO '__OUT__/top10_products_by_margin.csv' (HEADER, DELIMITER ',');

COPY (
    SELECT Brand, Description, units_sold, revenue, cogs,
           gross_profit, net_profit, gross_margin_pct, net_margin_pct
    FROM   brand_pnl
    ORDER  BY net_profit DESC
    LIMIT  10
) TO '__OUT__/top10_brands_by_profit.csv' (HEADER, DELIMITER ',');

COPY (
    SELECT Brand, Description, units_sold, revenue, cogs,
           gross_profit, net_profit, gross_margin_pct, net_margin_pct
    FROM   brand_pnl
    WHERE  revenue >= 25000
      AND  cogs    >  0
      AND  NOT has_missing_cost
    ORDER  BY net_margin_pct DESC
    LIMIT  10
) TO '__OUT__/top10_brands_by_margin.csv' (HEADER, DELIMITER ',');


-- Drop list: a SKU/brand is a candidate for de-listing if it lost money
-- in 2016 *and* sold enough volume that the loss was not noise.
--   * units_sold >= 12   — at least monthly cadence; rules out one-off
--                          mis-prices
--   * revenue   >= 500   — meaningful dollars at risk
COPY (
    SELECT Brand, Size, Description, units_sold, revenue, cogs, excise_tax,
           gross_profit, net_profit, gross_margin_pct, net_margin_pct,
           has_missing_cost
    FROM   product_pnl
    WHERE  net_profit < 0
      AND  units_sold >= 12
      AND  revenue    >= 500
      AND  NOT has_missing_cost
    ORDER  BY net_profit ASC
) TO '__OUT__/drop_candidates_products.csv' (HEADER, DELIMITER ',');

COPY (
    SELECT Brand, Description, units_sold, revenue, cogs, excise_tax,
           gross_profit, net_profit, gross_margin_pct, net_margin_pct,
           has_missing_cost
    FROM   brand_pnl
    WHERE  net_profit < 0
      AND  revenue    >= 1000
      AND  NOT has_missing_cost
    ORDER  BY net_profit ASC
) TO '__OUT__/drop_candidates_brands.csv' (HEADER, DELIMITER ',');


-- ---------------------------------------------------------------------------
-- 4. Sanity checks — written to stdout for the orchestrator to capture
-- ---------------------------------------------------------------------------
-- (a) Inventory roll-forward at cost basis:
--         BegInv$ + Purchases$ - EndInv$  ≈  COGS$
--     The Price column in beg/end inventory is the retail shelf price,
--     so we revalue inventory at our cost_lookup unit_cost to keep both
--     sides on the same basis.  A modest gap is expected (shrinkage,
--     mid-year cost shifts, the small slice of unreconciled SKUs).
-- (b) Coverage: how many sales rows / dollars hit a NULL unit cost.

WITH beg AS (
    SELECT ROUND(SUM(b.onHand * cl.unit_cost), 2) AS dollars
    FROM   beg_inv b LEFT JOIN cost_lookup cl
           ON cl.Brand = b.Brand AND cl.Size = b.Size
),
end_ AS (
    SELECT ROUND(SUM(e.onHand * cl.unit_cost), 2) AS dollars
    FROM   end_inv e LEFT JOIN cost_lookup cl
           ON cl.Brand = e.Brand AND cl.Size = e.Size
)
SELECT 'inventory_rollforward' AS check_name,
       (SELECT dollars FROM beg)                                AS beg_inv_at_cost,
       (SELECT ROUND(SUM(Dollars), 2) FROM purchases)           AS purchases_at_cost,
       (SELECT dollars FROM end_)                               AS end_inv_at_cost,
       (SELECT dollars FROM beg)
           + (SELECT ROUND(SUM(Dollars), 2) FROM purchases)
           - (SELECT dollars FROM end_)                         AS implied_cogs,
       (SELECT ROUND(SUM(cogs), 2) FROM product_pnl)            AS computed_cogs,
       ROUND(100.0 * (
            (SELECT ROUND(SUM(cogs), 2) FROM product_pnl)
            - ((SELECT dollars FROM beg)
               + (SELECT ROUND(SUM(Dollars), 2) FROM purchases)
               - (SELECT dollars FROM end_))
       ) / NULLIF((SELECT dollars FROM beg)
               + (SELECT ROUND(SUM(Dollars), 2) FROM purchases)
               - (SELECT dollars FROM end_), 0), 2)             AS rollforward_variance_pct;

SELECT 'cost_coverage' AS check_name,
       COUNT(*)                                          AS sales_rows,
       SUM(CASE WHEN cl.unit_cost IS NULL THEN 1 ELSE 0 END) AS rows_missing_cost,
       ROUND(100.0 * SUM(CASE WHEN cl.unit_cost IS NULL THEN 1 ELSE 0 END) / COUNT(*), 4)
                                                         AS pct_rows_missing_cost,
       ROUND(SUM(CASE WHEN cl.unit_cost IS NULL THEN s.SalesDollars ELSE 0 END), 2)
                                                         AS dollars_missing_cost
FROM sales s
LEFT JOIN cost_lookup cl ON cl.Brand = s.Brand AND cl.Size = s.Size;

SELECT 'company_totals' AS check_name,
       ROUND(SUM(revenue),     2) AS revenue,
       ROUND(SUM(cogs),        2) AS cogs,
       ROUND(SUM(excise_tax),  2) AS excise_tax,
       ROUND(SUM(gross_profit),2) AS gross_profit,
       ROUND(SUM(net_profit),  2) AS net_profit,
       ROUND(100.0 * SUM(gross_profit) / NULLIF(SUM(revenue), 0), 2) AS gross_margin_pct,
       ROUND(100.0 * SUM(net_profit)   / NULLIF(SUM(revenue), 0), 2) AS net_margin_pct
FROM product_pnl;
