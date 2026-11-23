# Vocabulary and Concept Mappings

The ETL uses standard OMOP vocabularies together with Swedish source-code mappings. The detailed field-level decisions are in [SWEEP_ETL_design.xlsx](sweep_ETL_design.xlsx); the executable setup and mapping SQL is under `sql/external_vocabularies/` and `sql/omop/`.

## Standard OMOP vocabularies

The CDM setup loads Athena vocabulary files into the configured OMOP schema. These tables support concept lookup, domain validation, standard-concept selection, and relationship traversal.

The setup is performed by `R/orchestrators/01_setup_CDM.R` using the configured OMOP CDM definition and the `CommonDataModel` package. At the start of each ETL run, the Athena release is read from the loaded `vocabulary` table's `None` row and recorded as `athena_vocabulary_version` in `metadata.etl_runs` (using the configured metadata schema). The metadata SQL also reads that row for `cdm_source.vocabulary_version`; the vocabulary should not be changed during a run. A missing, duplicate, or empty release stops the run.

External vocabulary setup records each load in `metadata.external_vocab_loads` (using the configured metadata schema): the external schema, source file paths, SHA-256 checksums, timestamps, and status. Checksums are calculated from staged copies that are used for loading. The OMOP ETL records the schema and the completed `ext_vocab_load_id` in `etl_runs`. Use the same `metadata_schema` for setup and ETL.

Existing vocabularies loaded before tracking have no known load ID; the ETL warns and continues. A failed or interrupted latest load blocks the ETL until setup succeeds. Setup and ETL use database advisory locks to prevent overlapping managed loads, and table identities are checked before linking a load. Manual changes to table contents outside these scripts are not detected. Source paths and checksums identify files, not their publisher's version or provenance.

## Swedish ICD-10 mappings

The diagnosis and cause-of-death transformations use mappings involving:

- ICD-10-SE source codes;
- ICD-10-WHO concepts;
- SNOMED concepts where required by the target domain.

The mapping setup includes:

- `sql/external_vocabularies/ext_vocab_2_icd10se_icd10.sql`: ICD-10-SE → ICD-10;
- `sql/external_vocabularies/ext_vocab_3_icd10se_who_snomed.sql`: ICD-10-SE → ICD-10 → standard concept;
- `sql/external_vocabularies/ext_vocab_4_icd10who_snomed.sql`: ICD-10 → standard concept (causes of death).

ICD-10-SE codes are mapped to ICD-10 within the pipeline into table `icd10se_codes` in schema `ext_vocab_schema`. `02_setup_ext_vocab.R` loads Socialstyrelsen's ICD-10-SE code list (`vocabularies.external.icd10se_codes_tsv_path`, columns `Kod`, `Titel` and `Kodnivå - kodspecifikation`) into `icd10se_codes`. `ext_vocab_2_icd10se_icd10.sql` then maps each code to its longest prefix that is a valid code of the Athena ICD10 vocabulary in the CDM (truncation to the nearest parent), for example `A08.3A` → `A08.3` and `X65.69` → `X65`. Chapter and section-range rows of the code list are excluded. Valid ICD10 codes that are not in the ICD-10-SE list are added mapped to themselves, so that WHO codes found in the registers are covered too. Codes with no valid ICD10 prefix keep an empty `icd10_who_map`.

Clinical-event scripts route mapped concepts by domain: Condition to `condition_occurrence`, Measurement to `measurement`, Procedure to `procedure_occurrence`, and other mapped domains to `observation`. Eligible unmapped codes are retained in `condition_occurrence` with concept ID `0`. The mapping functions select the lowest standard concept ID per source code and domain; codes mapped to multiple domains can therefore populate multiple OMOP tables.

## TPR and LISA mappings

Country of birth (`grunduppgifter`) and county, civil status, education and disposable income (LISA) are mapped to OMOP concepts with the project's own mapping file `vocabularies/external/tpr_lisa_external_vocab.csv` (`vocabularies.external.lisa_tpr_map_csv_path`). The file is semicolon-separated and UTF-8 encoded, with one row per source variable and code: `source_variable_description` and `source_code` identify the row, and `observation_concept_id`, `value_as_concept_id`, `value_as_number` and `value_as_string` give the OMOP values.

`02_setup_ext_vocab.R` checks the file before loading it: all expected columns must be present, the concept and number columns must be integers, and each `source_variable_description` + `source_code` pair must be unique. `07_grunduppgifter_lisa_to_observation.sql` joins on that pair, so a duplicate would duplicate observations. It then creates `lisa_tpr_map` with `ext_vocab_5_lisa_tpr_map.sql` and loads the file. Changes to the mapping are made in the file in the repository and go through review like code.

## Drug mappings

Medication source values from `lmed` use VARUNR and related product information. The external mapping process connects Swedish product identifiers to RxNorm and RxNorm Extension concepts.

Relevant files include:

- `sql/external_vocabularies/ext_vocab_1a_varunr_rxnorm.sql` for loading the source mapping data;
- `sql/external_vocabularies/ext_vocab_1_varunr_rxnorm.sql` for building the VARUNR mapping table;
- `sql/omop/05_lmed_to_drug_exposure.sql` for applying the mapping to drug exposure records.

Drug concepts are mapped by matching `lmed.varunr` to `ext_vocab.varunr_to_concept_final`, retaining standard concepts in the Drug domain. VARUNRs with no standard Drug concept receive concept ID `0`.

## Concept fields and source fields

OMOP concept fields should document both:

- the target concept ID and its selected vocabulary or domain;
- the original source code in the corresponding `*_source_value` field where available.

For each mapping, record the source code, target concept rule, fallback behavior, and whether the mapping is direct, hierarchical, or dependent on a custom table.

## Review items

The following items require explicit review before being treated as final:

- whether custom ICD-10-SE mappings should be replaced by direct OMOP vocabulary relationships;
- mapping coverage and the lowest-ID selection rule when a source code maps to multiple standard concepts in one domain;
- publisher versions and provenance of external vocabulary files.
