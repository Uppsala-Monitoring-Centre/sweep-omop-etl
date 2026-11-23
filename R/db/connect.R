source("R/utils/helpers.R")
source("R/utils/logging.R")

library(DBI)
library(RPostgres)
library(logger)


resolve_db_user <- function(db_config, default_env_var = NULL) {
  user_value <- db_config$user
  user_env <- db_config$user_env

  # Backward compatibility: allow user to reference an env var by name.
  # Example: user: "DB_USER" will resolve Sys.getenv("DB_USER") when set.
  resolve_user_alias <- function(candidate) {
    if (is.null(candidate) || !nzchar(candidate)) {
      return(NULL)
    }

    env_value <- Sys.getenv(candidate, unset = "")
    if (nzchar(env_value)) {
      return(env_value)
    }

    NULL
  }

  if (!is.null(user_value) && nzchar(user_value)) {
    aliased_user <- resolve_user_alias(user_value)
    if (!is.null(aliased_user)) {
      return(aliased_user)
    }
    return(user_value)
  }

  if (!is.null(user_env) && nzchar(user_env)) {
    user_from_env <- Sys.getenv(user_env)
    if (nzchar(user_from_env)) {
      return(user_from_env)
    }
    stop(sprintf("Environment variable %s is not set.", user_env))
  }

  if (!is.null(default_env_var) && nzchar(default_env_var)) {
    user_from_default_env <- Sys.getenv(default_env_var)
    if (nzchar(user_from_default_env)) {
      return(user_from_default_env)
    }
  }

  stop(
    "Database user is not set. Provide source_db.user, source_db.user_env, or set env var referenced by source_db.user."
  )
}

resolve_db_password <- function(db_config) {
  password_env <- db_config$password_env
  if (!is.null(password_env) && nzchar(password_env)) {
    password_value <- Sys.getenv(password_env)
    if (nzchar(password_value)) {
      return(password_value)
    }
    log_error("Database password environment variable %s is not set.", password_env)
    stop(sprintf("Environment variable %s is not set.", password_env))
  }
  NULL
}


get_db_connection <- function(db_config) {
  user_value <- resolve_db_user(db_config)
  password_value <- resolve_db_password(db_config)

  DBI::dbConnect(
    RPostgres::Postgres(),
    host = db_config$host,
    port = db_config$port,
    dbname = db_config$dbname,
    user = user_value,
    password = password_value
  )
}

connect_source_db <- function(config_path = NULL) {
  settings <- read_settings(config_path)
  get_db_connection(settings$source_db)
}

connect_target_db <- function(config_path = NULL) {
  settings <- read_settings(config_path)
  get_db_connection(settings$target_db)
}

disconnect_if_open <- function(con) {
  if (!is.null(con)) {
    try(
      {
        DBI::dbDisconnect(con)
      },
      silent = TRUE
    )
  }
}
