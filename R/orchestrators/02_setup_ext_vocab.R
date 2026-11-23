# this script creates conversion tables for vocabularies not supported by Athena/Usagi
#
# Required packages: dotenv, DBI

source("R/utils/helpers.R")
source("R/utils/logging.R")
source("R/utils/external_vocab_tracking.R")
source("R/db/connect.R")
source("R/config/settings.R")

library(DBI)
library(yaml)
library(renv)

main <- function(config_path = NULL) {
  # Load settings and setup logging
  config_path <- resolve_config_path(config_path)
  config_path <- normalizePath(config_path, winslash = "/", mustWork = TRUE)
  project_root <- normalizePath(file.path(dirname(config_path), ".."), winslash = "/", mustWork = TRUE)
  settings <- read_settings(config_path)
  log_dir <- get_setting_or_default(settings, c("project", "log_dir"), "logs")
  setup_logging(log_dir = log_dir, prefix = "run_setup_ext_vocab")

  # Get configuration values with defaults
  metadata_schema <- validate_schema(
    get_setting_or_default(settings, c("schemas", "metadata_schema"), "metadata")
  )
  ext_vocab_schema <- validate_schema(
    get_setting_or_default(settings, c("schemas", "ext_vocab_schema"), "ext_vocab")
  )
  # Input schema: the VARUNR mapping reads product descriptors from its lmed table
  input_schema <- validate_schema(
    get_setting_or_default(settings, c("schemas", "INPUT_SCHEMA"), "raw")
  )
  # CDM schema: where 01_setup_CDM.R loaded the Athena vocabulary (concept,
  # concept_relationship), read by the ICD-10 mapping steps
  cdm_schema <- validate_schema(
    get_setting_or_default(settings, c("schemas", "cdm_schema"), "omop54")
  )
  ext_vocab_sql_replacements <- list(
    EXT_VOCAB_SCHEMA = ext_vocab_schema,
    INPUT_SCHEMA = input_schema,
    CDM_SCHEMA = cdm_schema
  )
  nplid_csv_path <- get_setting_or_default(
    settings,
    c("vocabularies", "external", "nplid_to_rxnorm_csv_path"),
    "D:/Vocabularies/nplid_to_drug_exposure.csv"
  )
  # Socialstyrelsen's ICD-10-SE code list; the mapping to ICD-10 is built in SQL
  # (ext_vocab_2_icd10se_icd10.sql)
  icd10se_codes_path <- get_setting_or_default(
    settings,
    c("vocabularies", "external", "icd10se_codes_tsv_path"),
    "D:/Vocabularies/Vocabularies mapping/ICD10-SE to ICD10-WHO/icd-10-se.tsv"
  )
  # Project's TPR/LISA mapping, kept in the repository; a relative path is read from the project root
  lisa_tpr_map_path <- get_setting_or_default(
    settings,
    c("vocabularies", "external", "lisa_tpr_map_csv_path"),
    "vocabularies/external/tpr_lisa_external_vocab.csv"
  )
  if (!grepl("^([A-Za-z]:)?[/\\\\]", lisa_tpr_map_path)) {
    lisa_tpr_map_path <- file.path(project_root, lisa_tpr_map_path)
  }
  # Get sql folder path
  sql_dir <- get_setting_or_default(settings, c("sql_paths", "external_vocabularies"), "sql")
  sql_dir <- normalizePath(file.path(project_root, sql_dir), winslash = "/", mustWork = TRUE)

  files <- stage_external_vocab_files(c(
    nplid = nplid_csv_path,
    icd10 = icd10se_codes_path,
    lisa_tpr_map = lisa_tpr_map_path
  ))
  on.exit(unlink(files$staged_paths), add = TRUE)
  con <- NULL
  loads_table_id <- NULL
  load_id <- NULL

  tryCatch({
    # Connect to the database
    con <- connect_source_db(config_path)
    lock_external_vocab_schema(con, ext_vocab_schema)
    loads_table_id <- ensure_ext_vocab_loads_table(con, metadata_schema)
    load_id <- start_external_vocab_load(con, loads_table_id, ext_vocab_schema, files)
    log_info("Created external vocabulary load record with load_id={load_id}")

    # Create ext_vocab schema and tables
    sql_file_path <- file.path(sql_dir, "ext_vocab_1a_varunr_rxnorm.sql")
    time_step("Create ext_vocab schema", {
      run_sql_file(
        con = con,
        file_path = sql_file_path,
        replacements = ext_vocab_sql_replacements
      )
    })

    # Load nplid to rxnorm mapping
    time_step("Load nplid to rxnorm mapping", {
      df <- load_csv_xlsx_or_stop(files$staged_paths[["nplid"]], sep = ";", as_text = TRUE)
      DBI::dbWriteTable(
        con,
        DBI::Id(schema = ext_vocab_schema, table = "nplid_rxnorm"),
        df,
        append = TRUE,
        row.names = FALSE
      )
      rm(df)
      gc(verbose = FALSE)
    })

    # Create varunr to rxnorm mapping using the loaded nplid_rxnorm table
    sql_file_path <- file.path(sql_dir, "ext_vocab_1_varunr_rxnorm.sql")
    time_step("Create varunr rxnorm mapping", {
      run_sql_file(
        con = con,
        file_path = sql_file_path,
        replacements = ext_vocab_sql_replacements
      )
    })

    # Load Socialstyrelsen's ICD-10-SE code list
    time_step("Load ICD-10-SE code list", {
      df <- load_icd10se_codes_or_stop(files$staged_paths[["icd10"]])
      DBI::dbWriteTable(
        con,
        DBI::Id(schema = ext_vocab_schema, table = "icd10se_codes"),
        df,
        overwrite = TRUE,
        row.names = FALSE
      )
      log_info("ICD-10-SE code list: {nrow(df)} rows loaded from {basename(icd10se_codes_path)}")
      rm(df)
      gc(verbose = FALSE)
    })

    # Map ICD-10-SE codes to ICD10 codes of the CDM vocabulary (truncation to the
    # nearest valid parent code)
    sql_file_path <- file.path(sql_dir, "ext_vocab_2_icd10se_icd10.sql")
    time_step("Create ICD10-SE to ICD10 mapping", {
      run_sql_file(
        con = con,
        file_path = sql_file_path,
        replacements = ext_vocab_sql_replacements
      )
    })

    sql_file_path <- file.path(sql_dir, "ext_vocab_3_icd10se_who_snomed.sql")
    time_step("Create ICD10-SE WHO SNOMED mapping", {
      run_sql_file(
        con = con,
        file_path = sql_file_path,
        replacements = ext_vocab_sql_replacements
      )
    })

    sql_file_path <- file.path(sql_dir, "ext_vocab_4_icd10who_snomed.sql")
    time_step("Create ICD10 WHO SNOMED mapping", {
      run_sql_file(
        con = con,
        file_path = sql_file_path,
        replacements = ext_vocab_sql_replacements
      )
    })

    # Load the TPR/LISA mapping (read by 07_grunduppgifter_lisa_to_observation.sql);
    # the file is checked for duplicate codes before anything is written
    time_step("Load TPR/LISA mapping", {
      df <- load_lisa_tpr_map_or_stop(files$staged_paths[["lisa_tpr_map"]])
      run_sql_file(
        con = con,
        file_path = file.path(sql_dir, "ext_vocab_5_lisa_tpr_map.sql"),
        replacements = ext_vocab_sql_replacements
      )
      DBI::dbWriteTable(
        con,
        DBI::Id(schema = ext_vocab_schema, table = "lisa_tpr_map"),
        df,
        append = TRUE,
        row.names = FALSE
      )
      log_info("TPR/LISA mapping: {nrow(df)} rows loaded from {basename(lisa_tpr_map_path)}")
      rm(df)
    })
    fingerprint <- ext_vocab_table_fingerprint(con, ext_vocab_schema)
    finish_external_vocab_load(con, loads_table_id, load_id, "completed", fingerprint = fingerprint)
    log_info("Completed external vocabulary load with load_id={load_id}")
    load_id <- NULL
  }, error = function(e) {
    if (!is.null(con) && !is.null(load_id)) {
      finish_external_vocab_load(con, loads_table_id, load_id, "failed", conditionMessage(e))
    }
    log_error("An error occurred: {e$message}")
    stop(e)
  }, finally = {
    disconnect_if_open(con)
    log_info("Database connection closed.")
  })
}

if (sys.nframe() == 0) {
  main()
}
