source("R/utils/helpers.R")
source("R/utils/logging.R")
source("R/utils/etl_run_tracking.R")
source("R/utils/external_vocab_tracking.R")
source("R/db/connect.R")
source("R/config/settings.R")

library(DBI)
library(renv)

row_count <- function(con, schema, table) {
  table_id <- DBI::dbQuoteIdentifier(con, DBI::Id(schema = schema, table = table))
  DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM", table_id))[[1L]]
}


# ---------------------------------------------------------------------------
# Pipeline step definitions
#   file       = SQL filename under sql/
#   rows_input = source/input tables to count before the step (NULL = none)
#   rows_output = OMOP/output tables to count after the step (NULL = none)
# ---------------------------------------------------------------------------


# Load all sql logic files we want to use in our OMOP etl. They need to be run in order
steps <- list(
  list(file = "00_create_functions.sql"),
  list(
    file = "01_grunduppgifter_to_person.sql",
    rows_input = c("grunduppgifter", "dors", "lmed", "migrationer"),
    rows_output = "person"
  ),
  list(
    file = "02_grunduppgifter_and_dors_to_death.sql",
    rows_input = c("grunduppgifter", "dors"),
    rows_output = "death"
  ),
  list(
    file = "03_tpr_and_dors_to_observation_period.sql",
    rows_input = c("grunduppgifter", "migrationer", "dors"),
    rows_output = "observation_period"
  ),
  list(
    file = "04_par_to_visit_occurrence.sql",
    rows_input = c("par_ov", "par_sv"),
    rows_output = "visit_occurrence"
  ),
  list(
    file = "05_lmed_to_drug_exposure.sql",
    rows_input = c("lmed"),
    rows_output = "drug_exposure"
  ),
  list(
    file = "06a_parsv_to_condition_measurement_procedure_observation.sql",
    rows_input = c("par_sv"),
    rows_output = c("condition_occurrence", "observation", "measurement", "procedure_occurrence")
  ),
  list(
    file = "06b_parov_to_condition_measurement_procedure_observation.sql",
    rows_input = c("par_ov"),
    rows_output = c("condition_occurrence", "observation", "measurement", "procedure_occurrence")
  ),
  list(
    file = "06c_dors_to_condition_measurement_procedure_observation.sql",
    rows_input = c("dors"),
    rows_output = c("condition_occurrence", "observation", "measurement", "procedure_occurrence")
  ),
  list(
    file = "06d_can_to_condition_measurement_procedure_observation.sql",
    rows_input = c("can"),
    rows_output = c("condition_occurrence", "observation", "measurement", "procedure_occurrence")
  ),
  list(
    file = "07_grunduppgifter_lisa_to_observation.sql",
    rows_input = c(
      "grunduppgifter", "lisa_2005", "lisa_2006", "lisa_2007", "lisa_2008", "lisa_2009", "lisa_2010",
      "lisa_2011", "lisa_2012", "lisa_2013", "lisa_2014", "lisa_2015", "lisa_2016", "lisa_2017",
      "lisa_2018", "lisa_2019", "lisa_2020", "lisa_2021", "lisa_2022", "lisa_2023"
    ),
    rows_output = c("observation")
  ),
  list(file = "08_drug_era.sql"),
  list(file = "09_condition_era.sql"),
  list(file = "10_metadata.sql")
)

