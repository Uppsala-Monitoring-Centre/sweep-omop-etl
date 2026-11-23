# this script creates the sample of data to be used during the OMOP CDM mapping workshop
# it randomly samples sample_size (from settings.yml file) Lopnrs from the TPR (grunduppgifter) and
# selected all the records related to these Lopnrs in the other tables.
#
# Required packages: DBI, RPostgres

library(DBI)
library(RPostgres)
library(renv)

source("R/utils/logging.R")
source("R/utils/helpers.R")
source("R/db/connect.R")
source("R/config/settings.R")


resolve_sampling_schemas <- function(settings) {
  input_schema <- get_setting_or_default(
    settings,
    c("sampling", "input_schema"),
    get_setting_or_default(
      settings,
      c("schemas", "INPUT_SCHEMA_SAMPLE"),
      get_setting_or_default(settings, c("schemas", "INPUT_SCHEMA"), "")
    )
  )

  output_schema <- get_setting_or_default(
    settings,
    c("sampling", "output_schema"),
    get_setting_or_default(
      settings,
      c("schemas", "OUTPUT_SCHEMA_SAMPLE"),
      get_setting_or_default(settings, c("schemas", "OUTPUT_SCHEMA"), "")
    )
  )

  if (is.null(input_schema) || !nzchar(input_schema)) {
    stop("Sampling input schema is not set. Configure sampling.input_schema in settings.yaml.")
  }

  if (is.null(output_schema) || !nzchar(output_schema)) {
    stop("Sampling output schema is not set. Configure sampling.output_schema in settings.yaml.")
  }

  list(
    input_schema = input_schema,
    output_schema = output_schema
  )
}

resolve_sampling_databases <- function(settings) {
  source_db <- settings$source_db
  if (is.null(source_db)) {
    stop("source_db section is missing in settings.yaml.")
  }

  source_dbname <- source_db$dbname
  if (is.null(source_dbname) || !nzchar(source_dbname)) {
    stop("source_db.dbname is not set in settings.yaml.")
  }

  input_dbname <- get_setting_or_default(settings, c("sampling", "input_dbname"), source_dbname)
  output_dbname <- get_setting_or_default(settings, c("sampling", "output_dbname"), source_dbname)

  if (is.null(input_dbname) || !nzchar(input_dbname)) {
    stop("Sampling input database is not set. Configure sampling.input_dbname in settings.yaml.")
  }

  if (is.null(output_dbname) || !nzchar(output_dbname)) {
    stop("Sampling output database is not set. Configure sampling.output_dbname in settings.yaml.")
  }

  input_db <- source_db
  input_db$dbname <- input_dbname
  input_password_env <- get_setting_or_default(settings, c("sampling", "input_password_env"), input_db$password_env)
  input_db$password_env <- input_password_env

  output_db <- source_db
  output_db$dbname <- output_dbname
  output_password_env <- get_setting_or_default(settings, c("sampling", "output_password_env"), output_db$password_env)
  output_db$password_env <- output_password_env

  list(
    input_db = input_db,
    output_db = output_db
  )
}

resolve_sampling_fdw_settings <- function(settings, sampling_schemas) {
  list(
    auto_setup = isTRUE(get_setting_or_default(settings, c("sampling", "fdw_auto_setup"), FALSE)),
    server_name = get_setting_or_default(settings, c("sampling", "fdw_server_name"), "sampling_input_db_server"),
    local_schema = get_setting_or_default(settings, c("sampling", "fdw_local_schema"), sampling_schemas$input_schema)
  )
}

quote_ident <- function(con, value) {
  as.character(DBI::dbQuoteIdentifier(con, value))
}

quote_lit <- function(con, value) {
  as.character(DBI::dbQuoteString(con, value))
}

