test_that("read_settings returns parsed YAML content", {
  cfg <- tempfile(fileext = ".yaml")
  writeLines(c(
    "project:",
    "  name: omop",
    "schemas:",
    "  cdm_schema: omop54"
  ), cfg)

  settings <- read_settings(cfg)

  expect_equal(settings$project$name, "omop")
  expect_equal(settings$schemas$cdm_schema, "omop54")
})

test_that("read_settings errors when file does not exist", {
  missing <- file.path(tempdir(), "definitely_missing_settings.yaml")

  expect_error(
    read_settings(missing),
    regexp = "Configuration file not found"
  )
})

test_that("get_setting_or_default returns nested value or default", {
  settings <- list(
    source_db = list(host = "localhost", port = 5433, user = "etl_admin"),
    run = list(sample_size = 500)
  )

  expect_equal(get_setting_or_default(settings, c("source_db", "host"), "x"), "localhost")
  expect_equal(get_setting_or_default(settings, c("source_db", "port"), 3306), 5433)
  expect_equal(get_setting_or_default(settings, c("run", "sample_size"), 100), 500)
  expect_equal(get_setting_or_default(settings, c("source_db", "user"), "etl_admin"), "etl_admin")
  expect_equal(get_setting_or_default(settings, c("source_db", "password"), "default_pass"), "default_pass")
})
