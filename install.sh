#!/usr/bin/env bash
# This script manages to deploy the infrastructure for the Atlassian Data Center products
#
# Usage:  install.sh [-c <config_file>] [-h]
# -p <config_file>: Terraform configuration file. The default value is 'config.tfvars' if the argument is not provided.
# -h : provides help to how executing this script.
set -e
set -o pipefail
ROOT_PATH=$(cd $(dirname "${0}"); pwd)
SCRIPT_PATH="${ROOT_PATH}/pkg/scripts"
LOG_FILE="${ROOT_PATH}/logs/terraform-dc-install_$(date '+%Y-%m-%d_%H-%M-%S').log"
LOG_TAGGING="${ROOT_PATH}/logs/terraform-dc-asg-tagging_$(date '+%Y-%m-%d_%H-%M-%S').log"

ENVIRONMENT_NAME=
OVERRIDE_CONFIG_FILE=
DIFFERENT_ENVIRONMENT=1

source "${SCRIPT_PATH}/common.sh"

show_help(){
  if [ -n "${HELP_FLAG}" ]; then
cat << EOF
This script provisions the infrastructure for Atlassian Data Center products in AWS environment.
The infrastructure will be generated by terraform and state of the resources will be kept in a S3 bucket which will be provision by this script if is not existed.

Before installing the infrastructure make sure you have completed the configuration process and did all perquisites.
For more information visit https://github.com/atlassian-labs/data-center-terraform.
EOF

  fi
  echo
  echo "Usage:  ./install.sh [-c <config_file>] [-h]"
  echo "   -c <config_file>: Terraform configuration file. The default value is 'config.tfvars' if the argument is not provided."
  echo "   -h : provides help to how executing this script."
  echo
  exit 2
}

# Extract arguments
  CONFIG_FILE=
  HELP_FLAG=
  while getopts h?c: name ; do
      case $name in
      h)    HELP_FLAG=1; show_help;;  # Help
      c)    CONFIG_FILE="${OPTARG}";; # Config file name to install - this overrides the default, 'config.tfvars'
      ?)    echo "Invalid arguments."; show_help
      esac
  done

  shift $((${OPTIND} - 1))
  UNKNOWN_ARGS="$*"

# Validate the arguments.
process_arguments() {
  # set the default value for config file if is not provided
  if [ -z "${CONFIG_FILE}" ]; then
    CONFIG_FILE="${ROOT_PATH}/config.tfvars"
  else
    if [[ ! -f "${CONFIG_FILE}" ]]; then
      log "Terraform configuration file '${CONFIG_FILE}' not found!"
      show_help
    fi
  fi
  CONFIG_ABS_PATH="$(cd "$(dirname "${CONFIG_FILE}")"; pwd)/$(basename "${CONFIG_FILE}")"
  OVERRIDE_CONFIG_FILE="-var-file=${CONFIG_ABS_PATH}"
  
  log "Terraform will use '${CONFIG_ABS_PATH}' to install the infrastructure."

  if [ -n "${UNKNOWN_ARGS}" ]; then
    log "Unknown arguments:  ${UNKNOWN_ARGS}"
    show_help
  fi
}


# Make sure the infrastructure config file is existed and contains the valid data
verify_configuration_file() {
  log "Verifying the config file."

  HAS_VALIDATION_ERR=
  # Make sure the config values are defined
  set +e
  INVALID_CONTENT=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep '<\|>')
  set -e
  ENVIRONMENT_NAME=$(grep 'environment_name' "${CONFIG_ABS_PATH}" | sed -nE 's/^.*"(.*)".*$/\1/p')

  # check license and admin password
  export POPULATED_LICENSE=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep 'bamboo_license')
  export POPULATED_ADMIN_PWD=$(grep -o '^[^#]*' "${CONFIG_ABS_PATH}" | grep 'bamboo_admin_password')

  if [ "${#ENVIRONMENT_NAME}" -gt 25 ]; then
    log "The environment name '${ENVIRONMENT_NAME}' is too long(${#ENVIRONMENT_NAME} characters)." "ERROR"
    log "Please make sure your environment name is less than 25 characters."
    HAS_VALIDATION_ERR=1
  fi

  if [ -n "${INVALID_CONTENT}" ]; then
    log "Configuration file '${CONFIG_ABS_PATH##*/}' is not valid." "ERROR"
    log "Terraform uses this file to generate customised infrastructure for '${ENVIRONMENT_NAME}' on your AWS account."
    log "Please modify '${CONFIG_ABS_PATH##*/}' using a text editor and complete the configuration. "
    log "Then re-run the install.sh to deploy the infrastructure."
    log "${INVALID_CONTENT}"
    HAS_VALIDATION_ERR=1
  fi

  if [ -z "${POPULATED_LICENSE}" ];  then
    if [ -z "${TF_VAR_bamboo_license}" ]; then
      log "License is missing. Please provide license in config file, or export it to the environment variable 'TF_VAR_bamboo_license'." "ERROR"
      HAS_VALIDATION_ERR=1
    fi
  fi

  if [ -z "${POPULATED_ADMIN_PWD}" ];  then
    if [ -z "${TF_VAR_bamboo_admin_password}" ]; then
      log "Admin password is missing. Please provide admin password in config file, or export it to the environment variable 'TF_VAR_bamboo_admin_password'." "ERROR"
      HAS_VALIDATION_ERR=1
    fi
  fi

  if [ -n "${HAS_VALIDATION_ERR}" ]; then
    log "There was a problem with the configuration file. Aborting execution" "ERROR"
    exit 1
  fi
}

