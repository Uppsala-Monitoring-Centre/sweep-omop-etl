/*
PAR_OV to [CONDITION_OCCURRENCE], [MEASUREMENT], [PROCEDURE_OCCURRENCE] and [OBSERVATION] ETL

Transforms outpatient records from PAR_OV into OMOP CDM clinical event tables. Diagnosis and external cause (ekod) codes are 
mapped to OMOP standard concepts and routed to the appropriate OMOP domain:
[CONDITION_OCCURRENCE] – condition concepts and unmapped diagnoses (condition_concept_id = 0)
[MEASUREMENT] – measurement concepts
[PROCEDURE_OCCURRENCE] – procedure concepts
observation – all other mapped domains
The script performs the mapping once, stores the intermediate results in a temporary table, and uses this table to 
populate the four OMOP target tables.

Logic: 
-- requires PERSON and OBSERVATION_PERIOD to exist 
-- relies on a custom mapping table (etl_common.get_icd10se_map()) that maps Swedish ICD-10-SE codes to OMOP Standard Concepts 
via WHO ICD-10 concepts.

Date handling:
Incomplete dates:
-- outpatient visit dates (indatuma) dates are imputed with the mid of the month or year.
   -> rationale: since these dates concern onset events, imputing to the midpoint is preferable to minimize systematic bias in either direction.
Invalid dates:
-- see listed dates
Censoring of dates:
-- admission dates beyond the last day of observation are discarded
   -> rationale: to avoid entries after this date

*/


-- create temporary table that serves as input for all tables
DROP TABLE IF EXISTS routed_par_ov;
CREATE TEMP TABLE routed_par_ov AS
-- extract latest observation period end date per person
WITH max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id

),
-- parse admission and discharge dates and remove invalid dates
par_ov_cleaned AS (
    SELECT
        ov.lopnr,
        etl_common.parse_par_date(
            raw_value => ov.indatuma::text,
            partial_date_rule => 'midpoint'
        ) AS start_date,
        op.observation_period_end_date,
        ov.hdia,
        ov.diagnos,
        ov.ekod1,
        ov.ekod2,
        ov.ekod3,
        ov.ekod4,
        ov.ekod5,
        ov.ekod6,
        ov.ekod7
    FROM {{INPUT_SCHEMA}}.par_ov ov
    INNER JOIN {{OUTPUT_SCHEMA}}.person p -- restrict to lopnrs in [PERSON]
      ON p.person_id = ov.lopnr
    LEFT JOIN max_observation_period op
      ON op.person_id = ov.lopnr
    WHERE ov.indatuma NOT IN (
        '060201',
        '060710',
        '10060113',
        '1320',
        '51200102',
        '22060914',
        '21200601',
        '20600526'
    )
),
-- apply filters
par_ov_filtered AS (
    SELECT *
    FROM par_ov_cleaned
    WHERE start_date IS NOT NULL
      AND start_date <= observation_period_end_date -- discard records after latest observation period end date
),
-- order diagnosis codes
par_ov_long AS (
    SELECT
        t.lopnr,
        t.start_date,
        d.source_order,
        d.source_kind,
        d.source_value
    FROM par_ov_filtered t
    CROSS JOIN LATERAL (
        -- diagnosis codes
        SELECT
            dx.pos::integer AS source_order,
            'diagnosis'::text AS source_kind,
            NULLIF(BTRIM(dx.code),'') AS source_value
        FROM regexp_split_to_table(
            NULLIF(BTRIM(COALESCE(t.diagnos,'')),''),
            '\s+'
        ) WITH ORDINALITY AS dx(code,pos)
        
        UNION ALL
-- expand with ekod codes (ordered following diagnosis codes)
        SELECT
            100 + ek.pos::integer,
            'ekod',
            NULLIF(BTRIM(ek.code),'')
        FROM UNNEST(
            ARRAY[
                t.ekod1,
                t.ekod2,
                t.ekod3,
                t.ekod4,
                t.ekod5,
                t.ekod6,
                t.ekod7
            ]
        ) WITH ORDINALITY AS ek(code,pos)
    ) d
    WHERE d.source_value IS NOT NULL
)
SELECT
    l.*,
    m.standard_concept_id,
    m.target_domain_id
FROM par_ov_long l
-- map to SNOMED-CT 
LEFT JOIN etl_common.get_icd10se_map() m
    ON m.icd10_se = l.source_value;


-- populate [CONDITION_OCCURRENCE]
WITH current_max AS (
    SELECT COALESCE(MAX(condition_occurrence_id),0) AS max_id
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
    current_max.max_id + ROW_NUMBER() OVER ()::integer,
    lopnr,
    CASE
        WHEN target_domain_id='Condition'
            THEN standard_concept_id
        WHEN standard_concept_id IS NULL
            THEN 0
    END,
    start_date,
    32879, -- registry
    CASE
        WHEN source_kind='diagnosis'
         AND source_order=1
            THEN 32902 -- primary diagnosis
        ELSE 32908 -- secondary diagnosis
    END,
    source_value
FROM routed_par_ov
CROSS JOIN current_max
WHERE target_domain_id='Condition'
   OR standard_concept_id IS NULL;


-- populate [MEASUREMENT]
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
    current_max.max_id + ROW_NUMBER() OVER ()::integer,
    lopnr::integer,
    standard_concept_id::integer,
    start_date,
    32879, -- registry
    source_value
FROM routed_par_ov
CROSS JOIN current_max
WHERE target_domain_id = 'Measurement';


-- populate [PROCEDURE_OCCURRENCE]
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
    current_max.max_id + ROW_NUMBER() OVER ()::integer,
    lopnr::integer,
    standard_concept_id::integer,
    start_date,
    32879, -- registry
    source_value
FROM routed_par_ov
CROSS JOIN current_max
WHERE target_domain_id = 'Procedure';


-- populate [OBSERVATION]
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
    current_max.max_id + ROW_NUMBER() OVER ()::integer,
    lopnr::integer AS person_id,
    standard_concept_id::integer AS observation_concept_id,
    start_date AS observation_date,
    32879 AS observation_type_concept_id, -- registry
    source_value AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    NULL::numeric AS value_as_number,
    NULL::varchar AS value_as_string,
    NULL::varchar AS value_source_value
FROM routed_par_ov
CROSS JOIN current_max
WHERE target_domain_id NOT IN ('Condition', 'Measurement', 'Procedure')
  AND standard_concept_id IS NOT NULL;