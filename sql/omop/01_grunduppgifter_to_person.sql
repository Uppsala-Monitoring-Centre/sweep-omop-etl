/*

[PERSON] ETL
Extracts lopnrs from grunduppgifter and implement cohort eligibility criteria and data quality constraints.

SWEEP cohort observation window:
- Data lock point: 2024-12-31.
- Data anchoring point: 2005-07-01 (start of lmed)

1. base population: all lopnrs from grunduppgifter
2. lmed data constraint via INNER JOIN clause:
   - keep lopnr with record in lmed only (LMED is the base of SWEEP's source population)
3. observation period contraint via INNER JOIN clause (see also logic observation_period table):
   - keep lopnrs observed any time after 2005-07-01, i.e.,
     * lopnrs with no migration record
    * lopnrs with at least one immigration record AND at least one residency interval ending after 2005‑07‑01
     * lopnrs with no immigration record AND with emigration after 2005‑07‑01
4. data quality constraints in WHERE clause:
   - remove lopnrs with invalid sex
   - remove lopnrs with invalid year of birth
   - remove lopnrs with reused PIN (aternr <> 0)
   - remove lopnrs with incorrect PIN (felsenpnr <> 0)
   - remove lopnrs with a coordination nr (samordnr <> 0)
   - remove lopnrs with death before July 2025
5. data plausiblity constraints in WHERE clause:
   - remove lopnrs born after study end/death/emigration (earliest)
   - remove lopnrs with immigration after death

*/

TRUNCATE TABLE {{OUTPUT_SCHEMA}}.person;

-- clean dors data (dismiss records with _AVI_ and R999 codes (no death certificate) for duplicate lopnrs)
DROP TABLE IF EXISTS cleaned_dors;
CREATE TEMP TABLE cleaned_dors AS
SELECT *
FROM (
    SELECT
        t.*,
        ROW_NUMBER() OVER (
            PARTITION BY lopnr
            ORDER BY
                CASE WHEN ulorsak IN ('_AVI_', 'R999') THEN 1 ELSE 0 END
        ) AS rn
    FROM {{INPUT_SCHEMA}}.dors t
) x
WHERE rn = 1;

-- read and parse migration data as in the OBSERVATION_PERIOD ETL: impute partial dates (immigration to end,
-- emigration to start of the known period) and discard events without any date information (parse_par_date
-- returns NULL for them)
DROP TABLE IF EXISTS cleaned_migration_events;
CREATE TEMP TABLE cleaned_migration_events AS
WITH raw_events AS (
    SELECT
        lopnr,
        posttyp,
        event_date
    FROM (
        SELECT
            lopnr,
            posttyp,
            etl_common.parse_par_date(
                raw_value => datum::text,
                partial_date_rule => CASE WHEN posttyp = 'Utv' THEN 'period_start' ELSE 'period_end' END
            ) AS event_date
        FROM {{INPUT_SCHEMA}}.migrationer
    ) parsed
    WHERE event_date IS NOT NULL
),

-- identify previous migration event type (utv/inv) per lopnr
events_with_prev AS (
    SELECT
        lopnr,
        posttyp,
        event_date,
        LAG(posttyp) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS prev_type
    FROM raw_events
),

