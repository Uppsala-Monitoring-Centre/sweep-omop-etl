# Changelog

All notable changes to the OMOP ETL pipeline will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- Add the `period_start` rule to `etl_common.parse_par_date` in `00_create_functions.sql`, imputing partial dates to the first day of the known month or year. This is used to be conservative in the emigration period.

### Fixed

- In `03_tpr_and_dors_to_observation_period.sql` the existing merge of overlapping, touching (0-day gap) and 1-day-gap periods of the same person was never applied, because the final `INSERT` read the unmerged periods. It is applied now. Additionally periods with start > end are now dropped.
- In `03_tpr_and_dors_to_observation_period.sql` partial migration dates are now imputed in the direction that never counts time abroad as observed (immigrations to the end, emigrations to the start of the known month or year), and migration dates without any information (`0`) are discarded. Before, both were kept with a NULL date, which sorted the event after all dated ones: an undated immigration could produce a period from 2005-07-01 to 2024-12-31, and an undated emigration removed the preceding residency interval.
- In `03_tpr_and_dors_to_observation_period.sql` an emigration and an immigration of the same person on the same date are now ordered emigration first. Before, their order was arbitrary, so the observation periods of these persons could change between runs and could lose the residency time before that date.
- In `03_tpr_and_dors_to_observation_period.sql` persons whose first migration event is an emigration after 2005-07-01 are now considered resident on 2005-07-01 also when they later immigrate again. Before, only persons without any immigration were, so for the others (120,667 persons in the current data) observation started at their first return to Sweden instead of on 2005-07-01.
- In `03_tpr_and_dors_to_observation_period.sql` the attrition table check for overlapping observation periods now also counts periods that share only their boundary day, and a new check counts adjacent periods (next period starting the day after the end). Before, only periods starting strictly before the previous end were counted, and ties on the start date were ordered arbitrarily.
- In `01_grunduppgifter_to_person.sql` migration dates are now imputed or discarded and same-day emigration and immigration events are ordered emigration first, consistently with `03_tpr_and_dors_to_observation_period.sql`. Before, a person whose only migration record was an undated emigration, or whose last dated event was an immigration followed by an undated emigration, could be excluded from PERSON.
- In `00_create_functions.sql` `etl_common.parse_par_date` now imputes `YYYY0000` dates (year known, month and day `00`) to June 30 with the `midpoint` rule, as it already did for `YYYY` dates. Before, it returned NULL for them, so outpatient visits and diagnosis, measurement, procedure and cancer events (`04`, `06a`, `06b`, `06d`) with such dates were treated as having no valid date.

## Version omop-etl-v1.1.2

### Fixed

- Disable `drug_exposure_observation_check` (`05_lmed_to_drug_exposure.sql`) and `condition_occurrence_observation_check` (`06d_can_to_condition.sql`) QC queries; the correlated `EXISTS`-based observation-period checks could run for multiple days without a supporting index on `observation_period.person_id`, stalling the ETL run.

## Version omop-etl-v1.1.1

### Fixed

- Replace NULL-sensitive `NOT IN` anti-join with `NOT EXISTS` and reuse materialized cleaned migration events, observed persons, and parsed DORS death dates in person and death ETL SQL to avoid recomputing expensive parsing/cleaning logic.
- Align valid date logic for inpatient data in `visit_occurrence` ETL with attrition table logic.

## Version omop-etl-v1.1.0

### Added

- Add `condition_type_concept_id` to the condition check query for enhanced data mapping.
- Add `run_user` column to ETL metadata.
- Add cross-database sampling support with optional `postgres_fdw` bootstrap.
- Add per-database password environment variable support for sampling connections.
- Add environment-specific settings files for local, test, smoke, and production runs.
- Add release documentation and helper scripts for versioning and tagging.
- Add detailed ETL mapping, transformation, vocabulary, and data-quality documentation.

### Changed

- Rename `load_csv_or_stop` to support both CSV and XLSX formats.
- Update README and ETL mapping documentation for clarity.
- Refactor configuration path resolution to support explicit `config_path` and `CONFIG_PATH` overrides.
- Centralize database user resolution and extend connector support for environment-variable aliases.
- Parameterize external vocabulary schema references in OMOP and mapping SQL.
- Update smoke tests, unit tests, and README guidance to reflect the new configuration model.
- Update Azure validation workflow configuration to avoid pipeline errors.
- Update configuration files and `.gitignore` for the revised local and environment-specific workflow.
- Improve SQL comments and formatting for drug exposure and drug era transformations.

### Fixed

- Fix foreign key creation failing on PostgreSQL (`kolumnen "schema" existerar inte`) by using positional (`$1`, `$2`) instead of named (`?schema`) query placeholders, which RPostgres does not support.
- Fix missing comma in `condition_check` query causing a SQL syntax error.
- Fix missing comma in drug era and condition era scripts.
- Remove redundant `WITH` keyword in `max_observation_period` definition in drug era and condition era scripts.
- Enhance observation period handling in death record processing (`dors_to_condition`).
- Fix typos in README smoke test instructions.
- Remove records with `NULL` source values when they cannot produce valid OMOP records.
- Fix `run_status` tracking bug (using super-assignment in error handler).
- Fix NA handling in git tag version detection.
- Fix death-record date filtering beyond the data lock point.
- Fix FDW remote schema handling by quoting identifiers and synchronizing server options.
- Fix index creation reruns by rendering conditionally and using idempotent creation logic.
- Fix SQL conflict fallout and remove orphan SQL scripts introduced during rebase cleanup.

## Version omop-etl-v1.0.0

### Added

- Initial project setup with:
  - ETL metadata tracking with automatic version detection
  - Git-based versioning system
  - User tracking in ETL runs
  - Unit and smoke tests
  - Formatting and style changes
  