# Release Documentation

<!-- markdownlint-disable MD024 -->

This document provides detailed information about each OMOP ETL release.

## Release Template

Use this template when documenting a new release.

Copy this section under `## Releases` and replace the placeholders with release-specific values.

If you are documenting a real release, the heading should be `Release vMAJOR.MINOR.PATCH` under `## Releases`.

## Release vMAJOR.MINOR.PATCH

**Release Date:** YYYY-MM-DD  
**Git Tag:** `omop-etl-vMAJOR.MINOR.PATCH`  
**Database:** `swedish_registry_YYYY_MM`  

### Environment Details

- **Raw Data Schema:** `raw_YYY_MM`
- **Vocabulary Schema:** `ext_vocab_YYYY_MM`
- **OMOP Schema:** `omop54`
- **Athena Version:** v5.0 YYYYMMDD
- **External Vocabularies:**
  - ICD10-SE to ICD10: vYYYY.MM
  - NPL to RxNorm: vYYYY.MM

### ETL Statistics

- Total persons: X
- Total drug exposures: X
- Total conditions: X
- Total visits: X
- Run time: Xh XXmin
- Run date: YYYY-MM-DD
- Run by: [username]

### Configuration

- Config file: `config/settings.prod_YYYY_MM.yaml`
- Vocabularies path: `C:/vocabularies/athena_YYYY_MM/`

| Event | Version Change | Example | Reasoning |
| :-- | :-- | :-- | :-- |
| Vocabulary update | Bump MINOR | v1.0.0 -> v1.1.0 | New vocabulary = new feature data |
| Raw data update | Bump MAJOR | v1.1.0 -> v2.0.0 | New raw data year = breaking change in data lineage |
| Bug fix | Bump PATCH | v1.1.0 -> v1.1.1 | Code fix only |
| ETL code feature | Bump MINOR | v1.1.1 -> v1.2.0 | New mapping logic added |

### `release.ps1` Examples

```powershell
# Normal release: updates VERSION, commits release files, and creates the annotated tag
.\scripts\release.ps1 -Version "1.1.0" -Message "July 2026 vocabulary update"

# Dry-run style usage: show the release flow without making git changes
.\scripts\release.ps1 -Version "1.1.0" -Message "July 2026 vocabulary update" -SkipGit

# Hotfix release: same flow, but with a patch version and a short message
.\scripts\release.ps1 -Version "1.0.2" -Message "Fix DORS path handling"

# Release with a more explicit message for the annotated tag
.\scripts\release.ps1 -Version "1.2.0" -Message "Add new ETL mapping for visit attribution"
```

Notes:

- `-Version` must match `MAJOR.MINOR.PATCH`.
- `-Message` becomes the annotated git tag message.
- `-SkipGit` skips the commit and tag steps, which is useful for validating the script flow before releasing.
- The script expects a matching release heading in `CHANGELOG.md` before it creates the tag.

### Taging manually Examples

```powershell
# Starting point
git tag -a omop-etl-v1.0.0 -m "Initial 2026 raw + Jan 2026 vocab"

# July 2026 vocab update
git tag -a omop-etl-v1.1.0 -m "July 2026 vocabulary update"

# Bug fix
git tag -a omop-etl-v1.1.1 -m "Fix: person table duplicate handling"

# January 2027 vocab + raw data
git tag -a omop-etl-v2.0.0 -m "2027 raw data + January 2027 vocabulary"

# July 2027 vocab
git tag -a omop-etl-v2.1.0 -m "July 2027 vocabulary update"
```

### Verification Queries

```sql
-- Verify record counts
SELECT 'person' as table_name, COUNT(*) as count FROM omop54_YYYY_MM.person
UNION ALL
SELECT 'observation_period', COUNT(*) FROM omop54_YYYY_MM.observation_period
UNION ALL
SELECT 'visit_occurrence', COUNT(*) FROM omop54_YYYY_MM.visit_occurrence
UNION ALL
SELECT 'condition_occurrence', COUNT(*) FROM omop54_YYYY_MM.condition_occurrence
UNION ALL
SELECT 'drug_exposure', COUNT(*) FROM omop54_YYYY_MM.drug_exposure
UNION ALL
SELECT 'death', COUNT(*) FROM omop54_YYYY_MM.death;

-- Verify ETL metadata
SELECT * FROM metadata.etl_runs 
WHERE git_tag = 'omop-etl-vMAJOR.MINOR.PATCH' 
ORDER BY run_id DESC;
```

