#!/usr/bin/env bash
# Prints message to stdout
# params: $1 - message, $2 - log level
log(){
  if [ "$#" -eq 0 ]; then
    echo "Usage: log <message>"
    return 1
  elif [ "$#" -eq 2 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") [$2] $1"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1"
  fi
}

# Fetch the value of the requested variable defined in Terraform config file
# params: $1 - variable name, $2 - config file full path
get_variable(){
  if [ "$#" -eq 2 ]; then
    local variable_name=${1}
    local config_file=${2}
    if [ ! -f "${config_file}" ]; then
      log "File ${config_file} does not exist." "ERROR"
      return 1
    fi
    local VALUE=$(grep -o '^[^#]*' "${config_file}" | grep "${variable_name}" | sed 's/ //g' | grep "${variable_name}=" | sed -nE 's/^.*"(.*)".*$/\1/p')
    if [ ! $(echo "${VALUE}" | wc -l) -eq 1 ];then
      log "ERROR - '${variable_name}' is re-defined in '${config_file}'" "ERROR";
      return 1;
    fi
    echo "${VALUE}"
    return 0
  fi
  echo "Usage: get_variable <variable name> <config file>"
  return 1
}