# Generates ./terraform-backend.tf and ./pkg/tfstate/tfstate-local.tf using the content of local.tf and current aws account
generate_terraform_backend_variables() {
  log "${ENVIRONMENT_NAME}' infrastructure deployment is started using '${CONFIG_ABS_PATH##*/}'."

  log "Terraform state backend/variable files are not created yet."
  source "${SCRIPT_PATH}/generate-variables.sh" "${CONFIG_ABS_PATH}"
}

# Create S3 bucket, bucket key, and dynamodb table to keep state and manage lock if they are not created yet
create_tfstate_resources() {
  # Check if the S3 bucket is existed otherwise create the bucket to keep the terraform state
  log "Checking the terraform state."
  if ! test -d "${ROOT_PATH}/logs" ; then
    mkdir "${ROOT_PATH}/logs"
  fi
  touch "${LOG_FILE}"
  local STATE_FOLDER="${SCRIPT_PATH}/../tfstate"
  set +e
  aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null
  S3_BUCKET_EXISTS=$?
  set -e
  if [ ${S3_BUCKET_EXISTS} -eq 0 ]
  then
    log "S3 bucket '${S3_BUCKET}' already exists."
  else
    # create s3 bucket to be used for keep state of the terraform project
    log "Creating '${S3_BUCKET}' bucket for storing the terraform state..."
    if ! test -d "${STATE_FOLDER}/.terraform" ; then
      terraform -chdir="${STATE_FOLDER}" init -no-color | tee -a "${LOG_FILE}"
    fi
    terraform -chdir="${STATE_FOLDER}" apply -auto-approve "${OVERRIDE_CONFIG_FILE}" | tee -a "${LOG_FILE}"
    sleep 5s
  fi
}

# Deploy the infrastructure if is not created yet otherwise apply the changes to existing infrastructure
create_update_infrastructure() {
  log "Starting to analyze the infrastructure..."
  if [ -n "${DIFFERENT_ENVIRONMENT}" ]; then
    log "Migrating the terraform state to S3 bucket..."
    terraform -chdir="${ROOT_PATH}" init -migrate-state -no-color | tee -a "${LOG_FILE}"
    terraform -chdir="${ROOT_PATH}" init -no-color | tee -a "${LOG_FILE}"
  fi
  terraform -chdir="${ROOT_PATH}" apply -auto-approve -no-color "${OVERRIDE_CONFIG_FILE}" | tee -a "${LOG_FILE}"
}

# Apply the tags into ASG and EC2 instances created by ASG
add_tags_to_asg_resources() {
  log "Tagging Auto Scaling Group and EC2 instances. It may take a few minutes. Please wait..."
  TAG_MODULE_PATH="${SCRIPT_PATH}/../modules/AWS/asg_ec2_tagging"

  terraform -chdir="${TAG_MODULE_PATH}" init -no-color > "${LOG_TAGGING}"
  terraform -chdir="${TAG_MODULE_PATH}" apply -auto-approve -no-color "${OVERRIDE_CONFIG_FILE}" >> "${LOG_TAGGING}"
  log "Resource tags are applied to ASG and all EC2 instances."
}

set_current_context_k8s() {
  local EKS_PREFIX="atlas-"
  local EKS_SUFFIX="-cluster"
  local EKS_CLUSTER_NAME=${EKS_PREFIX}${ENVIRONMENT_NAME}${EKS_SUFFIX}
  local EKS_CLUSTER="${EKS_CLUSTER_NAME:0:38}"
  CONTEXT_FILE="${ROOT_PATH}/kubeconfig_${EKS_CLUSTER}"

  if [[ -f  "${CONTEXT_FILE}" ]]; then
    log "EKS Cluster ${EKS_CLUSTER} in region ${REGION} is ready to use."
    log "Kubernetes config file could be found at '${CONTEXT_FILE}'"
    aws --region "${REGION}" eks update-kubeconfig --name "${EKS_CLUSTER}"
  else
    log "Kubernetes context file '${CONTEXT_FILE}' could not be found."
  fi
}

# Process the arguments
process_arguments

# Verify the configuration file
verify_configuration_file

# Generates ./terraform-backend.tf and ./pkg/tfstate/tfstate-local.tf
generate_terraform_backend_variables

# Create S3 bucket and dynamodb table to keep state
create_tfstate_resources

# Deploy the infrastructure
create_update_infrastructure

# Manually add resource tags into ASG and EC2 
add_tags_to_asg_resources

# Print information about manually adding the new k8s context
set_current_context_k8s
