-- 1. Ingest

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

-- 2. Transform

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

    BOOL_OR(cl.unit_cost IS NULL)                                                           AS has_missing_cost
FROM sales s
LEFT JOIN cost_lookup cl
       ON cl.Brand = s.Brand
      AND cl.Size  = s.Size
GROUP BY s.Brand, s.Size;


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

-- 3. Report — write the four ranking tables and the two drop lists

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

