# This script sets up the OMOP CDM schema and loads vocabularies using psql
# for better performance.
# It creates the CDM tables using the CommonDataModel package and then loads
# the Athena vocabulary files into the database.
# Required packages: CommonDataModel, DBI, RPostgres, yaml

source("R/utils/helpers.R")
source("R/utils/logging.R")
source("R/db/connect.R")
source("R/config/settings.R")

library(CommonDataModel)
library(DBI)
library(yaml)
library(renv)


quote_ident <- function(x) {
  paste0('"', gsub('"', '""', x), '"')
}

normalize_for_psql <- function(x) {
  gsub("\\\\", "/", normalizePath(x, winslash = "/", mustWork = TRUE))
}

escape_sql_string <- function(x) {
  gsub("'", "''", x, fixed = TRUE)
}

build_vocab_copy_sql <- function(schema_name, vocab_files, full_paths) {
  copy_commands <- mapply(
    FUN = function(table, file) {
      sprintf(
        "\\copy %s.%s FROM '%s' WITH (FORMAT csv, DELIMITER E'\\t', HEADER true, QUOTE E'\\b', NULL '');",
        quote_ident(schema_name),
        quote_ident(table),
        escape_sql_string(normalize_for_psql(file))
      )
    },
    table = names(vocab_files),
    file = full_paths,
    USE.NAMES = FALSE
  )

  c("\\set ON_ERROR_STOP on", "\\encoding UTF8", copy_commands)
}


resolve_psql <- function(settings) {
  psql_path <- get_setting_or_default(settings, c("tools", "psql"), Sys.getenv("PSQL"))
  if (is.null(psql_path) || !nzchar(psql_path)) {
    psql_path <- Sys.which("psql")
  }

  if (!nzchar(psql_path)) {
    log_error("psql was not found on PATH. Configure tools.psql in settings.yaml or set PSQL.")
    stop(
      "psql was not found on PATH. Configure tools.psql in settings.yaml or set PSQL.\n",
      "Example: tools: { psql: 'C:/Program Files/PostgreSQL/18/bin/psql.exe' }"
    )
  }

  psql_path
}

