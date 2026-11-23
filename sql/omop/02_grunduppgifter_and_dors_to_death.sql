/*
[DEATH] ETL

Logic:
- Requires PERSON to exist
- Takes the earliest death date encountered in either the Total Population Register (grunduppgifter) or the
Cause of Death Register (dors). Death dates after 31-12-2024 are discarded to prevent the inclusion of events in unobserved time.
-The underlying cause of death (ulorsak) is extracted from dors and its source code (ICD10-WHO) is mapped
to the OMOP standard concept (SNOMED-CT).

Date handling:
Incomplete dates:
-- death dates (dodsdat in dors and doddatum in grunduppgifter) are imputed with the end of the month or year.
   -> rationale: for hard endpoints imputing to end of month/year is preferable to preserve valid event ordering and avoid erroneously censoring persons too early.
Censoring of dates:
-- death dates (dodsat and dors) beyond 31-12-2024 are discarded
   -> rationale: to avoid entries after the data lock point

Potential data quality issues:
- a person could have multiple records in grunduppgifter OR dors
- a person could have multiple standard concepts mapped from source cause of death

*/

TRUNCATE {{OUTPUT_SCHEMA}}.death;

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

-- parse death records from dors
DROP TABLE IF EXISTS death_dates;
CREATE TEMP TABLE death_dates AS
SELECT
    d.lopnr,
    d.ulorsak::TEXT AS cause_source_value,
    etl_common.parse_par_date(
        raw_value => d.dodsdat::text,
        partial_date_rule => 'period_end'
    ) AS dodsdat
FROM cleaned_dors d;

-- build ICD‑10 → OMOP standard concept (SNOMED-CT) mapping
WITH icd10_map AS MATERIALIZED (
    SELECT
        c_source.concept_code AS icd10,
        MIN(c_standard.concept_id) AS cause_concept_id
    FROM {{OUTPUT_SCHEMA}}.concept c_source
    JOIN {{OUTPUT_SCHEMA}}.concept_relationship cr
        ON cr.concept_id_1 = c_source.concept_id
       AND cr.relationship_id = 'Maps to'
       AND cr.invalid_reason IS NULL
    JOIN {{OUTPUT_SCHEMA}}.concept c_standard
        ON c_standard.concept_id = cr.concept_id_2
       AND c_standard.standard_concept = 'S'
    WHERE c_source.vocabulary_id = 'ICD10'
    GROUP BY c_source.concept_code
)

-- populate death table
INSERT INTO {{OUTPUT_SCHEMA}}.death
(
    person_id,
    death_date, 
    death_type_concept_id,
    cause_concept_id,
    cause_source_value
)
SELECT 
    CAST(valid_deaths.lopnr AS BIGINT) AS person_id,
    valid_deaths.death_date,
    32815 AS death_type_concept_id,    -- death certificate
    CASE 
        WHEN icd10.cause_concept_id IS NOT NULL
        THEN icd10.cause_concept_id
        ELSE NULL 
    END AS cause_concept_id,
    d.cause_source_value
FROM (
-- collect min death date from dors and grunduppgifter
    SELECT lopnr, MIN(death_date) AS death_date
    FROM (
        -- deaths from grunduppgifter
        SELECT g.lopnr, MIN(etl_common.parse_par_date(
        raw_value => g.doddatum::text,
        partial_date_rule => 'period_end')) AS death_date
        FROM {{INPUT_SCHEMA}}.grunduppgifter g
        INNER JOIN {{OUTPUT_SCHEMA}}.person p -- select lopnrs from person table only
            ON g.lopnr = p.person_id
        WHERE g.doddatum IS NOT NULL
        GROUP BY g.lopnr

        UNION ALL

        -- deaths from dors
        SELECT d.lopnr, MIN(d.dodsdat) AS death_date
        FROM death_dates d
        INNER JOIN {{OUTPUT_SCHEMA}}.person p -- select lopnrs from person table only
            ON d.lopnr = p.person_id
        WHERE d.dodsdat IS NOT NULL
        GROUP BY d.lopnr
    ) candidate_deaths
    GROUP BY lopnr
    HAVING MIN(death_date) IS NOT NULL   -- ensure no null death_date
    AND MIN(death_date) <= DATE '2024-12-31' -- to avoid entries after data lock point
) valid_deaths
-- join back to cause of death and map ICD‑10
LEFT JOIN death_dates d
    ON valid_deaths.lopnr = d.lopnr
   AND d.dodsdat IS NOT NULL
LEFT JOIN icd10_map icd10
    ON d.cause_source_value = REPLACE(icd10.icd10, '.','');

/* Create attrition table to show starting point record/person counts and end point record/person_counts,
as well as the number of lopnrs lost due to each exclusion criterion implemented */

DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.DEATH_ATTRITION;

CREATE TABLE {{OUTPUT_SCHEMA}}.DEATH_ATTRITION AS
SELECT 'Number of records in raw grunduppgifter with death' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter
WHERE doddatum IS NOT NULL

UNION ALL

SELECT 'Number of persons in raw grunduppgifter with death' AS QC_CATEGORY,
	COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter
WHERE doddatum IS NOT NULL

UNION ALL

SELECT 'Number of records in raw dors' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM cleaned_dors

UNION ALL

SELECT 'Number of persons in raw dors' AS QC_CATEGORY,
	COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM cleaned_dors

UNION ALL

SELECT 'Number of distinct persons in raw dors or grunduppgifter with death' AS QC_CATEGORY,
	COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM 
(
SELECT DISTINCT lopnr FROM {{INPUT_SCHEMA}}.grunduppgifter WHERE doddatum IS NOT NULL
UNION ALL
SELECT DISTINCT lopnr FROM cleaned_dors
) persons_w_death

UNION ALL

SELECT 'Number of records in OMOP.DEATH' AS QC_CATEGORY,
	COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.death

UNION ALL

SELECT 'Number of persons in OMOP.DEATH' AS QC_CATEGORY,
	COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.death

UNION ALL


SELECT 'Number of persons in raw dors with invalid date' AS QC_CATEGORY,
	COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM death_dates
WHERE dodsdat < '2005-07-01'


UNION ALL

SELECT 'Number of persons in raw dors with invalid person' AS QC_CATEGORY,
    COUNT(DISTINCT d.lopnr) AS RECORD_COUNT
FROM cleaned_dors d
LEFT JOIN {{OUTPUT_SCHEMA}}.person p
ON d.lopnr = p.person_id
WHERE p.person_id IS NULL

UNION ALL

SELECT 'Number of persons in raw grunduppgifter with invalid person' AS QC_CATEGORY,
	COUNT(DISTINCT g.lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter g
LEFT JOIN {{OUTPUT_SCHEMA}}.person
ON g.lopnr = person.person_id
WHERE person.person_id IS NULL AND g.doddatum IS NOT NULL

UNION ALL

SELECT 'Number of persons in raw grunduppgifter with invalid date' AS QC_CATEGORY,
	COUNT(DISTINCT g.lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.grunduppgifter g
WHERE g.doddatum < 20050701

;
