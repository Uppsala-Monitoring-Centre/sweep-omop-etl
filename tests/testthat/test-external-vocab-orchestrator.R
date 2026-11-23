test_that("external vocabulary setup uses the configured metadata schema", {
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(project_root)
  env <- new.env(parent = globalenv())
  sys.source(file.path(project_root, "R", "orchestrators", "02_setup_ext_vocab.R"), envir = env)
  schema_seen <- NULL

  env$read_settings <- function(...) {
    list(schemas = list(metadata_schema = "metadata_custom"), sql_paths = list(
      external_vocabularies = "sql/external_vocabularies"
    ))
  }
  env$setup_logging <- function(...) NULL
  env$stage_external_vocab_files <- function(...) list(staged_paths = character())
  env$connect_source_db <- function(...) TRUE
  env$lock_external_vocab_schema <- function(...) NULL
  env$ensure_ext_vocab_loads_table <- function(con, metadata_schema) {
    schema_seen <<- metadata_schema
    stop("setup stopped for test")
  }
  env$disconnect_if_open <- function(...) NULL
  env$log_error <- function(...) NULL
  env$log_info <- function(...) NULL

  expect_error(env$main(file.path(project_root, "config", "settings.smoke.yaml")), "setup stopped for test")
  expect_equal(schema_seen, "metadata_custom")
})
