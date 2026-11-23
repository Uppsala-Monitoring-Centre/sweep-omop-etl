args <- commandArgs(trailingOnly = TRUE)

mode <- "check"
if (length(args) > 0 && args[[1]] %in% c("--check", "--fix")) {
  mode <- sub("^--", "", args[[1]])
  args <- args[-1]
}

# If pre-commit/CI passes file paths, lint only those. Otherwise lint project R files.
if (length(args) > 0) {
  paths <- args
} else {
  paths <- c("R", "tests")
}

paths <- paths[file.exists(paths)]
paths <- unique(normalizePath(paths, winslash = "/", mustWork = FALSE))

if (length(paths) == 0) {
  message(sprintf("No files or folders found to %s.", if (mode == "fix") "lint-fix" else "lint-check"))
  quit(status = 0)
}

r_files <- unique(unlist(lapply(paths, function(p) {
  if (dir.exists(p)) {
    list.files(p, pattern = "\\.[Rr]$", recursive = TRUE, full.names = TRUE)
  } else if (grepl("\\.[Rr]$", p)) {
    p
  } else {
    character(0)
  }
})))

if (length(r_files) == 0) {
  message(sprintf("No R files found to %s.", if (mode == "fix") "lint-fix" else "lint-check"))
  quit(status = 0)
}

if (mode == "fix") {
  styler::style_file(r_files)
}

results <- do.call(c, lapply(r_files, lintr::lint))

if (length(results) > 0) {
  print(results)
  message(sprintf("Lint %s found %d issue(s).", if (mode == "fix") "check after fixes" else "check", length(results)))
  quit(status = 1)
}

if (mode == "fix") {
  message(sprintf(
    "Applied auto-fixable style changes and found no remaining lint issues in %d R file(s).",
    length(r_files)
  ))
} else {
  message(sprintf("No lint issues found in %d R file(s).", length(r_files)))
}
