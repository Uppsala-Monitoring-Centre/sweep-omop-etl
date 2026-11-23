---------------------------------------------------------------
--Mapping table for death records: ICD10-WHO -> SNOMED
---------------------------------------------------------------
-- Placeholders: {{EXT_VOCAB_SCHEMA}}, {{CDM_SCHEMA}} (schema with the Athena vocabulary tables)

DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.icd10_who_snomed_map;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.icd10_who_snomed_map AS
SELECT
    REPLACE(c.concept_code, '.', '') AS icd10_who,
    c.concept_code,
    c.vocabulary_id,
    r.concept_id_1,
    r.concept_id_2,
    s.concept_id AS standard_concept_id,
    r.relationship_id,
    s.standard_concept
FROM {{CDM_SCHEMA}}.concept c
LEFT JOIN {{CDM_SCHEMA}}.concept_relationship r
    ON r.concept_id_1 = c.concept_id
   AND r.relationship_id = 'Maps to'
LEFT JOIN {{CDM_SCHEMA}}.concept s
    ON r.concept_id_2 = s.concept_id
   AND s.standard_concept = 'S'
WHERE c.vocabulary_id = 'ICD10';