-- group consecutive same type events (utv/inv)
events_with_groups AS (
    SELECT
        lopnr,
        posttyp,
        event_date,
        SUM(
            CASE
                WHEN prev_type IS NULL OR posttyp <> prev_type THEN 1
                ELSE 0
            END
        ) OVER (
            PARTITION BY lopnr
            ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS grp
    FROM events_with_prev
),

-- clean administrative errors in migration sequence, collapse runs of same type events: keep latest inv / earliest utv in a run
cleaned AS (
    SELECT
        lopnr,
        posttyp,
        CASE
            WHEN posttyp = 'Inv' THEN MAX(event_date)
            ELSE MIN(event_date)
        END AS event_date
    FROM events_with_groups
    GROUP BY lopnr, grp, posttyp
)
SELECT *
FROM cleaned;

DROP TABLE IF EXISTS observed_persons;
CREATE TEMP TABLE observed_persons AS

-- define event to event intervals
WITH intervals AS (
    SELECT
        lopnr,
        event_date AS start_date, -- current event data
        LEAD(event_date) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS next_date, -- date of next event
        posttyp, -- current migration type
        LEAD(posttyp) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS next_type -- next migration type
    FROM cleaned_migration_events
),

-- define residency intervals: keeps only events where the current event is immigration. If the next event is utv take the emigration date, otherwise the data lock point
valid_intervals AS (
    SELECT
        lopnr,
        start_date,
        CASE
            WHEN next_type = 'Utv' THEN next_date
            ELSE DATE '2024-12-31'
        END AS end_date
    FROM intervals
    WHERE posttyp = 'Inv'
)

-- identify lopnrs observable after 1 July 2005
-- 1. lopnrs with no migration record
SELECT g.lopnr
FROM {{INPUT_SCHEMA}}.grunduppgifter g
LEFT JOIN cleaned_migration_events r ON g.lopnr = r.lopnr
WHERE r.lopnr IS NULL

UNION

-- 2. lopnrs with at least one immigration record AND at least one residency interval ending after 2005‑07‑01
SELECT DISTINCT lopnr
FROM valid_intervals
WHERE end_date > DATE '2005-07-01'

UNION

-- 3. lopnrs with no immigration record AND with emigration after 2005‑07‑01
SELECT x.lopnr
FROM (
    SELECT
        lopnr,
        MIN(CASE WHEN posttyp = 'Utv' THEN event_date END) AS first_utv,
        MIN(CASE WHEN posttyp = 'Inv' THEN event_date END) AS first_inv
    FROM cleaned_migration_events
    GROUP BY lopnr
) x
WHERE first_inv IS NULL
  AND first_utv > DATE '2005-07-01';

-- select earliest emigration and latest immigration record for plausibility checks
WITH emigration AS (
    SELECT 
        lopnr,
        MIN(event_date) AS min_emigration_date
    FROM cleaned_migration_events
    WHERE posttyp = 'Utv'
    GROUP BY lopnr
),

immigration AS (
    SELECT 
        lopnr,
        MAX(event_date) AS max_immigration_date
    FROM cleaned_migration_events
    WHERE posttyp = 'Inv'
    GROUP BY lopnr
)

-- populate person table
INSERT INTO {{OUTPUT_SCHEMA}}.person
(
    person_id,
    person_source_value,
    gender_concept_id,
    gender_source_value,
    year_of_birth,
    race_concept_id,
    ethnicity_concept_id
)
SELECT
    g.lopnr AS person_id,
    g.lopnr AS person_source_value,
    CASE
        WHEN g.kon = 1 THEN 8507  -- Male
        WHEN g.kon = 2 THEN 8532  -- Female
        ELSE 0
    END AS gender_concept_id,
    g.kon AS gender_source_value,
    g.fodelsear AS year_of_birth,
    0 AS race_concept_id,
    0 AS ethnicity_concept_id
FROM {{INPUT_SCHEMA}}.grunduppgifter g

-- must have a valid record in LMED
INNER JOIN (
    SELECT DISTINCT lopnr
    FROM {{INPUT_SCHEMA}}.lmed
    -- omit non-drug records
	  WHERE lmed.otyp not in ('H','L','A')
	  AND lmed.varutyp not in ('HA','OV')
) l ON g.lopnr = l.lopnr

-- must be observable after 2005-07-01 
INNER JOIN observed_persons op
    ON op.lopnr = g.lopnr

-- remove invalid deaths (death before 2005-07-01)
LEFT JOIN (
    SELECT DISTINCT lopnr
    FROM cleaned_dors
    WHERE etl_common.parse_par_date(
              raw_value => dodsdat::text,
              partial_date_rule => 'period_end'
          ) <= DATE '2005-07-01'

    UNION ALL

    SELECT DISTINCT lopnr
    FROM {{INPUT_SCHEMA}}.grunduppgifter
    WHERE etl_common.parse_par_date(
              raw_value => doddatum::text,
              partial_date_rule => 'period_end'
          ) <= DATE '2005-07-01'
) invalid_deaths
ON g.lopnr = invalid_deaths.lopnr

-- add death data for data plausibility check
LEFT JOIN cleaned_dors d
    ON g.lopnr = d.lopnr

-- add migration summaries for data plausibility check
LEFT JOIN emigration e
    ON g.lopnr = e.lopnr

LEFT JOIN immigration i
    ON g.lopnr = i.lopnr

WHERE
    -- data quality
    g.kon IN (1, 2)
    AND g.fodelsear BETWEEN 1900 AND 2024
    AND g.aterpnr = 0
    AND g.felsenpnr = 0
    AND g.samordnr = 0
    AND invalid_deaths.lopnr IS NULL

    -- data plausbility: birth before death, study or earliest emigration
    AND MAKE_DATE(g.fodelsear::int, 1, 1) <
        LEAST(
            DATE '2024-12-31',
            etl_common.parse_par_date(
                raw_value => g.doddatum::text,
                partial_date_rule => 'period_end'
            ),
            etl_common.parse_par_date(
                raw_value => d.dodsdat::text,
                partial_date_rule => 'period_end'
            ),
            COALESCE(e.min_emigration_date, DATE '2024-12-31')
        )

    -- data plausiblity: latest immigration must be before death or study end 
    AND (
        i.max_immigration_date IS NULL
        OR i.max_immigration_date <
            LEAST(
                DATE '2024-12-31',
                etl_common.parse_par_date(
                    raw_value => g.doddatum::text,
                    partial_date_rule => 'period_end'
                ),
                etl_common.parse_par_date(
                    raw_value => d.dodsdat::text,
                    partial_date_rule => 'period_end'
                )
            )
    );

/* Create attrition table to show starting point record/person counts and end point record/person_counts,
as well as the number of lopnrs lost due to each exclusion criterion implemented */

DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.PERSON_ATTRITION;
CREATE TABLE {{OUTPUT_SCHEMA}}.PERSON_ATTRITION AS

SELECT 'Number of records in raw grunduppgifter' AS QC_CATEGORY,
COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter

UNION ALL

SELECT 'Number of distinct persons in raw grunduppgifter' AS QC_CATEGORY,
COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter

UNION ALL

SELECT 'Number of records in final PERSON' AS QC_CATEGORY,
COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.person

UNION ALL

SELECT 'Number of persons in final PERSON' AS QC_CATEGORY,
COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.person

UNION ALL

SELECT 'Number of excluded persons due to invalid kon' AS QC_CATEGORY,
COUNT(DISTINCT invalid_person_records.lopnr) AS RECORD_COUNT
FROM
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE kon not in (1,2)
) invalid_person_records
LEFT JOIN
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE kon in (1,2)
) valid_person_records
ON invalid_person_records.lopnr = valid_person_records.lopnr
WHERE valid_person_records IS NULL

