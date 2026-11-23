/*
[CONDITION_ERA] ETL

This script takes individual condition occurence records from the [CONDITION_OCCURRENCE] table and combines them into periods of 
condition presence (condition eras) using a 30-day persistence window.

Date handling:
Censoring of dates:
-- calculated condition_era_end_dates are censored at the last day of observation
   -> rationale: to avoid spilling over of condition occurrence windows after this date

*/

TRUNCATE {{OUTPUT_SCHEMA}}.condition_era;

WITH erafied_condition_records AS (
SELECT
-- extract condition occurrences (add 30 days to start date to define end)
person_id, condition_concept_id, min(start_date) as start_date, (max(end_date) + -1 * 30*INTERVAL'1 day') as end_date
FROM
(
-- create era groups
  select person_id, condition_concept_id, start_date, end_date, sum(is_start) over (partition by person_id, condition_concept_id order by start_date, is_start desc rows unbounded preceding) group_idx
  from (
    select person_id, condition_concept_id, start_date, end_date, 
-- identify where new eras start    
      case when max(end_date) over (partition by person_id, condition_concept_id order by start_date rows between unbounded preceding and 1 preceding) >= start_date then 0 else 1 end is_start
    from (
      select co.person_id, 
		condition_concept_id, 
		co.condition_start_date AS start_date, 
		(COALESCE(co.condition_end_date, co.condition_start_date) + 30*INTERVAL'1 day') AS end_date
      from {{OUTPUT_SCHEMA}}.condition_occurrence co
    ) CR
  ) ST
) GR
-- collapse records into eras
group by person_id, condition_concept_id, group_idx
),



-- extract latest observation period end date per person
max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id
)
-- populate [CONDITION_ERA]
INSERT INTO {{OUTPUT_SCHEMA}}.condition_era
(
condition_era_id,
person_id,
condition_concept_id,
condition_era_start_date,
condition_era_end_date
)
SELECT ROW_NUMBER() OVER (ORDER BY e.person_id, e.condition_concept_id, e.start_date) AS condition_era_id, 
	e.person_id,
	e.condition_concept_id,
	e.start_date,
	LEAST(
        e.end_date::date,
        op.observation_period_end_date
    ) AS condition_era_end_date
FROM erafied_condition_records e
INNER JOIN max_observation_period op
    ON op.person_id = e.person_id
    WHERE e.condition_concept_id <> 0;