main <- function(config_path = NULL) {
  # Load settings and setup logging
  config_path <- resolve_config_path(config_path)
  config_path <- normalizePath(config_path, winslash = "/", mustWork = TRUE)
  project_root <- normalizePath(file.path(dirname(config_path), ".."), winslash = "/", mustWork = TRUE)
  settings <- read_settings(config_path)
  log_dir <- get_setting_or_default(settings, c("project", "log_dir"), "logs")
  setup_logging(log_dir = log_dir, prefix = "run_setup_cdm")

  # Get configuration values with defaults
  cdm_schema <- get_setting_or_default(settings, c("schemas", "cdm_schema"), "omop500k_v2")
  cdm_version <- get_setting_or_default(settings, c("schemas", "cdm_version"), "5.4")
  vocab_dir_path <- get_setting_or_default(settings, c("vocabularies", "dir_path"), "D:/Athena_Vocabularies")
  host <- get_setting_or_default(settings, c("source_db", "host"), Sys.getenv("DB_HOST"))
  port <- get_setting_or_default(settings, c("source_db", "port"), Sys.getenv("DB_PORT"))
  user <- resolve_db_user(settings$source_db, default_env_var = "DB_USER")
  dbname <- get_setting_or_default(settings, c("source_db", "dbname"), Sys.getenv("DB_DATABASE"))

  # Define expected vocabulary files and their corresponding tables
  vocab_files <- c(
    domain = "DOMAIN.csv",
    concept_class = "CONCEPT_CLASS.csv",
    relationship = "RELATIONSHIP.csv",
    vocabulary = "VOCABULARY.csv",
    concept = "CONCEPT.csv",
    concept_relationship = "CONCEPT_RELATIONSHIP.csv",
    concept_ancestor = "CONCEPT_ANCESTOR.csv",
    concept_synonym = "CONCEPT_SYNONYM.csv",
    drug_strength = "DRUG_STRENGTH.csv"
  )

  con <- NULL
  tryCatch({
    # Connect to the database
    con <- connect_source_db(config_path)

    # Create OMOP CDM schema
    time_step("Create OMOP schema", {
      schema_id <- as.character(DBI::dbQuoteIdentifier(con, cdm_schema))
      DBI::dbExecute(con, sprintf("DROP SCHEMA IF EXISTS %s CASCADE", schema_id))
      DBI::dbExecute(con, sprintf("CREATE SCHEMA IF NOT EXISTS %s", schema_id))

      ddl <- CommonDataModel::createDdl(cdmVersion = cdm_version)
      ddl_pg <- ddl |>
        SqlRender::render(cdmDatabaseSchema = cdm_schema) |>
        SqlRender::translate(targetDialect = "postgresql")
      DBI::dbExecute(con, ddl_pg, immediate = TRUE)
      schema_sql <- gsub('^"+|"+$', "", trimws(cdm_schema))

      bigint_columns <- list(
        person = c("person_id"),
        death = c("person_id"),
        drug_exposure = c("person_id", "drug_exposure_id"),
        visit_occurrence = c("person_id", "visit_occurrence_id"),
        observation_period = c("person_id", "observation_period_id"),
        condition_occurrence = c("person_id", "visit_occurrence_id", "condition_occurrence_id"),
        observation = c("person_id", "visit_occurrence_id", "observation_id"),
        procedure_occurrence = c("person_id", "visit_occurrence_id", "procedure_occurrence_id"),
        measurement = c("person_id", "visit_occurrence_id", "measurement_id"),
        drug_era = c("person_id", "drug_era_id"),
        condition_era = c("person_id", "condition_era_id")
      )

      quote_table <- function(con, schema, table) {
        paste0(
          dbQuoteIdentifier(con, schema),
          ".",
          dbQuoteIdentifier(con, table)
        )
      }

      quote_col <- function(con, col) {
        as.character(dbQuoteIdentifier(con, col))
      }

      make_alter_sql <- function(con, schema, table, columns) {
        table_name <- quote_table(con, schema, table)

        alter_clauses <- vapply(
          columns,
          function(col) {
            col_q <- quote_col(con, col)

            sprintf(
              "ALTER COLUMN %s TYPE BIGINT USING %s::BIGINT",
              col_q,
              col_q
            )
          },
          character(1)
        )

        sprintf(
          "ALTER TABLE %s\n  %s;",
          table_name,
          paste(alter_clauses, collapse = ",\n  ")
        )
      }

      sql <- paste(
        Map(
          function(table, columns) {
            make_alter_sql(con, schema_sql, table, columns)
          },
          names(bigint_columns),
          bigint_columns
        ),
        collapse = "\n\n"
      )

      DBI::dbWithTransaction(con, {
        DBI::dbExecute(con, sql, immediate = TRUE)
      })
    })

    # Load vocabularies using psql for better performance
    time_step("Upload vocabularies", {
      if (!dir.exists(vocab_dir_path)) {
        log_error("Vocabulary directory not found: {vocab_dir_path}")
        stop(sprintf("Vocabulary directory not found: %s", vocab_dir_path))
      }

      full_paths <- file.path(vocab_dir_path, vocab_files)
      missing_files <- full_paths[!file.exists(full_paths)]

      if (length(missing_files) > 0) {
        log_error("These Athena files are missing:\n{paste(missing_files, collapse = '\n')}")
        stop(
          "These Athena files are missing:\n",
          paste(missing_files, collapse = "\n")
        )
      }

      # Load vocabularies using psql for better performance
      load_sql <- build_vocab_copy_sql(cdm_schema, vocab_files, full_paths)
      sql_file <- tempfile(fileext = ".sql")
      on.exit(unlink(sql_file, force = TRUE), add = TRUE)
      writeLines(load_sql, sql_file, useBytes = TRUE)

      psql <- resolve_psql(settings)

      # Extract connection details for psql
      args <- c(
        "-h", host,
        "-p", port,
        "-U", user,
        "-d", dbname,
        "-f", sql_file
      )


      log_info("Running psql to load vocabularies")
      result <- system2(psql, args = args)
      if (result != 0) {
        log_error("Vocabulary load failed with exit code {result}.")
        stop("Vocabulary load failed. Check the psql output above.")
      }
    })

    # Validate that vocabularies were loaded
    time_step("Validate vocabularies", {
      schema_quoted <- quote_ident(cdm_schema)
      counts <- DBI::dbGetQuery(
        con,
        sprintf(
          "
          SELECT 'concept' AS table_name, COUNT(*) AS n FROM %s.concept
          UNION ALL
          SELECT 'concept_relationship', COUNT(*) FROM %s.concept_relationship
          UNION ALL
          SELECT 'concept_ancestor', COUNT(*) FROM %s.concept_ancestor
          UNION ALL
          SELECT 'concept_synonym', COUNT(*) FROM %s.concept_synonym
          UNION ALL
          SELECT 'drug_strength', COUNT(*) FROM %s.drug_strength
          UNION ALL
          SELECT 'vocabulary', COUNT(*) FROM %s.vocabulary
          ORDER BY table_name;
          ",
          schema_quoted,
          schema_quoted,
          schema_quoted,
          schema_quoted,
          schema_quoted,
          schema_quoted
        )
      )

      log_info("Vocabulary record counts:\n{paste(counts$table_name, counts$n, sep=': ', collapse='\n')}")
    })

    # Create primary keys
    time_step("Create primary keys", {
      pk <- CommonDataModel::createPrimaryKeys(cdmVersion = cdm_version)
      pk_pg <- pk |>
        SqlRender::render(cdmDatabaseSchema = cdm_schema) |>
        SqlRender::translate(targetDialect = "postgresql")
      DBI::dbExecute(con, pk_pg, immediate = TRUE)
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