main <- function(config_path = NULL) {
  # Load settings and setup logging
  config_path <- resolve_config_path(config_path)
  config_path <- normalizePath(config_path, winslash = "/", mustWork = TRUE)
  project_root <- normalizePath(file.path(dirname(config_path), ".."), winslash = "/", mustWork = TRUE)
  settings <- read_settings(config_path)
  log_dir <- get_setting_or_default(settings, c("project", "log_dir"), "logs")
  setup_logging(log_dir = log_dir, prefix = "run_omop_etl")
  metadata_schema <- get_setting_or_default(settings, c("schemas", "metadata_schema"), "metadata")

  input_schema <- get_setting_or_default(
    settings,
    c("schemas", "INPUT_SCHEMA"),
    "raw"
  )
  output_schema <- get_setting_or_default(
    settings,
    c("schemas", "OUTPUT_SCHEMA"),
    "omop54"
  )
  ext_vocab_schema <- get_setting_or_default(
    settings,
    c("schemas", "ext_vocab_schema"),
    "ext_vocab"
  )

  sql_dir <- get_setting_or_default(settings, c("sql_paths", "omop"), "sql")
  sql_dir <- normalizePath(file.path(project_root, sql_dir), winslash = "/", mustWork = TRUE)

  # Validate schema names
  input_schema <- validate_schema(input_schema)
  output_schema <- validate_schema(output_schema)
  metadata_schema <- validate_schema(metadata_schema)
  ext_vocab_schema <- validate_schema(ext_vocab_schema)

  log_info("Input schema: {input_schema}")
  log_info("Output schema: {output_schema}")
  log_info("Metadata schema: {metadata_schema}")

  con <- NULL
  runs_table_id <- NULL
  run_id <- NULL
  run_status <- "running"
  run_error <- NULL
  files_processed <- 0L
  successful_files <- 0L
  failed_files <- 0L

  tryCatch({
    # Connect to the database
    con <- connect_source_db(config_path)
    git <- get_git_metadata()

    # Derive ETL version from git metadata
    etl_version <- if (!is.null(git$tag) && !is.na(git$tag) && nchar(git$tag) > 0) {
      git$tag
    } else if (!is.null(git$commit)) {
      paste0("dev-", substr(git$commit, 1, 7))
    } else {
      "unknown"
    }
    log_info("ETL version: {etl_version}")

    cdm_etl_reference <- build_cdm_etl_reference(
      git_commit = git$commit,
      git_tag = git$tag
    )
    runs_table_id <- ensure_etl_runs_table(con, metadata_schema)
    run_id <- start_etl_run(
      con = con,
      table_id = runs_table_id,
      etl_version = etl_version,
      git_commit = git$commit,
      git_branch = git$branch,
      git_tag = git$tag,
      is_dirty = git$is_dirty,
      config_path = config_path,
      input_schema = input_schema,
      output_schema = output_schema,
      ext_vocab_schema = ext_vocab_schema
    )
    log_info("Created ETL run record with run_id={run_id}")
    lock_external_vocab_schema(con, ext_vocab_schema, shared = TRUE)
    loads_table_id <- ensure_ext_vocab_loads_table(con, metadata_schema)
    ext_vocab_load_id <- record_external_vocab_load(con, loads_table_id, runs_table_id, run_id, ext_vocab_schema)
    if (is.null(ext_vocab_load_id)) {
      log_warn("No external vocabulary load metadata found for schema {ext_vocab_schema}; provenance is unknown.")
    } else {
      log_info("External vocabulary load_id: {ext_vocab_load_id}")
    }
    athena_version <- record_athena_version(con, runs_table_id, run_id, output_schema)
    log_info("Athena vocabulary version: {athena_version}")

    # Loop over all the steps defined above
    for (step in steps) {
      path <- file.path(sql_dir, step$file)
      if (!file.exists(path)) {
        stop(sprintf("SQL file not found: %s", path))
      }

      files_processed <- files_processed + 1L

      time_step(sprintf("Run %s", step$file), {
        if (!is.null(step$rows_input)) {
          for (tbl in step$rows_input) {
            log_info("{input_schema}.{tbl}: {row_count(con, input_schema, tbl)} rows")
          }
        }

        # Run the SQL file with schema replacements
        run_sql_file(
          con = con,
          file_path = path,
          replacements = list(
            INPUT_SCHEMA = input_schema,
            OUTPUT_SCHEMA = output_schema,
            EXT_VOCAB_SCHEMA = ext_vocab_schema,
            CDM_ETL_REFERENCE = cdm_etl_reference
          )
        )

        if (!is.null(step$rows_output)) {
          for (tbl in step$rows_output) {
            log_info("{output_schema}.{tbl}: {row_count(con, output_schema, tbl)} rows")
          }
        }
      })

      successful_files <- successful_files + 1L
    }

    run_status <- "completed"
    failed_files <- files_processed - successful_files
  }, error = function(e) {
    run_status <<- "failed"
    run_error <<- conditionMessage(e)
    failed_files <<- files_processed - successful_files
    log_error("An error occurred: {e$message}")
    stop(e)
  }, finally = {
    if (!is.null(con) && !is.null(runs_table_id) && !is.null(run_id)) {
      finish_etl_run(
        con = con,
        table_id = runs_table_id,
        run_id = run_id,
        status = run_status,
        files_processed = files_processed,
        successful_files = successful_files,
        failed_files = max(0L, failed_files),
        error_message = run_error
      )
      log_info("Updated ETL run record with run_id={run_id}, status={run_status}")
    }

    disconnect_if_open(con)
    log_info("Database connection closed.")
  })
}

if (sys.nframe() == 0) {
  main()
}
