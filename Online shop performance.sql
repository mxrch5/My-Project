/* Cleaning data */
SELECT COUNT(*) FROM Sales_Transaction ; -- Total records 536350
-- Check null values 
SELECT * FROM Sales_Transaction WHERE TransactionNo IS NULL ;
SELECT * FROM Sales_Transaction WHERE TransactionDate IS NULL ;
SELECT * FROM Sales_Transaction WHERE ProductNo IS NULL ;
SELECT * FROM Sales_Transaction WHERE ProductName IS NULL ;
SELECT * FROM Sales_Transaction WHERE Price IS NULL ;
SELECT * FROM Sales_Transaction WHERE Quantity IS NULL ;
SELECT * FROM Sales_Transaction WHERE CustomerNo IS NULL ;
SELECT * FROM Sales_Transaction WHERE Country IS NULL ;
SELECT * FROM Sales_Transaction WHERE CustomerNo = '0' ;

-- Explore data 
SELECT MIN(TransactionDate) MinDate, MAX(TransactionDate) MaxDate FROM Sales_Transaction ; 
--MinDate 2018-12-01; MaxDate 2019-12-09
SELECT MIN(Price) MinPrice, MIN(Quantity) MinQuantity FROM Sales_Transaction ; 
--MinPrice 5.13 ; MinQuantity -80995


-- Check cancelled transactions 
SELECT * FROM Sales_Transaction 
WHERE TransactionNo LIKE'%C%' AND Quantity <= 0 ; --8585 records
SELECT * FROM Sales_Transaction 
WHERE TransactionNo LIKE'%C%' OR Quantity <= 0 ; --8585 records


-- Check duplicate values
WITH dup_check AS -- 5587 records
(
SELECT
	*,
	ROW_NUMBER() OVER (PARTITION BY TransactionNo, ProductNo, Quantity ORDER BY TransactionDate) as Duplicate_flag
FROM Sales_Transaction
)
SELECT *
FROM dup_check
WHERE Duplicate_flag > 1 ;


-- Removing duplicates
WITH ##Quantity AS -- 527765 records
(
SELECT * FROM Sales_Transaction
WHERE Quantity > 0
)

, ##duplicate_check AS -- 5262 duplicate records
(SELECT
	*,
	ROW_NUMBER() OVER (PARTITION BY TransactionNo, ProductNo, Quantity ORDER BY TransactionDate) as Dup_flag 
FROM ##Quantity
)

SELECT *
INTO ##Sales_Transaction_main -- 497491 clean data records
FROM ##duplicate_check
WHERE 
	Dup_flag = 1
and TransactionDate < '2019-12-01' ;

SELECT * FROM ##Sales_Transaction_main
-- Drop unnecessary column
ALTER TABLE ##Sales_Transaction_main
DROP COLUMN Dup_flag ;


-- Add new columns 
ALTER TABLE ##Sales_Transaction_main
ADD Amount FLOAT, YearMonth VARCHAR(7), DayOfWeek VARCHAR(10)

UPDATE ##Sales_Transaction_main
SET 
	Amount = Price * Quantity,
	YearMonth = CONVERT(VARCHAR(7), TransactionDate, 120),
	DayOfWeek = LEFT(DATENAME(WEEKDAY, TransactionDate), 3)


-- I. METRICS
-- 1. Average Order Value
SELECT
	SUM(Amount) as TotalRevenue,
	COUNT(DISTINCT TransactionNo) as TotalTransactions,
	SUM(Amount) / COUNT(DISTINCT TransactionNo) as AverageOrderValue
FROM ##Sales_Transaction_main ;


--2. Purchase Frequency
SELECT
	COUNT(DISTINCT TransactionNo) as TotalTransactions,
	COUNT(DISTINCT CustomerNo) as TotalCustomers,
	COUNT(DISTINCT TransactionNo) / COUNT(DISTINCT CustomerNo) as PurchaseFrequency
FROM ##Sales_Transaction_main;


--3. Repeat Customer Ratio (Repeat Purchase Rate)
WITH ##Customer_Purchase_history AS
(
SELECT
	CustomerNo,
	TransactionNo
FROM ##Sales_Transaction_main
GROUP BY
	CustomerNo,
	TransactionNo
 ) 

, ##Repeat_customers AS
(
SELECT
	CustomerNo,
	COUNT(TransactionNo) as NumberOfPurchases
FROM ##Customer_Purchase_history
GROUP BY CustomerNo
HAVING COUNT(TransactionNo) > 1
 )

