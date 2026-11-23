---------------------------------------------------------------
-- TPR / LISA mapping table
---------------------------------------------------------------
-- Creates the table for the project's mapping of TPR (grunduppgifter) and LISA
-- variables to OMOP concepts: country of birth, county, civil status, education
-- and disposable income. 02_setup_ext_vocab.R fills it from
-- vocabularies/external/tpr_lisa_external_vocab.csv
-- (vocabularies.external.lisa_tpr_map_csv_path).
-- Read by sql/omop/07_grunduppgifter_lisa_to_observation.sql, which matches on
-- source_variable_description + source_code (unique: checked before loading).
--
-- Placeholders: {{EXT_VOCAB_SCHEMA}}
---------------------------------------------------------------

DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.lisa_tpr_map;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.lisa_tpr_map (
    data_holder TEXT,
    data_source TEXT,
    source_variable TEXT,
    source_variable_description TEXT,
    data_type TEXT,
    source_code TEXT,
    value_source_value TEXT,
    observation_source_value TEXT,
    observation_concept_id INTEGER,
    value_as_concept_id INTEGER,
    value_as_number INTEGER,
    value_as_string TEXT
);