UNION ALL

SELECT 'Number of excluded records due to invalid fodelsear' AS QC_CATEGORY,
COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter g
WHERE g.fodelsear < 1900 OR g.fodelsear > 2026 OR g.fodelsear IS NULL

UNION ALL

SELECT 'Number of excluded persons due to invalid fodelsear' AS QC_CATEGORY,
COUNT(DISTINCT invalid_person_records.lopnr) AS RECORD_COUNT
FROM
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.fodelsear < 1900 OR g.fodelsear > 2026 OR g.fodelsear IS NULL
) invalid_person_records
LEFT JOIN
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.fodelsear >= 1900 AND g.fodelsear <= 2026
) valid_person_records
ON invalid_person_records.lopnr = valid_person_records.lopnr
WHERE valid_person_records IS NULL

UNION ALL

SELECT 'Number of excluded records due to invalid aterpnr' AS QC_CATEGORY,
COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter
WHERE aterpnr <> 0

UNION ALL

SELECT 'Number of excluded persons due to invalid aterpnr' AS QC_CATEGORY,
COUNT(DISTINCT invalid_person_records.lopnr) AS RECORD_COUNT
FROM
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.aterpnr <> 0
) invalid_person_records
LEFT JOIN
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.aterpnr = 0
) valid_person_records
ON invalid_person_records.lopnr = valid_person_records.lopnr
WHERE valid_person_records IS NULL

