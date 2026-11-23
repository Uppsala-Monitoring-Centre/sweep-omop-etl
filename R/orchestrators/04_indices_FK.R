# Create indexes and foreign keys ---------------------------------------------

source("R/utils/helpers.R")
source("R/utils/logging.R")
source("R/db/connect.R")
source("R/config/settings.R")

library(CommonDataModel)
library(DBI)
library(SqlRender)
library(renv)

split_sql_statements <- function(sql) {
  parts <- strsplit(sql, ";", fixed = TRUE)[[1]]
  statements <- trimws(parts)
  statements[nzchar(statements)]
}

constraint_exists <- function(con, schema, constraint_name) {
  # RPostgres only supports positional ($1, $2) placeholders, not named (?name).
  sql <- paste(
    "SELECT 1",
    "FROM information_schema.table_constraints",
    "WHERE constraint_schema = $1",
    "  AND constraint_name = $2",
    "LIMIT 1"
  )

  result <- DBI::dbGetQuery(
    con,
    sql,
    params = list(schema, constraint_name)
  )

  nrow(result) > 0
}

extract_constraint_name <- function(statement) {
  matches <- regmatches(
    statement,
    regexec("ADD CONSTRAINT\\s+([^\\s]+)", statement, ignore.case = TRUE)
  )

  if (length(matches[[1]]) < 2) {
    return(NULL)
  }

  matches[[1]][2]
}

make_constraint_not_valid <- function(statement) {
  if (grepl("NOT VALID\\s*$", statement, ignore.case = TRUE)) {
    return(statement)
  }

  sub("\\s*$", " NOT VALID", statement)
}

apply_foreign_key_statements <- function(con, schema, fk_sql) {
  statements <- split_sql_statements(fk_sql)

  for (statement in statements) {
    constraint_name <- extract_constraint_name(statement)

    if (is.null(constraint_name)) {
      log_info("Skipping non-constraint statement in FK SQL.")
      next
    }

    if (constraint_exists(con, schema, constraint_name)) {
      log_info("Skipping existing foreign key: {constraint_name}")
      next
    }

    DBI::dbExecute(
      con,
      paste0(make_constraint_not_valid(statement), ";"),
      immediate = TRUE
    )
  }
}

main <- function(config_path = NULL) {
  config_path <- resolve_config_path(config_path)
  settings <- read_settings(config_path)
  log_dir <- get_setting_or_default(settings, c("project", "log_dir"), "logs")
  setup_logging(log_dir = log_dir, prefix = "run_indices_fk")

  cdm_schema <- get_setting_or_default(settings, c("schemas", "cdm_schema"), "omop100k")
  cdm_version <- get_setting_or_default(settings, c("schemas", "cdm_version"), "5.4")
  sql_dir <- get_setting_or_default(settings, c("sql_paths", "indices"), "sql")

  con <- NULL

  tryCatch({
    con <- connect_source_db(config_path)

    time_step("Generate and apply indexes", {
      # Generate index SQL files
      CommonDataModel::writeIndex(
        targetDialect = "postgresql",
        cdmVersion = cdm_version,
        outputfolder = sql_dir,
        cdmDatabaseSchema = cdm_schema
      )

      # Create a list of indices
      idx_files <- list.files(
        sql_dir,
        pattern = "index|indices",
        recursive = TRUE,
        full.names = TRUE,
        ignore.case = TRUE
      )

      if (length(idx_files) == 0) {
        log_error("No index SQL files found in: {sql_dir}")
        stop(sprintf("No index SQL files found in: %s", sql_dir))
      }

      # Apply index SQL files
      idx_sql <- paste(readLines(idx_files[1], warn = FALSE), collapse = "\n")
      if (grepl("@cdmDatabaseSchema", idx_sql, fixed = TRUE)) {
        idx_sql <- SqlRender::render(idx_sql, cdmDatabaseSchema = cdm_schema)
      }
      idx_sql <- gsub(
        "(?m)^CREATE (UNIQUE )?INDEX",
        "CREATE \\1INDEX IF NOT EXISTS",
        idx_sql,
        perl = TRUE
      )
      DBI::dbExecute(con, idx_sql, immediate = TRUE)
    })

    # Create foreign keys
    time_step("Create foreign keys", {
      fk <- CommonDataModel::createForeignKeys(cdmVersion = cdm_version)
      fk_pg <- fk |>
        SqlRender::render(cdmDatabaseSchema = cdm_schema) |>
        SqlRender::translate(targetDialect = "postgresql")
      apply_foreign_key_statements(con, cdm_schema, fk_pg)
    })
  }, error = function(e) {
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
