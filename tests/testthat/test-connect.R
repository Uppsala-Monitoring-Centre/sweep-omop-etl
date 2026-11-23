test_that("get_db_connection errors when required user is missing", {
  expect_error(
    get_db_connection(list(
      host = "localhost",
      port = 5433,
      dbname = "omop",
      user = "",
      user_env = NULL,
      password_env = NULL
    )),
    regexp = "Database user is not set"
  )
})

test_that("resolve_db_user uses user_env when provided", {
  user_var <- paste0("TEST_DB_USER_", as.integer(Sys.time()))
  old_value <- Sys.getenv(user_var, unset = NA)
  on.exit(
    {
      if (is.na(old_value)) {
        Sys.unsetenv(user_var)
      } else {
        do.call(Sys.setenv, setNames(list(old_value), user_var))
      }
    },
    add = TRUE
  )
  do.call(Sys.setenv, setNames(list("pablo_admin"), user_var))

  resolved <- resolve_db_user(list(user = NULL, user_env = user_var))
  expect_equal(resolved, "pablo_admin")
})

test_that("resolve_db_user supports user as env-var alias", {
  user_var <- paste0("TEST_DB_USER_ALIAS_", as.integer(Sys.time()))
  old_value <- Sys.getenv(user_var, unset = NA)
  on.exit(
    {
      if (is.na(old_value)) {
        Sys.unsetenv(user_var)
      } else {
        do.call(Sys.setenv, setNames(list(old_value), user_var))
      }
    },
    add = TRUE
  )
  do.call(Sys.setenv, setNames(list("pablo_admin"), user_var))

  resolved <- resolve_db_user(list(user = user_var, user_env = NULL))
  expect_equal(resolved, "pablo_admin")
})

test_that("get_db_connection errors when password env variable is missing", {
  password_var <- paste0("MISSING_PASS_", as.integer(Sys.time()))

  expect_error(
    get_db_connection(list(
      host = "localhost",
      port = 5433,
      dbname = "omop",
      user = "etl_admin",
      user_env = NULL,
      password_env = password_var
    )),
    regexp = sprintf("Environment variable %s is not set", password_var)
  )
})

test_that("connect_source_db reads settings and attempts a connection", {
  settings_file <- tempfile(fileext = ".yaml")
  writeLines(c(
    "source_db:",
    "  host: localhost",
    "  port: 5433",
    "  dbname: omop",
    "  user: etl_admin"
  ), settings_file)

  expect_error(
    connect_source_db(settings_file),
    regexp = "(?i)(connection|could not|failed to connect|refused)"
  )
})

test_that("connect_target_db reads settings and attempts a connection", {
  settings_file <- tempfile(fileext = ".yaml")
  writeLines(c(
    "target_db:",
    "  host: localhost",
    "  port: 5433",
    "  dbname: target",
    "  user: etl_admin"
  ), settings_file)

  expect_error(
    connect_target_db(settings_file),
    regexp = "(?i)(connection|could not|failed to connect|refused)"
  )
})

test_that("disconnect_if_open ignores NULL connections", {
  expect_silent(disconnect_if_open(NULL))
})
