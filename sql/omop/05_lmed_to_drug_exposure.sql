/*
[DRUG_EXPOSURE] ETL

Transforms prescription records from LMED to drug exposure data.

Logic: 
- requires [PERSON] and [OBSERVATION_PERIOD] to exist
- uses and intermediate drug mapping file (shared by external source) for mapping unique combinations of 
produkt, subnamn, lform and styrkalf to RxNorm and RxNorm Extension.  
- excludes entries with otyp = H (assistive devices), L (food prescriptions), or A (food products for adults) and
varutyp = HA or OV (non-medicine products)
- ATC is retained as source value for drug exposures

Date handling:
Incomplete dates:
-- dispensing dates (edatum) are fully specified (no need for special date handling)
Censoring of dates:
-- dispensing dates (edatum) beyond the last day of observation are discarded
   -> rationale: to avoid entries after this date
-- calculated drug_exposure_end_dates are censored at the last day of observation
   -> rationale: to avoid spilling over of drug exposures after this date

Potential data quality issues:
- multiple records for same person/same drug/same date (need to consolidate quantity)
- drug concept mapped to different data domain

*/
  
TRUNCATE TABLE {{OUTPUT_SCHEMA}}.drug_exposure;

-- extract latest observation period end date per person
WITH max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id
),
-- prepare valid drug entries and fields
collapsed_valid_drugs AS MATERIALIZED (
	SELECT
	  l.lopnr, 
	  l.atc,
		l.varunr, 
		l.edatum AS drug_exposure_start_date,
-- define drug expsoure end date and quantity
    LEAST(
		l.edatum::DATE + (COALESCE(CASE WHEN l.fddd >= 1 THEN l.fddd ELSE 1 END, 1)::integer - 1),
		op.observation_period_end_date)
		AS drug_exposure_end_date,
		CASE WHEN l.antal > 0 THEN l.antal ELSE 0 END * CASE WHEN l.antnum > 0 THEN l.antnum ELSE 0 end AS quantity
	FROM {{INPUT_SCHEMA}}.lmed l
	LEFT JOIN max_observation_period op    
	  ON op.person_id = l.lopnr
-- omit non-drug records
-- If these filters or the drug concept mapping below change, update
-- sql/mapping_quality/drug/00_shared_setup.sql, which reproduces them.
	WHERE l.otyp not in ('H','L','A')
	AND l.varutyp not in ('HA','OV')
	AND l.edatum <= op.observation_period_end_date
	)

-- populate drug exposure table
INSERT INTO {{OUTPUT_SCHEMA}}.drug_exposure (
	drug_exposure_id,
	person_id,
	drug_concept_id,
	drug_source_concept_id,
	drug_exposure_start_date, 
	drug_exposure_end_date, 
	drug_type_concept_id, 
	quantity,
	drug_source_value
)

SELECT 
	ROW_NUMBER() OVER (ORDER BY d.lopnr, d.varunr, d.drug_exposure_start_date) AS drug_exposure_id,
	d.lopnr AS person_id,
	COALESCE(source_drug_to_concept_map.concept_id,0) AS drug_concept_id,
	source_drug_to_concept_map.source_concept_id AS drug_source_concept_id,
	d.drug_exposure_start_date,
	d.drug_exposure_end_date,
	32825 AS drug_type_concept_id, -- dispensation
	d.quantity,
	d.atc AS drug_source_value -- for now, replace varunr with atc to retain source vocabulary in cdm 
FROM collapsed_valid_drugs d
INNER JOIN {{OUTPUT_SCHEMA}}.person p 
ON p.person_id = d.lopnr -- select lopnrs from person table only
LEFT JOIN 
	(
		SELECT DISTINCT m.drug_source_value AS concept_code,
			NULL::INTEGER AS source_concept_id,
			m.drug_concept_id AS concept_id
-- links external mapping file for drug concept mappings
		FROM {{EXT_VOCAB_SCHEMA}}.varunr_to_concept_final m
		INNER JOIN {{OUTPUT_SCHEMA}}.concept c
		ON m.drug_concept_id = c.concept_id
		AND c.domain_id = 'Drug'
		AND c.standard_concept = 'S'
	) source_drug_to_concept_map 
	/*
	--this part of the query should be replaced once varunr in OHDSI vocabulary with the following code:
	(
		SELECT source_vocabulary.concept_code,
			source_vocabulary.concept_id AS source_concept_id,
			c1.concept_id
		FROM
		(SELECT concept_code, concept_id
		FROM {{OUTPUT_SCHEMA}}.concept
		WHERE vocabulary_id = 'varunr'
		) source_vocabulary
		LEFT JOIN {{OUTPUT_SCHEMA}}.concept_relationship cr1
		ON source_vocabulary.concept_id = cr1.concept_id_1
		LEFT JOIN {{OUTPUT_SCHEMA}}.concept c1
		ON cr1.concept_id_2 = c1.concept_id
		AND c1.domain_id = 'Drug'
		AND c1.standard_concept = 'S'
	) source_drug_to_concept_map
	*/