setup_sampling_fdw <- function(con, input_db, input_schema, fdw_settings, required_tables) {
  if (is.null(fdw_settings$server_name) || !nzchar(fdw_settings$server_name)) {
    stop("sampling.fdw_server_name must be a non-empty string when sampling.fdw_auto_setup is true.")
  }
  if (is.null(fdw_settings$local_schema) || !nzchar(fdw_settings$local_schema)) {
    stop("sampling.fdw_local_schema must be a non-empty string when sampling.fdw_auto_setup is true.")
  }

  remote_user <- resolve_db_user(input_db, default_env_var = "DB_USER")
  remote_password <- NULL
  if (!is.null(input_db$password_env) && nzchar(input_db$password_env)) {
    remote_password <- resolve_db_password(input_db)
  }

  server_q <- quote_ident(con, fdw_settings$server_name)
  local_schema_q <- quote_ident(con, fdw_settings$local_schema)
  remote_schema_ident <- quote_ident(con, input_schema)
  host_lit <- quote_lit(con, as.character(input_db$host))
  port_lit <- quote_lit(con, as.character(input_db$port))
  dbname_lit <- quote_lit(con, as.character(input_db$dbname))
  remote_user_lit <- quote_lit(con, remote_user)

  DBI::dbExecute(con, "CREATE EXTENSION IF NOT EXISTS postgres_fdw")

  # Ensure server options are in sync with current settings instead of relying
  # on stale objects from previous runs.
  DBI::dbExecute(con, sprintf("DROP SERVER IF EXISTS %s CASCADE", server_q))

  DBI::dbExecute(
    con,
    sprintf(
      "CREATE SERVER IF NOT EXISTS %s FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %s, port %s, dbname %s)",
      server_q,
      host_lit,
      port_lit,
      dbname_lit
    )
  )

  # Recreate mapping for CURRENT_USER to avoid stale remote user/password.
  DBI::dbExecute(
    con,
    sprintf("DROP USER MAPPING IF EXISTS FOR CURRENT_USER SERVER %s", server_q)
  )

  if (!is.null(remote_password) && nzchar(remote_password)) {
    remote_password_lit <- quote_lit(con, remote_password)
    DBI::dbExecute(
      con,
      sprintf(
        "CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER %s OPTIONS (user %s, password %s)",
        server_q,
        remote_user_lit,
        remote_password_lit
      )
    )
  } else {
    # Explicitly allow passwordless FDW auth when pg_hba for the remote DB
    # supports it (for example trust, sspi, or peer on local setups).
    DBI::dbExecute(
      con,
      sprintf(
        paste(
          "CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER %s",
          "OPTIONS (user %s, password_required 'false')"
        ),
        server_q,
        remote_user_lit
      )
    )
  }

  DBI::dbExecute(con, sprintf("CREATE SCHEMA IF NOT EXISTS %s", local_schema_q))

  missing_tables <- character(0)
  for (tbl in required_tables) {
    relname <- paste0(fdw_settings$local_schema, ".", tbl)
    relname_sql <- quote_lit(con, relname)
    exists_query <- sprintf("SELECT to_regclass(%s) IS NOT NULL AS exists", relname_sql)
    exists_flag <- isTRUE(DBI::dbGetQuery(con, exists_query)$exists[[1]])
    if (!exists_flag) {
      missing_tables <- c(missing_tables, tbl)
    }
  }

  if (length(missing_tables) > 0) {
    missing_table_idents <- paste(vapply(missing_tables, quote_ident, character(1), con = con), collapse = ", ")
    import_sql <- sprintf(
      "IMPORT FOREIGN SCHEMA %s LIMIT TO (%s) FROM SERVER %s INTO %s",
      remote_schema_ident,
      missing_table_idents,
      server_q,
      local_schema_q
    )

    tryCatch(
      {
        DBI::dbExecute(con, import_sql)
      },
      error = function(err) {
        err_msg <- conditionMessage(err)
        if (grepl("could not connect to server", err_msg, ignore.case = TRUE)) {
          no_password_cfg <- is.null(remote_password) || !nzchar(remote_password)
          guidance <- if (no_password_cfg) {
            paste0(
              "No FDW password is configured (source_db.password_env is empty). ",
              "For passwordless cross-database FDW, pg_hba.conf for the input database must allow ",
              "this connection (for example trust/SSPI for the mapped user and source host)."
            )
          } else {
            "A password is configured, so verify pg_hba/auth settings and password correctness for the input database."
          }

          stop(
            paste0(
              "FDW import failed while connecting to server ",
              fdw_settings$server_name,
              ". ",
              guidance,
              "\nPostgreSQL error: ",
              err_msg
            ),
            call. = FALSE
          )
        }

        stop(err)
      }
    )
  }
}

