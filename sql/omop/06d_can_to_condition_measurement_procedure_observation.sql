/*
CAN to [CONDITION_OCCURRENCE], [MEASUREMENT], [PROCEDURE_OCCURRENCE] and [OBSERVATION] ETL

Transforms cancer records from CAN into OMOP CDM clinical event tables.  
icdo10 (International Classification of Diseases for Oncology) and snomed10 (Systematized Nomenclature of Medicine - Oncology)
codes mapped to OMOP standard concepts and routed to the appropriate OMOP domain: 
[CONDITION_OCCURRENCE], – condition concepts and unmapped diagnoses (condition_concept_id = 0)
[MEASUREMENT] – measurement concepts
[PROCEDURE_OCCURRENCE] – procedure concepts
[OBSERVATION] – all other mapped domains
The script performs the mapping once, stores the intermediate results in a temporary table and uses this table to 
populate the OMOP target tables.

Logic: 
- Requires PERSON and OBSERVATION_PERIOD to exist
- ICD7 is retained as source value for cancer diagnoses as this field is virtually complete for all cancer diagnoses, while
missigness on icdo10 and snomed10 is ~10%.

Date handling:
Incomplete dates:
-- diagnosis dates (diadat) are imputed with the mid of the month or year.
   -> rationale: since these dates concern onset events, imputing to the midpoint is preferable to minimize systematic bias in either direction.
Invalid dates:
-- see dates listed
Censoring of dates:
-- diagnosis dates are censored at the latest observation_period_end_date per person
   -> rationale: to avoid entries after data lock point

*/

-- create routed data that serves as input for all tables
DROP TABLE IF EXISTS can_routed;
CREATE TEMP TABLE can_routed AS
-- extract latest observation period end date per person
WITH max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id),
-- parse cancer diagnosis dates
can_long AS (
    SELECT DISTINCT
        t.lopnr::integer AS person_id,
        etl_common.parse_par_date(
            raw_value => t.diadat::text,
            partial_date_rule => 'midpoint'
        ) AS event_date,
        UPPER(
            BTRIM(
                CONCAT(
                    SUBSTRING(t.snomedo10 FROM 1 FOR 4), '/',
                    SUBSTRING(t.snomedo10 FROM 5 FOR 1), '-',
                    SUBSTRING(t.icdo10 FROM 1 FOR 3), '.',
                    SUBSTRING(t.icdo10 FROM 4 FOR 1)
                )
            )
        ) AS source_value,
        32835::integer AS type_concept_id,   -- EHR pathology report
        32893::integer AS status_concept_id, -- confirmed diagnosis
        t.icd7,
        op.observation_period_end_date
    FROM {{INPUT_SCHEMA}}.can t
    INNER JOIN {{OUTPUT_SCHEMA}}.person p
        ON p.person_id = t.lopnr::integer
    LEFT JOIN max_observation_period op
        ON op.person_id = t.lopnr::integer)
SELECT
    l.person_id,
    l.event_date,
    l.source_value,
    l.type_concept_id,
    l.status_concept_id,
    m.standard_concept_id,
    m.target_domain_id,
        l.icd7
FROM can_long l
LEFT JOIN etl_common.get_icdo3_map() m
    ON m.icdo3 = l.source_value
WHERE l.event_date IS NOT NULL
  AND l.event_date <= l.observation_period_end_date
        AND l.icd7 IS NOT NULL
        AND l.source_value IS NOT NULL;

