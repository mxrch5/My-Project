-- Checking null values 
SELECT * FROM Sales_Transaction WHERE TransactionNo IS NULL ;
SELECT * FROM Sales_Transaction WHERE TransactionDate IS NULL ;
SELECT * FROM Sales_Transaction WHERE ProductNo IS NULL ;
SELECT * FROM Sales_Transaction WHERE ProductName IS NULL ;
SELECT * FROM Sales_Transaction WHERE Price IS NULL ;
SELECT * FROM Sales_Transaction WHERE Quantity IS NULL ;
SELECT * FROM Sales_Transaction WHERE CustomerNo IS NULL ;
SELECT * FROM Sales_Transaction WHERE Country IS NULL ;


-- Explore data 
SELECT MIN(TransactionDate) MinDate, MAX(TransactionDate) MaxDate FROM Sales_Transaction ; --MinDate 2018-12-01, MaxDate 2019-12-09
SELECT DISTINCT Country FROM Sales_Transaction ;
SELECT MIN(Price) MinPrice, MIN(Quantity) MinQuantity FROM Sales_Transaction ; --MinQuantity is negative value


-- Check cancelled transactions 
SELECT COUNT(*) FROM Sales_Transaction WHERE TransactionNo LIKE'%C%' AND Quantity <= 0 ; --8585 rows
SELECT COUNT(*) FROM Sales_Transaction WHERE TransactionNo LIKE'%C%' OR Quantity <= 0 ; --8585 rows


-- Delete canceled transactions and unsuitable data 
DELETE FROM Sales_Transaction
WHERE TransactionNo LIKE 'C%' OR Quantity <= 0 --8585 rows deleted

DELETE FROM Sales_Transaction
WHERE [TransactionDate] >= '2019-12-01' --25012 rows deleted


-- Add new columns 
ALTER TABLE Sales_Transaction
ADD Amount FLOAT
UPDATE Sales_Transaction
SET Amount = Price * Quantity

ALTER TABLE Sales_Transaction
ADD YearMonth VARCHAR(7)
UPDATE Sales_Transaction
SET YearMonth = CONVERT(VARCHAR(7), TransactionDate, 120)

ALTER TABLE Sales_Transaction
ADD DayOfWeek VARCHAR(3)
UPDATE Sales_Transaction
SET DayOfWeek = LEFT(DATENAME(WEEKDAY, TransactionDate), 3)


-- 1. The sales trend over the months (and revenue ranking) 
SELECT
    YearMonth,
    SUM(Amount) AS Revenue,
    SUM(Amount) - LAG(SUM(Amount), 1) OVER (ORDER BY YearMonth) AS RevenueChange,
    ROUND(  100.0 * (SUM(Amount) - LAG(SUM(Amount), 1) OVER (ORDER BY YearMonth)) 
          / LAG(SUM(Amount), 1) OVER (ORDER BY YearMonth)
          , 2) AS Percentage_RevenueChange,
	DENSE_RANK() OVER(ORDER BY SUM(Amount) DESC)  AS RevenueRank
FROM Sales_Transaction
GROUP BY YearMonth
ORDER BY YearMonth ;


-- 2. At which day of the week customers do most of the shopping? 
SELECT
	DayOfWeek,
	COUNT (DISTINCT TransactionNo) AS NumberOfTransactions,
	SUM(Amount) AS Revenue
FROM Sales_Transaction
GROUP BY DayOfWeek ;


-- 3. Market basket analysis 
WITH ##Item AS
(
	SELECT
		ProductNo AS ItemID,
		COUNT (DISTINCT TransactionNo) AS ItemCount,
		1.0 * COUNT (DISTINCT TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM Sales_Transaction) AS ItemSupport
	FROM Sales_Transaction
	GROUP BY ProductNo
	HAVING 1.0 * COUNT (DISTINCT TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM Sales_Transaction) >= 0.02
 )

, ##Pair AS
(
	SELECT
		S1.ProductNo AS Antecedent,
		S2.ProductNo AS Consequent,
		COUNT (DISTINCT S1.TransactionNo) AS PairCount,
		1.0 * COUNT (DISTINCT S1.TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM Sales_Transaction) AS PairSupport
	FROM Sales_Transaction S1
	JOIN Sales_Transaction S2
	ON S1.TransactionNo = S2.TransactionNo
	AND S1.ProductNo <> S2.ProductNo
	GROUP BY S1.ProductNo, S2.ProductNo
	HAVING 1.0 * COUNT (DISTINCT S1.TransactionNo) / (SELECT COUNT (DISTINCT TransactionNo) FROM Sales_Transaction) >= 0.02
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
	FORMAT(Confidence, 'P') AS Confidence,
	FORMAT(Lift, 'F') AS Lift
FROM ##AssociationRule
WHERE Lift > 1 AND Confidence >= 0.6
ORDER BY Antecedent, Confidence DESC, Frequency DESC ;


-- 4. Customer segmentation 
WITH Transactions AS
(
	SELECT
		TransactionNo,
		TransactionDate,
		CustomerNo,
		SUM(Amount) AS TransactionAmount
	FROM Sales_Transaction
	GROUP BY TransactionNo, TransactionDate, CustomerNo 
)

, rfm_metrics AS
(
	SELECT
		CustomerNo,
		MAX(TransactionDate) AS LastActiveDate,
		DATEDIFF(DAY, MAX(TransactionDate), (SELECT MAX(TransactionDate) FROM Sales_Transaction)) AS Recency,
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


-- 5. Size of each customer segment 
WITH Transactions AS
(
	SELECT
		TransactionNo,
		TransactionDate,
		CustomerNo,
		SUM(Amount) AS TransactionAmount
	FROM Sales_Transaction
	GROUP BY TransactionNo, TransactionDate, CustomerNo 
)

, rfm_metrics AS
(
	SELECT
		CustomerNo,
		MAX([Date]) AS LastActiveDate,
		DATEDIFF(DAY, MAX(TransactionDate), (SELECT MAX(TransactionDate) FROM Sales_Transaction)) AS Recency,
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