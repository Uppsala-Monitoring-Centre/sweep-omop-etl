/*
DORS to [CONDITION_OCCURRENCE], [MEASUREMENT], [PROCEDURE_OCCURRENCE] and [OBSERVATION] ETL

Transforms cause of death records from DORS into OMOP CDM clinical event tables. Underlying (ulorsak) and contributing (morsak) 
cause of death codes are mapped to OMOP standard concepts and routed to the appropriate OMOP domain: 
[CONDITION_OCCURRENCE], – condition concepts and unmapped diagnoses (condition_concept_id = 0)
[MEASUREMENT] – measurement concepts
[PROCEDURE_OCCURRENCE] – procedure concepts
[OBSERVATION] – all other mapped domains
The script performs the mapping once, stores the intermediate results in a temporary table, and uses this table to 
populate theOMOP target tables.

Logic: 
- Requires PERSON, DEATH and OBSERVATION_PERIOD to exist

Date handling:
Incomplete dates:
-- death dates are imputed with the end of the month or year.
   -> rationale: since these dates concern hard endpoints, imputating to the end is preferable to preserve valid event ordering and avoid erroneously censoring individuals too early.
Censoring of dates:
-- death dates beyond the last day of observation are discarded
   -> rationale: to avoid entries after this date

*/

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
-- create routed data that serves as input for all tables
DROP TABLE IF EXISTS dors_routed;
CREATE TEMP TABLE dors_routed AS
-- extract latest observation period end date per person
WITH max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id),
-- parse death records
dors_long AS (
    SELECT
        d.lopnr::integer AS person_id,
        e.death_date AS event_date, -- extract min death date encountered in dors and grunduppgifter as in [DEATH]
        32815::integer AS type_concept_id, -- death certificate
        CASE
            WHEN dx.pos = 1 THEN 32911 -- underlying cause of death (position 1)
            ELSE 32891                 -- contributing cause of death (postion 2+)
        END::integer AS status_concept_id,
        dx.source_value::text AS source_value,
        dx.code_clean,
        dx.pos
    FROM cleaned_dors d
    INNER JOIN {{OUTPUT_SCHEMA}}.person p  -- restrict to lopnrs in [PERSON]
        ON p.person_id = d.lopnr::integer
    LEFT JOIN max_observation_period op
        ON op.person_id = d.lopnr::integer        
    LEFT JOIN {{OUTPUT_SCHEMA}}.death e
        ON e.person_id = d.lopnr::integer
    CROSS JOIN LATERAL (
        SELECT
            pos,
            NULLIF(btrim(code::text), '') AS source_value,
            regexp_replace(
                upper(NULLIF(btrim(code::text), '')),
                '[^A-Z0-9]',
                '',
                'g'
            ) AS code_clean
        FROM unnest(ARRAY[
            d.ulorsak,
            d.morsak1,  d.morsak2,  d.morsak3,  d.morsak4,  d.morsak5,
            d.morsak6,  d.morsak7,  d.morsak8,  d.morsak9,  d.morsak10,
            d.morsak11, d.morsak12, d.morsak13, d.morsak14, d.morsak15,
            d.morsak16, d.morsak17, d.morsak18, d.morsak19, d.morsak20,
            d.morsak21, d.morsak22, d.morsak23, d.morsak24, d.morsak25,
            d.morsak26, d.morsak27, d.morsak28, d.morsak29, d.morsak30,
            d.morsak31, d.morsak32, d.morsak33, d.morsak34, d.morsak35,
            d.morsak36, d.morsak37, d.morsak38, d.morsak39, d.morsak40,
            d.morsak41, d.morsak42, d.morsak43, d.morsak44, d.morsak45,
            d.morsak46, d.morsak47, d.morsak48,
            d.kap19
        ]) WITH ORDINALITY AS u(code, pos)
    ) dx
    WHERE e.death_date IS NOT NULL
      AND e.death_date <= op.observation_period_end_date -- discard records after latest observation period end date
      AND dx.source_value IS NOT NULL
)
SELECT
    l.person_id,
    l.event_date,
    l.type_concept_id,
    l.status_concept_id,
    l.source_value,
    l.code_clean,
    l.pos,
    m.standard_concept_id,
    m.target_domain_id
FROM dors_long l
--map to SNOMED-CT
LEFT JOIN etl_common.get_icd10_map() m 
    ON m.code = l.code_clean;

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
    current_max.max_id +
    ROW_NUMBER() OVER (
        ORDER BY person_id,event_date,pos,source_value
    ),
    person_id,
    CASE
        WHEN target_domain_id = 'Condition'
            THEN standard_concept_id::integer
        ELSE 0
    END,
    event_date::date,
    type_concept_id,
    status_concept_id,
    source_value
FROM dors_routed
CROSS JOIN current_max
WHERE target_domain_id = 'Condition'
   OR standard_concept_id IS NULL;

-- populate [MEASUREMENT]
WITH current_max AS (
    SELECT COALESCE(MAX(measurement_id),0) AS max_id
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
    current_max.max_id +
    ROW_NUMBER() OVER (
        ORDER BY person_id,event_date,pos,source_value
    ),
    person_id,
    standard_concept_id,
    event_date::date,
    type_concept_id,
    source_value
FROM dors_routed
CROSS JOIN current_max
WHERE target_domain_id = 'Measurement';

-- populate [PROCEDURE_OCCURRENCE]
WITH current_max AS (
    SELECT COALESCE(MAX(procedure_occurrence_id),0) AS max_id
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
    current_max.max_id +
    ROW_NUMBER() OVER (
        ORDER BY person_id,event_date,pos,source_value
    ),
    person_id,
    standard_concept_id,
    event_date::date,
    type_concept_id,
    source_value
FROM dors_routed
CROSS JOIN current_max
WHERE target_domain_id = 'Procedure';

-- populate [OBSERVATION]
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id),0) AS max_id
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
    current_max.max_id +
    ROW_NUMBER() OVER (
        ORDER BY person_id,event_date,pos,source_value
    ),
    person_id AS person_id,
    standard_concept_id AS observation_concept_id,
    event_date::date AS observation_date,
    type_concept_id AS observation_type_concept_id,
    source_value AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    NULL::numeric AS value_as_number,
    NULL::varchar AS value_as_string,
    NULL::varchar AS value_source_value
FROM dors_routed
CROSS JOIN current_max
WHERE target_domain_id NOT IN (
        'Condition',
        'Measurement',
        'Procedure'
      )
  AND standard_concept_id IS NOT NULL;