UNION ALL

SELECT 'Number of excluded records due to invalid felsenpnr' AS QC_CATEGORY,
COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter
WHERE felsenpnr <> 0

UNION ALL

SELECT 'Number of excluded persons due to invalid felsenpnr' AS QC_CATEGORY,
COUNT(DISTINCT invalid_person_records.lopnr) AS RECORD_COUNT
FROM
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.felsenpnr <> 0
) invalid_person_records
LEFT JOIN
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.felsenpnr = 0
) valid_person_records
ON invalid_person_records.lopnr = valid_person_records.lopnr
WHERE valid_person_records IS NULL

UNION ALL

SELECT 'Number of excluded records due to invalid samordnr' AS QC_CATEGORY,
COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter
WHERE samordnr <> 0

UNION ALL

SELECT 'Number of excluded persons due to invalid samordnr' AS QC_CATEGORY,
COUNT(DISTINCT invalid_person_records.lopnr) AS RECORD_COUNT
FROM
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.samordnr <> 0
) invalid_person_records
LEFT JOIN
(
  SELECT DISTINCT g.lopnr
  FROM {{INPUT_SCHEMA}}.grunduppgifter g
  WHERE g.samordnr = 0
) valid_person_records
ON invalid_person_records.lopnr = valid_person_records.lopnr
WHERE valid_person_records IS NULL

UNION ALL