ensure_sampling_source_tables <- function(con, input_schema) {
  required_tables <- sampling_required_tables()

  missing_tables <- character(0)

  for (tbl in required_tables) {
    relation_name <- paste0(input_schema, ".", tbl)
    relation_sql <- as.character(DBI::dbQuoteString(con, relation_name))
    exists_query <- sprintf("SELECT to_regclass(%s) IS NOT NULL AS exists", relation_sql)
    exists_flag <- isTRUE(DBI::dbGetQuery(con, exists_query)$exists[[1]])
    if (!exists_flag) {
      missing_tables <- c(missing_tables, relation_name)
    }
  }

  if (length(missing_tables) > 0) {
    stop(
      paste0(
        "Sampling source tables are not available in the execution database. Missing: ",
        paste(missing_tables, collapse = ", "),
        "\nIf input and output databases differ, expose input tables in this database ",
        "(for example via postgres_fdw foreign tables)."
      )
    )
  }
}

sampling_required_tables <- function() {
  c(
    "grunduppgifter",
    "lmed",
    "par_sv",
    "par_ov",
    "dors",
    "migrationer",
    "can",
    "lisa_2005",
    "lisa_2006",
    "lisa_2007",
    "lisa_2008",
    "lisa_2009",
    "lisa_2010",
    "lisa_2011",
    "lisa_2012",
    "lisa_2013",
    "lisa_2014",
    "lisa_2015",
    "lisa_2016",
    "lisa_2017",
    "lisa_2018",
    "lisa_2019",
    "lisa_2020",
    "lisa_2021",
    "lisa_2022",
    "lisa_2023"
  )
}


main <- function(config_path = NULL, dry_run = FALSE) {
  # Load settings and setup logging
  config_path <- resolve_config_path(config_path)
  config_path <- normalizePath(config_path, winslash = "/", mustWork = TRUE)
  project_root <- normalizePath(file.path(dirname(config_path), ".."), winslash = "/", mustWork = TRUE)
  settings <- read_settings(config_path)
  log_dir <- get_setting_or_default(settings, c("project", "log_dir"), "logs")
  setup_logging(log_dir = log_dir, prefix = "run_sample_generator")
  sql_dir <- get_setting_or_default(settings, c("sql_paths", "sampling"), "sql")
  sql_file_path <- normalizePath(file.path(project_root, sql_dir, "sample_generator.sql"),
    winslash = "/",
    mustWork = TRUE
  )
  sampling_schemas <- resolve_sampling_schemas(settings)
  sampling_dbs <- resolve_sampling_databases(settings)
  sampling_fdw <- resolve_sampling_fdw_settings(settings, sampling_schemas)
  effective_input_schema <- sampling_schemas$input_schema
  required_tables <- sampling_required_tables()
  source_tables_verified <- FALSE

  con_src <- NULL

  tryCatch({
    # Run sampling SQL in the output database.
    con_src <- get_db_connection(sampling_dbs$output_db)

    if (sampling_dbs$input_db$dbname != sampling_dbs$output_db$dbname) {
      log_warn(sprintf(
        paste0(
          "Sampling input database (%s) differs from output database (%s). ",
          "Input schema must be accessible from output DB (e.g. postgres_fdw)."
        ),
        sampling_dbs$input_db$dbname,
        sampling_dbs$output_db$dbname
      ))

      if (sampling_fdw$auto_setup) {
        effective_input_schema <- sampling_fdw$local_schema
        required_tables <- sampling_required_tables()

        time_step("Setup postgres_fdw for sampling", {
          setup_sampling_fdw(
            con = con_src,
            input_db = sampling_dbs$input_db,
            input_schema = sampling_schemas$input_schema,
            fdw_settings = sampling_fdw,
            required_tables = required_tables
          )
        })

        source_tables_verified <- TRUE
      }
    }

    if (!source_tables_verified) {
      ensure_sampling_source_tables(con_src, effective_input_schema)
    }

    # Run query
    time_step("Generate sample dataset", {
      run_sql_file(
        con = con_src,
        file_path = sql_file_path,
        replacements = list(
          INPUT_SCHEMA_SAMPLE = effective_input_schema,
          OUTPUT_SCHEMA_SAMPLE = sampling_schemas$output_schema,
          SAMPLE_SIZE = settings$run$sample_size,
          USE_INDEX = ifelse(settings$run$use_index, "TRUE", "FALSE")
        ),
        block_conditions = list(
          INDEX = function(repl) toupper(repl$USE_INDEX) != "TRUE"
        )
      )
    })
  }, error = function(e) {
    log_error("An error occurred: {e$message}")
  }, finally = {
    if (!is.null(con_src)) {
      disconnect_if_open(con_src)
      log_info("Database connection closed.")
    }
  })
}

# Run only if script is executed directly
if (sys.nframe() == 0) {
  main()
}
