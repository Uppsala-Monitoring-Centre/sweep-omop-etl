/*
[DRUG_ERA] ETL

This script takes individual drug exposure records from the [DRUG_EXPOSURE] table and combines them into periods of 
continuous exposure (drug eras) at the active ingredient level, allowing for a 30-day persistence window between
dispensations.

Date handling:
Censoring of dates:
-- calculated drug_era_end_dates are censored at the last day of observation
   -> rationale: to avoid spilling over of drug exposures windows after this date

*/


TRUNCATE {{OUTPUT_SCHEMA}}.drug_era;

-- create drug → ingredient mapping
WITH drug_ingredient_map AS MATERIALIZED (
	SELECT c1.concept_id AS drug_concept_id,
		c2.concept_id AS ingredient_concept_id
	FROM 
		{{OUTPUT_SCHEMA}}.concept c1
		INNER JOIN 
		{{OUTPUT_SCHEMA}}.concept_ancestor ca1
		ON c1.concept_id = ca1.descendant_concept_id
		INNER JOIN
		{{OUTPUT_SCHEMA}}.concept c2
		ON c2.concept_id = ca1.ancestor_concept_id
		WHERE c2.standard_concept = 'S'
		AND c2.domain_id = 'Drug'
		AND c2.concept_class_id = 'Ingredient'
		AND c1.standard_concept = 'S'
		AND c1.domain_id = 'Drug'
),
erafied_drug_records AS (
SELECT
-- expand end dates by 30 days
person_id, drug_concept_id, min(start_date) as start_date, (max(end_date) + -1 * 30*INTERVAL'1 day') as end_date
FROM
(
-- create era groups
  select person_id, drug_concept_id, start_date, end_date, sum(is_start) over (partition by person_id, drug_concept_id order by start_date, is_start desc rows unbounded preceding) group_idx
  from (
    select person_id, drug_concept_id, start_date, end_date, 
-- identify where new eras start
      case when max(end_date) over (partition by person_id, drug_concept_id order by start_date rows between unbounded preceding and 1 preceding) >= start_date then 0 else 1 end is_start
    from (
      select de.person_id, 
		drug_ingredient_map.ingredient_concept_id AS drug_concept_id, 
		de.drug_exposure_start_date AS start_date, 
		(de.drug_exposure_end_date + 30*INTERVAL'1 day') AS end_date
      from {{OUTPUT_SCHEMA}}.drug_exposure de
	  INNER JOIN drug_ingredient_map
	  ON de.drug_concept_id = drug_ingredient_map.drug_concept_id
    ) CR
  ) ST
) GR
-- collapse records into eras
group by person_id, drug_concept_id, group_idx
),

-- extract latest observation period end date per person
max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id
)
-- populate [DRUG_ERA]
INSERT INTO {{OUTPUT_SCHEMA}}.drug_era
(
    drug_era_id,
    person_id,
    drug_concept_id,
    drug_era_start_date,
    drug_era_end_date
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY e.person_id, e.drug_concept_id, e.start_date
    ) AS drug_era_id,
    e.person_id,
    e.drug_concept_id,
    e.start_date,
    LEAST(
        e.end_date::date,
        op.observation_period_end_date
    ) AS drug_era_end_date
FROM erafied_drug_records e
INNER JOIN max_observation_period op
    ON op.person_id = e.person_id;

