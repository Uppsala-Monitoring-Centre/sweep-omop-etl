---------------------------------------------------------------
-- Mapping table for patient diagnosis records: ICD10-SE -> ICD10-WHO -> SNOMED mapping
---------------------------------------------------------------
-- Placeholders: {{EXT_VOCAB_SCHEMA}}, {{CDM_SCHEMA}} (schema with the Athena vocabulary tables)

DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.icd10_se_who_snomed_map;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.icd10_se_who_snomed_map AS
SELECT
    REPLACE(v.icd10_se, '.', '') AS icd10_se,
    REPLACE(v.icd10_who_map, '.', '') AS icd10_who_map,
    c.concept_code,
    c.vocabulary_id,
    r.concept_id_1,
    r.concept_id_2,
    s.concept_id AS standard_concept_id,
    r.relationship_id,
    s.standard_concept
FROM {{EXT_VOCAB_SCHEMA}}.icd10se_icd10 v
LEFT JOIN {{CDM_SCHEMA}}.concept c
    ON c.concept_code = v.icd10_who_map
   AND c.vocabulary_id = 'ICD10'
LEFT JOIN {{CDM_SCHEMA}}.concept_relationship r
    ON r.concept_id_1 = c.concept_id
   AND r.relationship_id = 'Maps to'
LEFT JOIN {{CDM_SCHEMA}}.concept s
    ON r.concept_id_2 = s.concept_id
   AND s.standard_concept = 'S';