Using `pg_stat_user_tables`

```powershell
psql -h 127.0.0.1 -p 5432 -U etl_admin -d swedish_registry_prod -c "SELECT schemaname, n_tup_ins as rows FROM pg_stat_user_tables WHERE schemaname IN ('raw') ORDER BY schemaname;"
```

## Releases

Add new releases below in reverse chronological order (newest first).

### Release History

### Release v1.1.2 (In Progress)

**Release Date:** In progress  
**Git Tag:** `omop-etl-v1.1.2`  
**Database:** `swedish_registry_YYYY_MM`  
**Status:** Draft

#### Environment Details

- **Raw Data Schema:** `raw_2024`
- **Vocabulary Schema:** `ext_vocab_2024_02`
- **OMOP Schema:** `omop54`
- **Athena Version:** TODO

#### ETL Statistics

- Total persons: TBD
- Total drug exposures: TBD
- Total conditions: TBD
- Total visits: TBD
- Run time: TBD
- Run date: TBD
- Run by: TBD

#### Configuration

- Config file: `config/settings.prod.yaml`
- Vocabularies path: TBD
- Log file: TBD

#### Changes in This Release

##### Fixed

- Disable `drug_exposure_observation_check` and `condition_occurrence_observation_check` QC queries; the correlated `EXISTS`-based observation-period checks could run for multiple days without a supporting index on `observation_period.person_id`, stalling the ETL run.

#### Known Issues

- `drug_exposure_observation_check` and `condition_occurrence_observation_check` QC queries are temporarily disabled pending a performant rewrite (single join/aggregation instead of correlated `EXISTS` subqueries).

#### Data Quality Notes

- Final ETL statistics must be recorded after the production run.

### Release v1.1.1 (In Progress)

**Release Date:** In progress  
**Git Tag:** `omop-etl-v1.1.1`  
**Database:** `swedish_registry_YYYY_MM`  
**Status:** Draft

#### Environment Details

- **Raw Data Schema:** `raw_2024`
- **Vocabulary Schema:** `ext_vocab_2024_02`
- **OMOP Schema:** `omop54`
- **Athena Version:** TODO

#### ETL Statistics

- Total persons: TBD
- Total drug exposures: TBD
- Total conditions: TBD
- Total visits: TBD
- Run time: TBD
- Run date: TBD
- Run by: TBD

#### Configuration

- Config file: `config/settings.prod.yaml`
- Vocabularies path: TBD
- Log file: TBD

#### Changes in This Release

##### Fixed

- Replace NULL-sensitive `NOT IN` anti-join with `NOT EXISTS` in person and death ETL SQL.
- Reuse materialized ETL intermediates (cleaned migration events, observed persons, parsed DORS death dates) instead of recomputing expensive parsing/cleaning logic.
- Align valid date logic for inpatient data in `visit_occurrence` ETL with attrition table logic.

#### Known Issues

- Observation-period overlap handling still requires review.
- VARUNR-to-RxNorm mapping coverage requires confirmation.
- Dedicated workbook mappings for `measurement` and `procedure_occurrence` are still pending.

#### Data Quality Notes

- Some incomplete source dates are imputed according to transformation-specific rules.
- Unmapped vocabulary values may receive concept ID `0`.
- Final ETL statistics must be recorded after the production run.

### Release v1.1.0

**Release Date:** In progress  
**Git Tag:** `omop-etl-v1.1.0`  
**Database:** `swedish_registry_YYYY_MM`  
**Status:** Draft

#### Environment Details