SELECT
	COUNT(CustomerNo) as RepeatCustomers,
	(SELECT COUNT(DISTINCT CustomerNo) FROM ##Sales_Transaction_main) as TotalCustomers,
	FORMAT(1.0 * COUNT(CustomerNo) / (SELECT COUNT(DISTINCT CustomerNo) FROM ##Customer_Purchase_history), 'P') as RepeatPurchaseRate 
FROM ##Repeat_customers


--4. Time Between Purchases
WITH Customer_Purchase_history AS
(
SELECT
	CustomerNo,
	TransactionNo,
	TransactionDate
FROM ##Sales_Transaction_main
GROUP BY
	CustomerNo,
	TransactionNo,
	TransactionDate
 ) 

, Average_purchase_rate AS -- average days between purchases of each repeat customer
(
SELECT 
	CustomerNo,
	DATEDIFF(day, min(TransactionDate), max(TransactionDate)) as TotalDaysBetweenPurchases,
	COUNT(TransactionNo) as NumberOfPurchases,
	1.0 * DATEDIFF(day, min(TransactionDate), max(TransactionDate)) / (COUNT(TransactionNo) - 1) as AveragePurchaseRate
FROM Customer_Purchase_history
GROUP BY CustomerNo 
HAVING COUNT(TransactionNo) > 1
)

SELECT
	AVG(AveragePurchaseRate) as AverageDaysBetweenPurchases
FROM Average_purchase_rate


--II. PERFORMANCE
-- 1. The sales trend over the months (and revenue ranking) 
SELECT
    YearMonth,
    ROUND(SUM(Amount), 2) as Revenue,
	FORMAT((SUM(Amount) - LAG(SUM(Amount), 1) OVER (ORDER BY YearMonth)) 
          / LAG(SUM(Amount), 1) OVER (ORDER BY YearMonth), 'P') as RevenueChange,
	DENSE_RANK() OVER(ORDER BY SUM(Amount) DESC) as RevenueRank
FROM ##Sales_Transaction_main
GROUP BY YearMonth
ORDER BY YearMonth ;


-- 2. At which day of the week customers do most of the shopping? 
SELECT
	DayOfWeek,
	COUNT ( DISTINCT TransactionNo ) as NumberOfTransactions,
	ROUND( SUM(Amount), 2 ) as Revenue
FROM ##Sales_Transaction_main
GROUP BY DayOfWeek
ORDER BY 
	NumberOfTransactions DESC, 
	Revenue DESC;


-- 3. Market basket analysis (cross-selling recommendations)
WITH ##Item AS
(
	SELECT
		ProductNo as ItemID,
		COUNT (DISTINCT TransactionNo) as ItemCount,
		1.0 * COUNT (DISTINCT TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM ##Sales_Transaction_main) AS ItemSupport
	FROM ##Sales_Transaction_main
	GROUP BY ProductNo
	HAVING 1.0 * COUNT (DISTINCT TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM ##Sales_Transaction_main) >= 0.02
 )

, ##Pair AS
(
	SELECT
		S1.ProductNo AS Antecedent,
		S2.ProductNo AS Consequent,
		COUNT (DISTINCT S1.TransactionNo) AS PairCount,
		1.0 * COUNT (DISTINCT S1.TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM ##Sales_Transaction_main) AS PairSupport
	FROM ##Sales_Transaction_main S1
	JOIN ##Sales_Transaction_main S2
	ON S1.TransactionNo = S2.TransactionNo
	AND S1.ProductNo <> S2.ProductNo
	GROUP BY S1.ProductNo, S2.ProductNo
	HAVING 1.0 * COUNT (DISTINCT S1.TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM ##Sales_Transaction_main) >= 0.02
 )

, ##AssociationRule AS
(
SELECT
	Antecedent,
	Consequent,
	PairCount AS Frequency,
	1.0 * PairCount / I1.ItemCount AS Confidence,
	1.0 * PairSupport / (I1.ItemSupport * I2.ItemSupport) AS Lift
FROM ##Pair P
JOIN ##Item I1
ON P.Antecedent = I1.ItemID
JOIN ##Item I2
ON P.Consequent = I2.ItemID
)

SELECT
	Antecedent,
	Consequent,
	Antecedent + N' ---> ' + Consequent AS AssociationRule,
	Frequency,
	FORMAT(Confidence, 'P') AS Confidence,
	FORMAT(Lift, 'F') AS Lift
FROM ##AssociationRule
WHERE Lift > 1 AND Confidence >= 0.6
ORDER BY 
	Antecedent, 
	Confidence DESC, 
	Frequency DESC ;


-- 4. Customer retention rate
WITH Customer_Purchasing_history AS
(
SELECT
	CustomerNo,
	CONVERT(varchar(7), TransactionDate, 120) as YearMonth
	
FROM ##Sales_Transaction_main 
GROUP BY
	CustomerNo,
	CONVERT(varchar(7), TransactionDate, 120)
)

, Customer_First_purchase AS
(
SELECT 
	CustomerNo,
	MIN(YearMonth) as FirstPurchaseMonth
FROM Customer_Purchasing_history
GROUP BY
	CustomerNo
)

, Retained_customers_by_month AS 
(
SELECT
	FirstPurchaseMonth as OpeningPeriod,
	YearMonth as RetentionMonth,
	COUNT(CP.CustomerNo) as Retained_customers
FROM Customer_Purchasing_history CP
LEFT JOIN Customer_First_purchase CF 
	ON CP.CustomerNo = CF.CustomerNo
GROUP BY 
	FirstPurchaseMonth,
	YearMonth
)

, Opening_customers AS -- Number of customers at the beginning of the period
(
SELECT 
	FirstPurchaseMonth as OpeningPeriod,
	COUNT(CustomerNo) as OpeningCustomers
FROM Customer_first_purchase
GROUP BY
	FirstPurchaseMonth
)

SELECT
	OC.OpeningPeriod,
	OC.OpeningCustomers,
	RC.RetentionMonth,
	RC.Retained_customers,
	FORMAT( 1.0 * RC.Retained_customers / OC.OpeningCustomers ,'P' ) as CustomerRetentionRate 
FROM Retained_customers_by_month RC 
LEFT JOIN Opening_customers OC 
ON RC.OpeningPeriod = OC.OpeningPeriod
ORDER BY 1, 3 ;


-- 5. Customer segmentation 
WITH Transactions AS
(
	SELECT
		TransactionNo,
		TransactionDate,
		CustomerNo,
		SUM(Amount) AS TransactionAmount
	FROM ##Sales_Transaction_main
	GROUP BY TransactionNo, TransactionDate, CustomerNo 
)

, rfm_metrics AS
(
	SELECT
		CustomerNo,
		MAX(TransactionDate) AS LastActiveDate,
		DATEDIFF(DAY, MAX(TransactionDate), (SELECT MAX(TransactionDate) FROM ##Sales_Transaction_main)) AS Recency,
		COUNT(TransactionNo) AS Frequency,
		SUM(TransactionAmount) AS Monetary
	FROM Transactions
	GROUP BY CustomerNo
)

, rfm_percent_rank AS 
(
	SELECT
		*,
		PERCENT_RANK() OVER (ORDER BY Frequency) AS Frequency_percent_rank,
		PERCENT_RANK() OVER (ORDER BY Monetary) AS Monetary_percent_rank
	FROM rfm_metrics
)

, rfm_rank AS 
(
	SELECT
		*,
		CASE 
			WHEN Recency BETWEEN 0 AND 100 THEN 3
			WHEN Recency BETWEEN 100 AND 200 THEN 2
			WHEN Recency BETWEEN 200 AND 370 THEN 1
			ELSE 0 END 
		AS recency_rank,
		CASE 
			WHEN Frequency_percent_rank BETWEEN 0.8 AND 1 THEN 3
			WHEN Frequency_percent_rank BETWEEN 0.5 AND 0.8 THEN 2
			WHEN Frequency_percent_rank BETWEEN 0 AND 0.5 THEN 1
			ELSE 0 END
		AS frequency_rank,
		CASE 
			WHEN Monetary_percent_rank BETWEEN 0.8 AND 1 THEN 3
			WHEN Monetary_percent_rank BETWEEN 0.5 AND 0.8 THEN 2
			WHEN Monetary_percent_rank BETWEEN 0 AND 0.5 THEN 1
			ELSE 0 END
		AS monetary_rank
	FROM rfm_percent_rank
)

, rfm_rank_concat AS 
(
	SELECT
		*,
		CONCAT(recency_rank, frequency_rank, monetary_rank) AS rfm_rank
	FROM rfm_rank
)

SELECT 
    *,
	CASE 
        WHEN recency_rank = 1 THEN '1-Churned'
        WHEN recency_rank = 2 THEN '2-Hibernating'
        WHEN recency_rank = 3 THEN '3-Active'
    END 
    AS recency_segment,
    CASE 
        WHEN frequency_rank = 1 THEN '1-Least frequent'
        WHEN frequency_rank = 2 THEN '2-Frequent'
        WHEN frequency_rank = 3 THEN '3-Most frequent'
    END 
    AS frequency_segment,
    CASE
        WHEN monetary_rank = 1 THEN '1-Least spending'
        WHEN monetary_rank = 2 THEN '2-Normal spending'
        WHEN monetary_rank = 3 THEN '3-Most spending'
    END 
    AS monetary_segment,
    CASE
        WHEN rfm_rank = '333' THEN 'Champions'
		WHEN rfm_rank = '332' THEN 'Loyal Customers'
        WHEN rfm_rank IN ('331', '323') THEN 'Potential Loyalists'
        WHEN rfm_rank = '313' THEN 'Big Spenders'
        WHEN rfm_rank = '233' THEN 'Can`t Lose Them'
        WHEN rfm_rank LIKE'2_3' THEN 'At Risk'
        WHEN rfm_rank LIKE '32_' THEN 'Normal'
        WHEN rfm_rank LIKE '1__' THEN 'Lost'
        ELSE 'Undefined'
    END
    AS rfm_segment
FROM rfm_rank_concat ;


-- 6. Size of each customer segment 
WITH Transactions AS
(
	SELECT
		TransactionNo,
		TransactionDate,
		CustomerNo,
		SUM(Amount) AS TransactionAmount
	FROM ##Sales_Transaction_main
	GROUP BY TransactionNo, TransactionDate, CustomerNo 
)

, rfm_metrics AS
(
	SELECT
		CustomerNo,
		MAX([Date]) AS LastActiveDate,
		DATEDIFF(DAY, MAX(TransactionDate), (SELECT MAX(TransactionDate) FROM ##Sales_Transaction_main)) AS Recency,
		COUNT(TransactionNo) AS Frequency,
		SUM(TransactionAmount) AS Monetary
	FROM Transactions
	GROUP BY CustomerNo
)

, rfm_percent_rank AS 
(
	SELECT
		*,
		PERCENT_RANK() OVER (ORDER BY Frequency) AS Frequency_percent_rank,
		PERCENT_RANK() OVER (ORDER BY Monetary) AS Monetary_percent_rank
	FROM rfm_metrics
)

, rfm_rank AS 
(
	SELECT
		*,
		CASE 
			WHEN Recency BETWEEN 0 AND 100 THEN 3
			WHEN Recency BETWEEN 100 AND 200 THEN 2
			WHEN Recency BETWEEN 200 AND 370 THEN 1
			ELSE 0 END 
		AS recency_rank,
		CASE 
			WHEN Frequency_percent_rank BETWEEN 0.8 AND 1 THEN 3
			WHEN Frequency_percent_rank BETWEEN 0.5 AND 0.8 THEN 2
			WHEN Frequency_percent_rank BETWEEN 0 AND 0.5 THEN 1
			ELSE 0 END
		AS frequency_rank,
		CASE 
			WHEN Monetary_percent_rank BETWEEN 0.8 AND 1 THEN 3
			WHEN Monetary_percent_rank BETWEEN 0.5 AND 0.8 THEN 2
			WHEN Monetary_percent_rank BETWEEN 0 AND 0.5 THEN 1
			ELSE 0 END
		AS monetary_rank
	FROM rfm_percent_rank
)

, rfm_rank_concat AS 
(
	SELECT
		*,
		CONCAT(recency_rank, frequency_rank, monetary_rank) AS rfm_rank
	FROM rfm_rank
)

, rfm_segment AS
(
SELECT 
    *,
	CASE 
        WHEN recency_rank = 1 THEN '1-Churned'
        WHEN recency_rank = 2 THEN '2-Hibernating'
        WHEN recency_rank = 3 THEN '3-Active'
    END 
    AS recency_segment,
    CASE 
        WHEN frequency_rank = 1 THEN '1-Least frequent'
        WHEN frequency_rank = 2 THEN '2-Frequent'
        WHEN frequency_rank = 3 THEN '3-Most frequent'
    END 
    AS frequency_segment,
    CASE
        WHEN monetary_rank = 1 THEN '1-Least spending'
        WHEN monetary_rank = 2 THEN '2-Normal spending'
        WHEN monetary_rank = 3 THEN '3-Most spending'
    END 
    AS monetary_segment,
    CASE
        WHEN rfm_rank = '333' THEN 'Champions'
		WHEN rfm_rank = '332' THEN 'Loyal Customers'
        WHEN rfm_rank IN ('331', '323') THEN 'Potential Loyalists'
        WHEN rfm_rank = '313' THEN 'Big Spenders'
        WHEN rfm_rank = '233' THEN 'Can`t Lose Them'
        WHEN rfm_rank LIKE'2_3' THEN 'At Risk'
        WHEN rfm_rank LIKE '32_' THEN 'Normal'
        WHEN rfm_rank LIKE '1__' THEN 'Lost'
        ELSE 'Undefined'
    END
    AS rfm_segment
FROM rfm_rank_concat
)

SELECT
    rfm_segment,
    COUNT(CustomerNo) AS CustomerCount,
	FORMAT(1.0 * COUNT(CustomerNo) / SUM(COUNT(CustomerNo)) OVER(), 'P') AS Proportion
FROM rfm_segment
GROUP BY rfm_segment
ORDER BY 3 DESC ;