-- populate [CONDITION_OCCURRENCE]
WITH current_max AS (
    SELECT COALESCE(MAX(condition_occurrence_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.condition_occurrence
)
INSERT INTO {{OUTPUT_SCHEMA}}.condition_occurrence (
    condition_occurrence_id,
    person_id,
    condition_concept_id,
    condition_start_date,
    condition_type_concept_id,
    condition_status_concept_id,
    condition_source_value
)
SELECT
    current_max.max_id
    + ROW_NUMBER() OVER (
        ORDER BY person_id, event_date, icd7
    ) AS condition_occurrence_id,
    person_id,
    CASE
        WHEN target_domain_id = 'Condition'
            THEN standard_concept_id::integer
        WHEN standard_concept_id IS NULL
            THEN 0
    END AS condition_concept_id,
    event_date::date,
    type_concept_id,
    status_concept_id,
    icd7
FROM can_routed

CROSS JOIN current_max
WHERE target_domain_id = 'Condition'
   OR standard_concept_id IS NULL;

-- Populate [MEASUREMENT]   
WITH current_max AS (
    SELECT COALESCE(MAX(measurement_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.measurement
)
INSERT INTO {{OUTPUT_SCHEMA}}.measurement (
    measurement_id,
    person_id,
    measurement_concept_id,
    measurement_date,
    measurement_type_concept_id,
    measurement_source_value
)
SELECT
    current_max.max_id
    + ROW_NUMBER() OVER (
        ORDER BY person_id, event_date, icd7
    ) AS measurement_id,

    person_id,
    standard_concept_id::integer,
    event_date::date,
    type_concept_id,
    icd7
FROM can_routed
CROSS JOIN current_max
WHERE target_domain_id = 'Measurement';

-- Populate [PROCEDURE_OCCURRENCE]   
WITH current_max AS (
    SELECT COALESCE(MAX(procedure_occurrence_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.procedure_occurrence
)
INSERT INTO {{OUTPUT_SCHEMA}}.procedure_occurrence (
    procedure_occurrence_id,
    person_id,
    procedure_concept_id,
    procedure_date,
    procedure_type_concept_id,
    procedure_source_value
)
SELECT
    current_max.max_id
    + ROW_NUMBER() OVER (
        ORDER BY person_id, event_date, icd7
    ) AS procedure_occurrence_id,

    person_id,
    standard_concept_id::integer,
    event_date::date,
    type_concept_id,
    icd7
FROM can_routed
CROSS JOIN current_max
WHERE target_domain_id = 'Procedure';

-- Populate [OBSERVATION]   
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.observation
)
INSERT INTO {{OUTPUT_SCHEMA}}.observation (
    observation_id,
    person_id,
    observation_concept_id,
    observation_date,
    observation_type_concept_id,
    observation_source_value,
    value_as_concept_id,
    value_as_number,
    value_as_string,
    value_source_value
)
SELECT
    current_max.max_id
    + ROW_NUMBER() OVER (
        ORDER BY person_id, event_date, icd7
    ) AS observation_id,

    person_id as person_id,
    standard_concept_id::integer as observation_concept_id,
    event_date::date as observation_date,
    type_concept_id as observation_type_concept_id,
    icd7 as observation_source_value,
    NULL::integer AS value_as_concept_id,
    NULL::numeric AS value_as_number,
    NULL::varchar AS value_as_string,
    NULL::varchar AS value_source_value

FROM can_routed
CROSS JOIN current_max
WHERE target_domain_id NOT IN ('Condition', 'Measurement', 'Procedure')
  AND standard_concept_id IS NOT NULL;
  
  
/* Check that identifies condition records where the condition_start_date does not fall within any observation period */

-- DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.condition_occurrence_observation_check;
-- CREATE TABLE {{OUTPUT_SCHEMA}}.condition_occurrence_observation_check AS

-- WITH condition_check AS (
--     SELECT
--         co.person_id,
--         co.condition_occurrence_id,
--         co.condition_start_date,
--         co.condition_type_concept_id,
--         EXISTS (
--             SELECT 1
--             FROM {{OUTPUT_SCHEMA}}.observation_period op
--             WHERE op.person_id = co.person_id
--               AND co.condition_start_date BETWEEN
--                     op.observation_period_start_date
--                 AND op.observation_period_end_date
--         ) AS start_in_observation_period
--     FROM {{OUTPUT_SCHEMA}}.condition_occurrence co
-- )

-- SELECT
--     c.person_id,
--     op.observation_period_id,
--     op.observation_period_start_date,
--     op.observation_period_end_date,
--     c.condition_occurrence_id,
--     c.condition_start_date,
--     c.condition_type_concept_id
-- FROM condition_check c
-- LEFT JOIN {{OUTPUT_SCHEMA}}.observation_period op
--     ON op.person_id = c.person_id
-- WHERE NOT c.start_in_observation_period
-- ORDER BY
--     c.person_id,
--     c.condition_start_date,
--     op.observation_period_start_date;