ON d.varunr = source_drug_to_concept_map.concept_code;

/* Create attrition table to show starting point record/person counts and end point record/person_counts,
as well as the number of lopnrs lost due to each exclusion criterion implemented */


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.DRUG_EXPOSURE_ATTRITION;
CREATE TABLE {{OUTPUT_SCHEMA}}.DRUG_EXPOSURE_ATTRITION AS

SELECT 'Number of records in raw lmed' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.lmed

UNION ALL

SELECT 'Number of persons in raw lmed' AS QC_CATEGORY,
	COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.lmed

UNION ALL

SELECT 'Number of records in lmed from invalid persons' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.lmed
LEFT JOIN {{OUTPUT_SCHEMA}}.person
ON lmed.lopnr = person.person_id
WHERE person.person_id IS NULL

UNION ALL

SELECT 'Number of records in lmed from non-drug types (otyp HLA, varutyp HA)' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.lmed
WHERE otyp in ('H','L','A') OR varutyp in ('HA', 'OV')

UNION ALL

SELECT 'Number of records collapsed due to same person/same drug/same date' AS QC_CATEGORY,
	SUM(num_records - 1) AS num_extra_records
FROM	
(	
SELECT lopnr, varunr, edatum, COUNT(lopnr) AS num_records
FROM {{INPUT_SCHEMA}}.lmed
GROUP BY lopnr, varunr, edatum
) t1
WHERE num_records > 1

UNION ALL

SELECT 'Number of records in drug_exposure' AS QC_CATEGORY,
	COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.drug_exposure

UNION ALL

SELECT 'Number of persons in drug_exposure' AS QC_CATEGORY,
	COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.drug_exposure
;


/* Check that identifies lopnrs with drug expsosure records where the start date, end date or the interval of exposure does not falls within an observation period */

-- DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.drug_exposure_observation_check;
-- CREATE TABLE {{OUTPUT_SCHEMA}}.drug_exposure_observation_check AS

-- WITH drug_exposure_check AS (
--     SELECT
--         de.person_id,
--         de.drug_exposure_id,
--         de.drug_exposure_start_date,
--         de.drug_exposure_end_date,
--         /* Start date falls in at least one observation period */
--         EXISTS (
--             SELECT 1
--             FROM {{OUTPUT_SCHEMA}}.observation_period op
--             WHERE op.person_id = de.person_id
--               AND de.drug_exposure_start_date BETWEEN
--                     op.observation_period_start_date
--                 AND op.observation_period_end_date
--         ) AS start_in_observation_period,
--         /* End date falls in at least one observation period */
--         EXISTS (
--             SELECT 1
--             FROM {{OUTPUT_SCHEMA}}.observation_period op
--             WHERE op.person_id = de.person_id
--               AND de.drug_exposure_end_date BETWEEN
--                     op.observation_period_start_date
--                 AND op.observation_period_end_date
--         ) AS end_in_observation_period,
--         /* Entire drug exposure interval contained in a single observation period */
--         EXISTS (
--             SELECT 1
--             FROM {{OUTPUT_SCHEMA}}.observation_period op
--             WHERE op.person_id = de.person_id
--               AND de.drug_exposure_start_date >= op.observation_period_start_date
--               AND de.drug_exposure_end_date   <= op.observation_period_end_date
--         ) AS interval_contained_in_single_op
--     FROM {{OUTPUT_SCHEMA}}.drug_exposure de
-- )

-- SELECT
--     c.person_id,
--     c.drug_exposure_id,
--     op.observation_period_id,
--     op.observation_period_start_date,
--     op.observation_period_end_date,
--     c.drug_exposure_start_date,
--     c.drug_exposure_end_date,
--     c.start_in_observation_period,
--     c.end_in_observation_period,
--     c.interval_contained_in_single_op
-- FROM drug_exposure_check c
-- LEFT JOIN {{OUTPUT_SCHEMA}}.observation_period op
--     ON op.person_id = c.person_id
-- WHERE
--       NOT c.start_in_observation_period
--    OR NOT c.end_in_observation_period
--    OR NOT c.interval_contained_in_single_op
-- ORDER BY
--     c.person_id,
--     c.drug_exposure_start_date,
--     op.observation_period_start_date;