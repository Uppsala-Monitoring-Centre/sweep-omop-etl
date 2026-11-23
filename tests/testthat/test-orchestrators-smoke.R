smoke_enabled <- function(flag = "RUN_SMOKE") {
  identical(tolower(Sys.getenv(flag, "false")), "true")
}

smoke_config_path <- function() {
  path <- Sys.getenv("SMOKE_CONFIG_PATH", file.path(project_root, "config", "settings.smoke.yaml"))
  normalizePath(path, winslash = "/", mustWork = FALSE)
}

require_smoke_config <- function() {
  path <- smoke_config_path()
  if (!file.exists(path)) {
    skip(sprintf("Smoke config not found: %s", path))
  }
  path
}

with_smoke_config <- function(config_path, code) {
  old_config <- Sys.getenv("CONFIG_PATH", unset = NA)
  on.exit(
    {
      if (is.na(old_config)) {
        Sys.unsetenv("CONFIG_PATH")
      } else {
        Sys.setenv(CONFIG_PATH = old_config)
      }
    },
    add = TRUE
  )

  Sys.setenv(CONFIG_PATH = config_path)
  force(code)
}

load_orchestrator_main <- function(script_path) {
  env <- new.env(parent = globalenv())
  script_abs_path <- normalizePath(
    file.path(project_root, script_path),
    winslash = "/",
    mustWork = FALSE
  )

  if (!file.exists(script_abs_path)) {
    stop(sprintf("Orchestrator script not found: %s", script_abs_path))
  }

  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(project_root)
  sys.source(script_abs_path, envir = env)

  if (!exists("main", envir = env, inherits = FALSE)) {
    stop(sprintf("No main() found in %s", script_abs_path))
  }

  get("main", envir = env, inherits = FALSE)
}

test_that("smoke: 00 sample generator runs", {
  skip_if_not(smoke_enabled())
  skip_if_not(smoke_enabled("RUN_SMOKE_00"))
  config_path <- require_smoke_config()

  main_fun <- load_orchestrator_main(file.path("R", "orchestrators", "00_sample_generator.R"))

  with_smoke_config(config_path, {
    expect_no_error(main_fun())
  })
})

test_that("smoke: 01 setup CDM runs", {
  skip_if_not(smoke_enabled())
  skip_if_not(smoke_enabled("RUN_SMOKE_01"))
  config_path <- require_smoke_config()
  settings <- yaml::read_yaml(config_path)

  vocab_dir <- settings$vocabularies$dir_path
  if (is.null(vocab_dir) || !dir.exists(vocab_dir)) {
    skip("Vocabulary directory does not exist for smoke test")
  }

  main_fun <- load_orchestrator_main(file.path("R", "orchestrators", "01_setup_CDM.R"))

  with_smoke_config(config_path, {
    expect_no_error(main_fun())
  })
})

test_that("smoke: 02 setup external vocab runs", {
  skip_if_not(smoke_enabled())
  skip_if_not(smoke_enabled("RUN_SMOKE_02"))
  config_path <- require_smoke_config()
  settings <- yaml::read_yaml(config_path)

  nplid_path <- settings$vocabularies$external$nplid_to_rxnorm_csv_path
  icd10_path <- settings$vocabularies$external$icd10se_codes_tsv_path

  if (is.null(nplid_path) || !file.exists(nplid_path)) {
    skip("NPLID mapping CSV not found for smoke test")
  }
  if (is.null(icd10_path) || !file.exists(icd10_path)) {
    skip("ICD-10-SE code list not found for smoke test")
  }

  main_fun <- load_orchestrator_main(file.path("R", "orchestrators", "02_setup_ext_vocab.R"))

  with_smoke_config(config_path, {
    expect_no_error(main_fun())
  })
})

test_that("smoke: 03 OMOP orchestrator runs", {
  skip_if_not(smoke_enabled())
  skip_if_not(smoke_enabled("RUN_SMOKE_03"))
  config_path <- require_smoke_config()

  main_fun <- load_orchestrator_main(file.path("R", "orchestrators", "03_omop_orchestrator.R"))

  with_smoke_config(config_path, {
    expect_no_error(main_fun())
  })
})

test_that("smoke: 04 indices and FK runs", {
  skip_if_not(smoke_enabled())
  skip_if_not(smoke_enabled("RUN_SMOKE_04"))
  config_path <- require_smoke_config()

  main_fun <- load_orchestrator_main(file.path("R", "orchestrators", "04_indices_FK.R"))

  with_smoke_config(config_path, {
    expect_no_error(main_fun())
  })
})
