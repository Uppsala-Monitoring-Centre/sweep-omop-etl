# OMOP ETL Sweep

This repository contains the ETL pipeline (R orchestrators with SQL logic) used to map Swedish register data (delivered by Socialstyrelsen, (SoS) and Statistics Sweden (SCB)) into the OMOP CDM.

## Index

1. [Purpose](#purpose)
2. [ETL architecture](#etl-architecture)
3. [Repository structure](#repository-structure)
4. [Documentation](#documentation)
5. [Working with R in this project](#working-with-r-in-this-project)
6. [Scope of each orchestrator](#scope-of-each-orchestrator)
7. [Tests](#tests)
8. [Tests: Smoke config keys](#smoke-config-keys)
9. [Tests: Smoke tests for orchestrators](#smoke-tests-for-orchestrators)
10. [Formatter and linter setup (R and SQL)](#formatter-and-linter-setup-r-and-sql)
11. [SQL rendering notes](#sql-rendering-notes)
12. [ETL run metadata tracking](#etl-run-metadata-tracking)
13. [How to extend the refactored pipeline](#how-to-extend-the-refactored-pipeline)
14. [License](#license)

## Purpose

The project starts from raw source tables in PostgreSQL and writes cleaned and standardized data to OMOP CDM tables in a target schema. Mapping uses the OMOP CDM version and vocabulary release available at execution time; those versions are recorded with each release and ETL run for traceability and reproducibility.

- Source database: Swedish register data
- Target schema: OMOP CDM tables using the configured CDM version
- Supporting schemas: external vocabularies and shared ETL functions

### Database environments

The project separates database server instances by environment and keeps the databases within each instance isolated by purpose:

- **Test server instance:** hosts `swedish_registry_test` and `swedish_registry_smoke`.
  - **Test database** (`swedish_registry_test`, configured by `config/settings.test.yaml`): used for local development, integration tests, and investigating ETL behavior with a persistent non-smoke test setup. It may contain broader test data and is not intended for production outputs.
  - **Smoke database** (`swedish_registry_smoke`, configured by `config/settings.smoke.yaml`): used for fast, isolated end-to-end checks in CI or before changes are merged. It uses separate schemas such as `raw_smoke`, `omop_smoke`, and `metadata_smoke`, and should use a small sample so that failures are detected quickly without affecting the test database.
- **Production server instance:** hosts versioned production databases, currently `swedish_registry_prod_2024_v1`. Future source-data or vocabulary releases may create additional databases such as `swedish_registry_prod_2024_v2`, rather than replacing the earlier version. This preserves older study outputs and supports reproducibility.

The server host, port, and database name are selected through the active environment-specific settings file. Keep smoke schemas and metadata separate from non-smoke test schemas, and keep production databases separate from both. The smoke environment validates that orchestrators can execute in sequence; it is not a substitute for full data-quality validation or a production ETL run.

## ETL architecture

The pipeline is organized to keep responsibilities separated:

1. Orchestrators define pipeline steps and execution order.
2. Utility/config files provide shared behavior (logging, settings, DB connection).
3. SQL files contain transformation logic and are called from orchestrators.

This structure makes the ETL easier to maintain.

## Repository structure

- `R/orchestrators`: entry points for each ETL phase
  - `00_sample_generator.R`: build a workshop sample subset
  - `01_setup_CDM.R`: create OMOP CDM + load OHDSI vocabularies
  - `02_setup_ext_vocab.R`: load non-OHDSI vocabularies
  - `03_omop_orchestrator.R`: run the core mapping
  - `04_indices_FK.R`: create indexes and foreign keys
- `R/config`: settings helpers
- `R/db`: database connection helpers
- `R/utils`: logging and general helpers
- `sql`: Folder having SQL queries used at distinct ETL phases 
- `config/settings.<env>.yaml`: runtime configuration (schemas, DB endpoints, paths)
- `vocabularies/external`: external vocabulary files maintained by the project (e.g. the TPR/LISA mapping), loaded by `02_setup_ext_vocab.R`
- `docs`: project and ETL documentation
  - `Documentation_Mapping.qmd`: Quarto overview of the pipeline and mapping documentation
  - `Documentation_Mapping.html`: rendered mapping documentation with Mermaid visualizations
  - `Documentation_Mapping_files/`: CSS, JavaScript, and font assets required by the rendered HTML
  - `purpose.md`: cohort purpose, population, data sources, and intended use
  - `transformation.md`: table-level transformation logic and dependencies
  - `vocabulary.md`: standard and custom vocabulary mappings
  - `data_quality.md`: quality rules, validation checks, and open issues
  - `SWEEP_ETL_specification.xlsx`: detailed field-level mapping register
  - `RELEASES.md`: release history and production release notes
  - `condition_occurrences_outside_observation_periods/`: Quarto report files on condition occurrences outside observation periods
- `scripts`: code to run formatter and linter setup (R and SQL)
- `tests`: unit test folder

## Documentation

Start with the [mapping overview source](docs/Documentation_Mapping.qmd) or open the [rendered mapping documentation](docs/Documentation_Mapping.html) for the HTML layout and Mermaid pipeline visualization. The rendered page depends on the adjacent `docs/Documentation_Mapping_files/` asset directory.

Use the supporting documents for focused review:

- [Purpose](docs/purpose.md): why the ETL exists, its source data, study population, observation window, and intended use.
- [Transformation rules](docs/transformation.md): how source data is transformed into OMOP tables, including dependencies, exclusions, date handling, and clinical-event routing.
- [Vocabulary mappings](docs/vocabulary.md): Athena, ICD-10, SNOMED, VARUNR, RxNorm, and custom mapping assets.
- [Data quality and open issues](docs/data_quality.md): validation expectations, attrition checks, known defects, and unresolved mapping questions.
- [Drug mapping quality checks](docs/drug_mapping_quality.md): recurring checks of how LMED drug codes map to RxNorm / RxNorm Extension.
- [Detailed mapping register](docs/SWEEP_ETL_specification.xlsx): field-level source-to-destination mappings, logic, comments, and notes.
- [Release documentation](docs/RELEASES.md): version-specific release details and verification information.

The Markdown and Quarto files describe decisions and relationships between transformations. The Excel workbook contains the row-level mapping register, and the SQL files remain the executable source of truth.

When the Quarto source changes, regenerate the rendered page and its companion assets:

```powershell
quarto render docs/Documentation_Mapping.qmd
```

Commit the source file, `Documentation_Mapping.html`, and the complete `Documentation_Mapping_files/` directory together. GitHub or Azure DevOps repository views may display the HTML source rather than execute it; publish the rendered files through GitHub Pages, Azure Static Web Apps, or another static web host for the full visualization experience.

## Working with R in this project

### 1. Open the project

Open `omop_etl_sweep.Rproj` in RStudio (or set the project root in VS Code).
The project `.Rprofile` activates `renv` automatically.

### 2. Install dependencies

Run once per machine (or when `renv.lock` changes):

```r
renv::restore()
```

### 3. Configure runtime settings

Review and edit one of:

- `config/settings.local.yaml`
- `config/settings.test.yaml`
- `config/settings.prod.yaml`

Make sure DB connection values, schema names, and vocabulary paths are correct for your environment.

Optional: set `CONFIG_PATH` to use a different settings file (for example `config/settings.local.yaml`) without changing script arguments.

Windows PowerShell:

```powershell
$env:CONFIG_PATH = "config/settings.local.yaml"
```

### Runtime config keys (`config/settings.<env>.yaml`)

Main groups and their purpose:

- `project`: `name` (project identifier), `log_dir` (runtime logs folder).
- `source_db`: `host`, `port`, `dbname`, and either `user` or `user_env` (source PostgreSQL connection settings).
- `schemas`: `INPUT_SCHEMA` and `OUTPUT_SCHEMA` (main ETL), `metadata_schema` (schema used for ETL run audit table), `cdm_schema` and `cdm_version` (CDM setup and index/FK generation), `ext_vocab_schema` (external vocab setup).
- `sampling`: `input_schema` and `output_schema` (sample generator source/target schemas), optional `input_dbname` and `output_dbname` (default to `source_db.dbname`), and optional FDW bootstrap keys `fdw_auto_setup`, `fdw_server_name`, `fdw_local_schema`.
- `sql_paths`: `sampling`, `omop`, `external_vocabularies`, `indices` (folders where orchestrators read SQL files).
- `run`: `sample_size` (sample records), `use_index` (sample SQL index block), `sql` (SQL-enabled run toggle).
- `vocabularies`: `dir_path` (Athena vocabulary folder), `external.icd10se_codes_tsv_path` (Socialstyrelsen's ICD-10-SE code list), `external.lisa_tpr_map_csv_path` (TPR/LISA mapping, kept in `vocabularies/external/`; relative paths are read from the project root) and `external.nplid_to_rxnorm_csv_path` (NPLID to RxNorm mapping CSV).

Recommended checks before running:

1. Ensure all schema names exist (or can be created) in the target database.
2. Ensure all SQL paths point to existing folders in this repository.
3. Ensure vocabulary paths are valid local paths on the machine executing the pipeline.

When `sampling.input_dbname` and `sampling.output_dbname` differ, `00_sample_generator.R` executes in the output database and expects source tables to be accessible there.

Cross-database options:

1. Manual FDW setup (bring your own `postgres_fdw` server/user mapping/foreign tables).
2. Automatic FDW setup by setting `sampling.fdw_auto_setup: true`.

With auto setup enabled, the orchestrator will create:

1. `postgres_fdw` extension (if missing)
2. FDW server (`sampling.fdw_server_name`, default `sampling_input_db_server`)
3. User mapping for `CURRENT_USER` (using `source_db` user and optional password env)
4. Missing foreign tables in `sampling.fdw_local_schema` (defaults to `sampling.input_schema`)

### Per-user DB credentials without git changes

To avoid editing `config/settings*.yaml` per developer, use environment variables:

1. Keep `source_db.user_env: "DB_USER"` in the shared config.
2. Set `DB_USER` locally on each machine.
3. Optionally set `source_db.password_env` and the corresponding environment variable if your PostgreSQL setup requires a password.

Windows PowerShell (current session):

```powershell
$env:DB_USER = "your_postgres_user"
$env:DB_PASSWORD = "your_postgres_password"
```

R startup file (`~/.Renviron`) for persistent local setup:

```text
DB_USER=your_postgres_user
DB_PASSWORD=your_postgres_password
```

`R/db/connect.R` and `R/orchestrators/01_setup_CDM.R` both support this pattern.

### 4. Run orchestrators in order

Typical execution order:

1. `R/orchestrators/00_sample_generator.R` (optional, for workshop/sample data)
2. `R/orchestrators/01_setup_CDM.R` (run once per environment unless re-initializing)
3. `R/orchestrators/02_setup_ext_vocab.R` (if external vocabularies are required)
4. `R/orchestrators/03_omop_orchestrator.R` (main ETL run)
5. `R/mapping_quality/run_drug_mapping_quality.R` (optional: drug mapping quality checks, see [docs/drug_mapping_quality.md](docs/drug_mapping_quality.md))
6. `R/orchestrators/04_indices_FK.R` (post-load performance and integrity)

You can run each script interactively, or from terminal:

```bash
Rscript R/orchestrators/03_omop_orchestrator.R
```

## Scope of each orchestrator

The orchestrators are intentionally separated so each one has a clear operational scope.

### `00_sample_generator.R`

Scope:

1. Build a reproducible sample subset from source data for workshops and development.
2. Execute SQL under `sql/sampling` only.
3. Create sample output schemas/tables configured in the active settings file (`config_path`).

### `01_setup_CDM.R`

Scope:

1. Create OMOP CDM structures for the configured CDM version.
2. Load OHDSI/Athena vocabularies into the configured CDM schema.
3. Apply OMOP primary keys required for the base model.

### `02_setup_ext_vocab.R`

Scope:

1. Load and prepare external (non-OHDSI) vocabularies. Note that the drug dictionary is not made available.
2. Execute SQL under `sql/external_vocabularies`.
3. Prepare mapping assets required by downstream ETL steps.

### `03_omop_orchestrator.R`

Scope:

1. Run the core source-to-OMOP mapping pipeline.
2. Execute transformation SQL under `sql/omop` in controlled sequence.
3. Populate OMOP domain tables from source schemas.

### `04_indices_FK.R`

Scope:

1. Apply indexes and foreign keys after data load.
2. Run performance/integrity hardening SQL (typically from `sql/5.4/postgresql`).
3. Finalize the schema for query performance and relational consistency.

### 5. Logs and troubleshooting

Execution logs are written to `logs/`.
Check the latest log first when a step fails.

## Tests

Before pushing new changes to the git repository ensure that those changes pass the designed tests under the `tests` folder. Depending on your operating system, you can run one of the following commands.

- Windows

  ```PowerShell
  Rscript -e "renv::activate(); testthat::test_dir('tests/testthat')"
  ```

If `Rscript` is not available on `PATH`, use the full path to your local R installation.

- Linux/macOS

  ```sh
  R -q -e "renv::activate(); testthat::test_dir('tests/testthat')"
  ```

- R environment within any OS

  ```R
  renv::activate()
  testthat::test_dir("tests/testthat")
  ```

Also make sure to add new test functions for each new functionality you add.

### Smoke config keys

Smoke tests read settings from `config/settings.smoke.yaml` (or `SMOKE_CONFIG_PATH` if overridden).

Required keys:

1. `source_db.host`, `source_db.port`, `source_db.dbname`, and either `source_db.user` or `source_db.user_env`
2. `schemas.INPUT_SCHEMA`, `schemas.OUTPUT_SCHEMA`, `sampling.input_schema`, `sampling.output_schema`
3. `schemas.cdm_schema`, `schemas.cdm_version`, `schemas.ext_vocab_schema`
4. `sql_paths.sampling`, `sql_paths.omop`, `sql_paths.external_vocabularies`, `sql_paths.indices`

Required for selected orchestrators:

1. `vocabularies.dir_path` for `RUN_SMOKE_01`
2. `vocabularies.external.icd10se_codes_tsv_path` and `vocabularies.external.nplid_to_rxnorm_csv_path` for `RUN_SMOKE_02`

Optional keys:

1. `tools.psql` can be set when `psql` is not available on `PATH` (used by `01_setup_CDM.R`).
2. `project.log_dir` can be customized to separate smoke logs from non-smoke runs.
3. `schemas.metadata_schema` can be set to isolate smoke ETL audit rows in a separate schema.
4. `sampling.input_dbname` and `sampling.output_dbname` can be set for cross-database sampling.
5. `sampling.fdw_auto_setup`, `sampling.fdw_server_name`, and `sampling.fdw_local_schema` can be set to let `00_sample_generator.R` bootstrap `postgres_fdw` automatically.

Recommendation:

1. Keep smoke schemas isolated from non-smoke ETL schemas (for example `*_smoke`).
2. Use a small `run.sample_size` (for example `100`) for fast smoke runs.

### Smoke tests for orchestrators

Smoke tests are implemented in `tests/testthat/test-orchestrators-smoke.R` and use `config/settings.smoke.yaml` by default.

They are gated and skipped unless you explicitly enable them with environment variables.

#### Running them in the terminal

Enable all smoke tests:

```PowerShell
$env:RUN_SMOKE = "true"
Rscript -e "renv::activate(); testthat::test_file('tests/testthat/test-orchestrators-smoke.R')"
```

Run only one orchestrator smoke test (example: `03_omop_orchestrator.R`):

```PowerShell
$env:RUN_SMOKE = "true"
$env:RUN_SMOKE_03 = "true"
Rscript -e "renv::activate(); testthat::test_file('tests/testthat/test-orchestrators-smoke.R')"
```

Per-orchestrator flags:

1. `RUN_SMOKE_00` for `00_sample_generator.R`
2. `RUN_SMOKE_01` for `01_setup_CDM.R`
3. `RUN_SMOKE_02` for `02_setup_ext_vocab.R`
4. `RUN_SMOKE_03` for `03_omop_orchestrator.R`
5. `RUN_SMOKE_04` for `04_indices_FK.R`

Optional config override:

```PowerShell
$env:SMOKE_CONFIG_PATH = "config/settings.smoke.yaml"
```

Notes:

1. `RUN_SMOKE=true` is always required.
2. `RUN_SMOKE_01` requires Athena vocabulary files configured in your smoke config.
3. `RUN_SMOKE_02` requires the external mapping CSV files configured in your smoke config.

#### Running them in an R interactive environment

Set the environmental variables in the `.Renviron` file

```txt
RUN_SMOKE="true"
RUN_SMOKE_00="true"
RUN_SMOKE_01="false"
RUN_SMOKE_03="true"
SMOKE_CONFIG_PATH="config/settings.smoke.yaml"
```

Load the R environment and run the functions (if within the test folder)

```R
renv::load()
testthat::test_file("test-orchestrators-smoke.R")
```

or within the parent folder

```R
renv::activate()
testthat::test_file("tests/testthat/test-orchestrators-smoke.R")
```

## Formatter and linter setup (R and SQL)

Consistent formatting and linting keep the ETL logic readable, make code and SQL changes easier to review, and help catch style or syntax issues before they reach CI or a production data run.

This repository includes:

1. R formatter: `styler`
2. R linter: `lintr`
3. SQL formatter/linter: `sqlfluff` (PostgreSQL dialect)
4. Pre-commit hooks: `.pre-commit-config.yaml`

Project files:

1. `.lintr`
2. `.sqlfluff`
3. `scripts/quality/format_r.R`
4. `scripts/quality/lint_r.R`

Install tools:

  1. R packages (inside project):
    ```R
    renv::install(c("styler", "lintr"))
    renv::snapshot()
    ```
  2. Python tools (system): `pre-commit` is OPTIONAL
    ```PowerShell
    pip install pre-commit sqlfluff
    ```

Run format/lint manually:

  1. Fix R formatting (default mode):
    ```PowerShell
    Rscript scripts/quality/format_r.R --fix
    ```
  2. Check R formatting:
    ```PowerShell
    Rscript scripts/quality/format_r.R --check
    ```
  3. Check R linting (default mode):
    ```PowerShell
    Rscript scripts/quality/lint_r.R --check
    ```
  4. Fix auto-fixable R style issues, then re-run lint:
    ```PowerShell
    Rscript scripts/quality/lint_r.R --fix
    ```
  5. Check SQL formatting rules only:
    ```PowerShell
    python -m sqlfluff lint --ignore parsing,templating --rules LT01,LT02,LT09,LT12,LT13,LT15 sql
    ```
  6. Check full SQL linting:
    ```PowerShell
    python -m sqlfluff lint --ignore parsing,templating sql
    ```

If `sqlfluff` is not available on `PATH`, run it from the project virtual environment:

```PowerShell
.venv\Scripts\python.exe -m sqlfluff lint --ignore parsing,templating --rules LT01,LT02,LT09,LT12,LT13,LT15 sql
.venv\Scripts\python.exe -m sqlfluff lint --ignore parsing,templating sql
```

Notes:

1. `format_r.R` defaults to fix mode when no flag is provided.
2. `lint_r.R` defaults to check mode when no flag is provided.
3. `lint_r.R --fix` applies `styler` first, then runs `lintr`; it does not guarantee that all lint findings are auto-fixable.

Enable pre-commit hooks (OPTIONAL):

```PowerShell
pre-commit install
```

Run hooks on all files:

```PowerShell
pre-commit run --all-files
```

## SQL rendering notes

When rendering parameterized SQL with SqlRender, write rendered output to a dedicated file before execution.

Example:

```r
renderSqlFile("sql/omop/07_setup_drug_era.sql", "sql/omop/07_setup_drug_era_rendered.sql")
```

## ETL run metadata tracking

The main orchestrator `R/orchestrators/03_omop_orchestrator.R` writes run-level audit metadata to PostgreSQL.

On each run, it ensures `etl_runs` exists under `schemas.metadata_schema` and records:

1. Run lifecycle: `started_at`, `finished_at`, `status`.
2. Version control context: `etl_version`, `git_commit`, `git_branch`, `git_tag`, `is_dirty`.
3. Run context: `config_path`, `input_schema`, `output_schema`, `run_user`, `ext_vocab_schema`, `ext_vocab_load_id`, `athena_vocabulary_version`.
4. Execution summary: `files_processed`, `successful_files`, `failed_files`, `error_message`.

### Automatic version detection

The `etl_version` is automatically derived from git metadata:

- **Tagged releases**: Uses the git tag (e.g., `v1.0.1`)
- **Untagged commits**: Uses `dev-` prefix with 7-char commit hash (e.g., `dev-abc1234`)
- **No git info**: Uses `unknown`

This eliminates the need to manually maintain version numbers in configuration files and ensures version tracking always matches your git state.

### User tracking

The `run_user` column captures the system user executing the ETL (from `Sys.info()[["user"]]`), enabling audit trails of who ran each ETL job.

## How to extend the refactored pipeline

When adding a new mapping step:

1. Add SQL under the appropriate `sql/` subfolder.
2. Reuse shared helpers from `R/utils` and `R/db`.
3. Wire the new step in the relevant orchestrator.
4. Keep schema/table names configurable through `config/settings.<env>.yaml`.
5. Validate results and add logging around the new step.

## License

See [LICENSE](./LICENSE.txt) for repository licensing terms.
