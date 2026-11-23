library(yaml)

resolve_config_path <- function(config_path = NULL) {
  if (!is.null(config_path) && nzchar(config_path)) {
    return(config_path)
  }

  env_config_path <- Sys.getenv("CONFIG_PATH", unset = "")
  if (nzchar(env_config_path)) {
    return(env_config_path)
  }

  "config/settings.yaml"
}

read_settings <- function(config_path = NULL) {
  config_path <- resolve_config_path(config_path)
  if (!file.exists(config_path)) {
    stop(sprintf("Configuration file not found: %s", config_path))
  }
  yaml::read_yaml(config_path)
}

get_setting_or_default <- function(settings, path, default_value = NULL) {
  cur <- settings
  for (key in path) {
    if (is.null(cur[[key]])) {
      return(default_value)
    }
    cur <- cur[[key]]
  }
  cur
}