SELECT 'Number of excluded persons due to invalid death' AS QC_CATEGORY,
COUNT(DISTINCT invalid_deaths.lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter g
INNER JOIN (
  SELECT DISTINCT lopnr
  FROM {{INPUT_SCHEMA}}.lmed
) l
ON g.lopnr = l.lopnr

LEFT JOIN (
    SELECT DISTINCT lopnr
    FROM cleaned_dors
    WHERE etl_common.parse_par_date(
              raw_value => dodsdat::text,
              partial_date_rule => 'period_end'
          ) <= DATE '2005-07-01'

    UNION ALL

    SELECT DISTINCT lopnr
    FROM {{INPUT_SCHEMA}}.grunduppgifter
    WHERE etl_common.parse_par_date(
              raw_value => doddatum::text,
              partial_date_rule => 'period_end'
          ) <= DATE '2005-07-01'
) invalid_deaths
ON g.lopnr = invalid_deaths.lopnr

UNION ALL

SELECT 
    'Number of excluded persons due to not meeting LMED criteria' AS QC_CATEGORY,
    COUNT(DISTINCT g.lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter g
LEFT JOIN (
    -- persons who have at least one VALID lmed record
    SELECT DISTINCT lopnr
    FROM {{INPUT_SCHEMA}}.lmed
    WHERE otyp NOT IN ('H','L','A')
      AND varutyp NOT IN ('HA','OV')
) valid_lmed
    ON g.lopnr = valid_lmed.lopnr
WHERE valid_lmed.lopnr IS NULL

UNION ALL

SELECT 'Number of persons with birth NOT before death, study end or emigration' AS qc_category,
COUNT(DISTINCT g.lopnr) AS record_count
FROM {{INPUT_SCHEMA}}.grunduppgifter g
INNER JOIN (SELECT DISTINCT lopnr FROM {{INPUT_SCHEMA}}.lmed) l
    ON g.lopnr = l.lopnr
LEFT JOIN cleaned_dors d
    ON g.lopnr = d.lopnr
LEFT JOIN (
    SELECT
        lopnr,
        MIN(CASE WHEN posttyp = 'Utv' THEN etl_common.parse_par_date(datum::text,'exact') END) AS min_emigration_date,
        MAX(CASE WHEN posttyp = 'Inv' THEN etl_common.parse_par_date(datum::text,'exact') END) AS max_immigration_date
    FROM {{INPUT_SCHEMA}}.migrationer
    GROUP BY lopnr
) mig ON g.lopnr = mig.lopnr

WHERE
    g.aterpnr = 0
    AND g.felsenpnr = 0
    AND g.samordnr = 0

    -- fail the birth plausibility rule
    AND MAKE_DATE(g.fodelsear::int, 1, 1) >=
        LEAST(
            DATE '2024-12-31',
            etl_common.parse_par_date(g.doddatum::text,'period_end'),
            etl_common.parse_par_date(d.dodsdat::text,'period_end'),
            COALESCE(mig.min_emigration_date, DATE '2024-12-31')
        )

UNION ALL

SELECT 'Number of persons with latest immigration NOT before death or study end' AS qc_category,
COUNT(DISTINCT g.lopnr) AS record_count
FROM {{INPUT_SCHEMA}}.grunduppgifter g

LEFT JOIN cleaned_dors d
    ON g.lopnr = d.lopnr

LEFT JOIN (
    SELECT
        lopnr,
        MIN(CASE WHEN posttyp = 'Utv' THEN etl_common.parse_par_date(datum::text,'exact') END) AS min_emigration_date,
        MAX(CASE WHEN posttyp = 'Inv' THEN etl_common.parse_par_date(datum::text,'exact') END) AS max_immigration_date
    FROM {{INPUT_SCHEMA}}.migrationer
    GROUP BY lopnr
) mig ON g.lopnr = mig.lopnr

WHERE
    g.aterpnr = 0
    AND g.felsenpnr = 0
    AND g.samordnr = 0

    -- only applies if immigration exists
    AND mig.max_immigration_date IS NOT NULL

    -- fail the immigration plausibility rule
    AND mig.max_immigration_date >=
        LEAST(
            DATE '2024-12-31',
            etl_common.parse_par_date(g.doddatum::text,'period_end'),
            etl_common.parse_par_date(d.dodsdat::text,'period_end')
        );

-- Add persons not observed during study period
INSERT INTO {{OUTPUT_SCHEMA}}.PERSON_ATTRITION (qc_category, record_count)
SELECT
    'Number of persons not observed after 2005-07-01' AS qc_category,
    COUNT(DISTINCT g.lopnr) AS record_count
FROM {{INPUT_SCHEMA}}.grunduppgifter g
WHERE NOT EXISTS (
    SELECT 1
    FROM observed_persons op
    WHERE op.lopnr = g.lopnr
);


-- /* Create table with lopnrs in grunduppgifter and LMED but not in person table */

-- DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.lopnr_missing_person;
-- CREATE TABLE {{OUTPUT_SCHEMA}}.lopnr_missing_person AS
-- SELECT 
--     -- Grunduppgifter 
--     g.lopnr AS lopnr,
--     g.fodelsear,
--     g.doddatum,
--     g.aterpnr,
--     g.felsenpnr,
--     g.samordnr,
--     -- Death table 
--     d.dodsdat,
--     -- Migration table 
--     m.posttyp,
--     m.datum,
--     etl_common.parse_par_date(
--                     raw_value => m.datum::text,
--                     partial_date_rule => 'exact'
--                   ) AS migration_date
-- FROM {{INPUT_SCHEMA}}.grunduppgifter g
-- LEFT JOIN {{OUTPUT_SCHEMA}}.person p
--     ON g.lopnr = p.person_id
-- LEFT JOIN cleaned_dors d
--     ON g.lopnr = d.lopnr
-- LEFT JOIN {{INPUT_SCHEMA}}.migrationer m
--     ON g.lopnr = m.lopnr
-- INNER JOIN (
--     SELECT DISTINCT lopnr
--     FROM {{INPUT_SCHEMA}}.lmed
-- ) l ON g.lopnr = l.lopnr
-- WHERE p.person_id IS NULL
-- ORDER BY g.lopnr, migration_date;
