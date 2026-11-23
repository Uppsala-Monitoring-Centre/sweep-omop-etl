TRUNCATE {{OUTPUT_SCHEMA}}.cdm_source;

INSERT INTO {{OUTPUT_SCHEMA}}.cdm_source (
  cdm_source_name,
  cdm_source_abbreviation,
  cdm_holder,
  source_description,
  source_documentation_reference,
  cdm_etl_reference,
  source_release_date,
  cdm_release_date,
  cdm_version,
  vocabulary_version,
  cdm_version_concept_id
) 
SELECT
'SWEdish register-based Evidence for Pharmacovigilance database',
'SWEEP',
'Uppsala Monitoring Centre',
'SWEEP is a nationwide Swedish register-based cohort designed to support pharmacovigilance signal management',
'',  -- e.g. link to source data dictionary
'{{CDM_ETL_REFERENCE}}',  -- e.g. release tag with short commit hash
'2025-09-10',  -- when the source data was pulled
CURRENT_DATE,  -- or the date of ETL run
'v5.4',
vocabulary_version,
756265  -- 'OMOP CDM Version 5.4.0'
FROM {{OUTPUT_SCHEMA}}.vocabulary
WHERE vocabulary_id = 'None';