- **Raw Data Schema:** `raw_2026`
- **Vocabulary Schema:** `ext_vocab_2026_02`
- **OMOP Schema:** `omop54`
- **Athena Version:** TODO

#### ETL Statistics

- Total persons: TBD
- Total drug exposures: TBD
- Total conditions: TBD
- Total visits: TBD
- Run time: TBD
- Run date: TBD
- Run by: TBD

#### Configuration

- Config file: `config/settings.prod.yaml`
- Vocabularies path: TBD
- Log file: TBD

#### Changes in This Release

##### Added

- Add `run_user` capture to ETL metadata for auditability.
- Add cross-database sampling support with optional `postgres_fdw` bootstrap.
- Add per-database password environment variable support for sampling connections.
- Add environment-specific configuration files for local, test, smoke, and production workflows.
- Add release documentation (`CHANGELOG.md`, `docs/RELEASES.md`) and release automation support.
- Add detailed ETL mapping, transformation, vocabulary, and data-quality documentation.
- Add `condition_type_concept_id` to the condition check query for enhanced data mapping.

##### Changed

- Refactor configuration loading to support explicit `config_path` values and `CONFIG_PATH` environment overrides.
- Centralize database credential resolution and extend connector support for user environment-variable aliases.
- Parameterize `EXT_VOCAB_SCHEMA` across OMOP and mapping SQL to avoid hardcoded schema names.
- Update README guidance and test configuration handling to match the new settings layout.
- Update Azure validation workflow configuration to avoid pipeline errors.
- Update configuration files and `.gitignore` for the revised local and environment-specific workflow.
- Improve SQL comments and formatting for drug exposure and drug era transformations.
- Rename `load_csv_or_stop` to support both CSV and XLSX formats.
- Update README and ETL mapping documentation for clarity.

##### Fixed

- Remove records with `NULL` source values when they cannot produce valid OMOP records.
- Fix `run_status` tracking bug (using super-assignment in error handler).
- Fix NA handling in git tag version detection.
- Fix death-record date filtering beyond the data lock point.
- Fix FDW remote schema handling by quoting identifiers and synchronizing server options.
- Fix index/FK rerun behavior by rendering conditionally and making index creation idempotent.
- Fix smoke-test alignment issues introduced by the configuration refactor.
- Fix transformations that populate multiple OMOP tables by removing invalid source rows before insertion.
- Fix foreign key creation failing on PostgreSQL by using positional (`$1`, `$2`) instead of named (`?schema`) query placeholders, which RPostgres does not support.
- Fix missing comma in `condition_check` query causing a SQL syntax error.
- Fix missing comma in drug era and condition era scripts.
- Remove redundant `WITH` keyword in `max_observation_period` definition in drug era and condition era scripts.
- Enhance observation period handling in death record processing (`dors_to_condition`).
- Fix typos in README smoke test instructions.

#### Known Issues

- Observation-period overlap handling still requires review.
- VARUNR-to-RxNorm mapping coverage requires confirmation.
- Dedicated workbook mappings for `measurement` and `procedure_occurrence` are still pending.

#### Data Quality Notes

- Some incomplete source dates are imputed according to transformation-specific rules.
- Unmapped vocabulary values may receive concept ID `0`.
- Final ETL statistics must be recorded after the production run.

#### Verification Queries

Use the template verification queries above.

#### Next Steps

- Finalize environment values and ETL statistics after run completion.
- Run the production ETL and record final row counts, runtime, vocabulary versions, and operator.
- Run the verification queries and review data-quality checks.
- Set status to Released when tag `omop-etl-v1.1.0` is published.

### Release v1.0.0

**Release Date:** 2026-06-24  
**Git Tag:** `omop-etl-v1.0.0`  
**Database:** `swedish_registry`  
**Status:** Released

#### Known Issues

DORS logic was not correct and needed refactoring. For this reason we did not produce a production omop database with this etl version  

Summary is maintained in `CHANGELOG.md` under `## Version omop-etl-v1.0.0`.

- Add precise values if historical metadata is available.

<!-- markdownlint-enable MD024 -->
