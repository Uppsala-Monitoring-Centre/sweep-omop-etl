find_project_root <- function(max_levels = 8L) {
  current <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)

  for (i in seq.int(0L, max_levels)) {
    parts <- rep("..", i)
    candidate <- if (length(parts) == 0L) {
      current
    } else {
      normalizePath(file.path(current, do.call(file.path, as.list(parts))),
        winslash = "/",
        mustWork = FALSE
      )
    }

    if (file.exists(file.path(candidate, "R", "utils", "helpers.R"))) {
      return(candidate)
    }
  }

  stop("Could not locate project root from current working directory.")
}

project_root <- find_project_root()

# Some project scripts use project-relative source() calls, so enforce root cwd for tests.
setwd(project_root)

source(file.path(project_root, "R", "utils", "logging.R"))
source(file.path(project_root, "R", "utils", "helpers.R"))
source(file.path(project_root, "R", "utils", "etl_run_tracking.R"))
source(file.path(project_root, "R", "utils", "external_vocab_tracking.R"))
source(file.path(project_root, "R", "config", "settings.R"))
source(file.path(project_root, "R", "db", "connect.R"))
