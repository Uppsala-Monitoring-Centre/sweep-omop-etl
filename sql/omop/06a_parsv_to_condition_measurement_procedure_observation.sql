/*
PAR_SV to [CONDITON_OCCURRENCE], [MEASUREMENT], [PROCEDURE_OCCURRENCE] and [OBSERVATION] ETL

Transforms inpatient records from PAR_SV into OMOP CDM clinical event tables. Diagnosis and external cause (ekod) codes are 
mapped to OMOP standard concepts and routed to the appropriate OMOP domain:
[CONDITION_OCCURRENCE] – condition concepts and unmapped diagnoses (condition_concept_id = 0)
[MEASUREMENT] – measurement concepts
[PROCEDURE_OCCURRENCE]– procedure concepts
[OBSERVATION] – all other mapped domains
The script performs the mapping once, stores the intermediate results in a temporary table, and uses this table to 
populate the four OMOP target tables.

Logic: 
- Requires [PERSON] and [OBSERVATION_PERIOD] to exist
- Relies on a custom mapping table (etl_common.get_icd10se_map()) that maps Swedish ICD-10-SE codes to OMOP Standard Concepts 
via WHO ICD-10 concepts.

Date handling:
Incomplete dates:
-- inpatient admission dates (indatuma) are imputed with the mid of the month or year.
   -> rationale: since these dates concern onset events, imputing to the midpoint is preferable to minimize systematic bias in either direction.
Invalid dates:
-- see listed dates
Censoring of dates:
-- admission and discharge dates (indatuma and utdatuma) beyond the last day of observation are discarded
   -> rationale: to avoid entries after this date

*/

TRUNCATE {{OUTPUT_SCHEMA}}.condition_occurrence;
TRUNCATE {{OUTPUT_SCHEMA}}.measurement;
TRUNCATE {{OUTPUT_SCHEMA}}.procedure_occurrence;
TRUNCATE {{OUTPUT_SCHEMA}}.observation;

-- create routed data that serves as input for all tables
DROP TABLE IF EXISTS routed_par_sv;
CREATE TEMP TABLE routed_par_sv AS
-- extract latest observation period end date per person
WITH max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id
),
-- parse admission and discharge dates and remove invalid dates
par_sv_cleaned AS (
    SELECT *
    FROM (
        SELECT
            sv.lopnr,
            etl_common.parse_par_date(
                raw_value => sv.indatuma::text,
                partial_date_rule => 'midpoint'
            ) AS start_date,
            op.observation_period_end_date,
            sv.hdia,
            sv.diagnos,
            sv.ekod1,
            sv.ekod2,
            sv.ekod3,
            sv.ekod4,
            sv.ekod5
        FROM {{INPUT_SCHEMA}}.par_sv sv
        INNER JOIN {{OUTPUT_SCHEMA}}.person p -- restrict to lopnrs in [PERSON]
          ON p.person_id = sv.lopnr
        LEFT JOIN max_observation_period op
          ON op.person_id = sv.lopnr
    ) x
    WHERE start_date IS NOT NULL
      AND start_date <> DATE '1899-12-31'
      AND start_date <= observation_period_end_date
),
-- order diagnosis codes
par_sv_long AS (
    SELECT
        t.lopnr,
        t.start_date,
        d.source_order,
        d.source_kind,
        d.source_value
    FROM par_sv_cleaned t
    CROSS JOIN LATERAL (
        SELECT
            dx.pos::integer AS source_order,
            'diagnosis'::text AS source_kind,
            NULLIF(BTRIM(dx.code), '') AS source_value
        FROM regexp_split_to_table(
            NULLIF(BTRIM(COALESCE(t.diagnos,'')),''),
            '\s+'
        ) WITH ORDINALITY AS dx(code,pos)
-- expand with  ekod codes (ordered following diagnosis codes order)
        UNION ALL
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
                t.ekod5
            ]
        ) WITH ORDINALITY AS ek(code,pos)
    ) d
    WHERE d.source_value IS NOT NULL
)
SELECT
    l.*,
    m.standard_concept_id,
    m.target_domain_id
FROM par_sv_long l
-- map to SNOMED-CT 
LEFT JOIN etl_common.get_icd10se_map() m
    ON m.icd10_se = l.source_value;


-- populate [CONDITION_OCCURRENCE] 
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
    ROW_NUMBER() OVER ()::integer,
    lopnr,
    CASE
        WHEN target_domain_id='Condition'
            THEN standard_concept_id
        WHEN standard_concept_id IS NULL
            THEN 0
    END,
    start_date,
    32824,-- EHR discharge diagnosis
    CASE
        WHEN source_kind='diagnosis'
         AND source_order=1
            THEN 32903 -- primary discharge diagnosis
        ELSE 32909 -- secondary discharge diagnosis
    END,
    source_value
FROM routed_par_sv
WHERE target_domain_id='Condition'
   OR standard_concept_id IS NULL;
   
-- Populate [MEASUREMENT]    
INSERT INTO {{OUTPUT_SCHEMA}}.measurement (
    measurement_id,
    person_id,
    measurement_concept_id,
    measurement_date,
    measurement_type_concept_id,
    measurement_source_value
)
SELECT
    ROW_NUMBER() OVER ()::integer,
    lopnr,
    standard_concept_id,
    start_date,
    32824, -- EHR discharge diagnosis
    source_value
FROM routed_par_sv
WHERE target_domain_id='Measurement';

-- Populate [PROCEDURE_OCCURRENCE]  
INSERT INTO {{OUTPUT_SCHEMA}}.procedure_occurrence (
    procedure_occurrence_id,
    person_id,
    procedure_concept_id,
    procedure_date,
    procedure_type_concept_id,
    procedure_source_value
)
SELECT
    ROW_NUMBER() OVER ()::integer,
    lopnr,
    standard_concept_id,
    start_date,
    32824, -- EHR discharge diagnosis
    source_value
FROM routed_par_sv
WHERE target_domain_id='Procedure';

-- Populate [OBSERVATION]  
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
    ROW_NUMBER() OVER ()::integer,
    lopnr AS person_id,
    standard_concept_id AS observation_concept_id,
    start_date AS observation_date,
    32824 AS observation_type_concept_id, -- EHR discharge diagnosis
    source_value AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    NULL::numeric AS value_as_number,
    NULL::varchar AS value_as_string,
    NULL::varchar AS value_source_value
FROM routed_par_sv

WHERE target_domain_id NOT IN (
        'Condition',
        'Measurement',
        'Procedure'
)
AND standard_concept_id IS NOT NULL;

