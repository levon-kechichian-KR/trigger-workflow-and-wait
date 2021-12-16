#!/usr/bin/env bash
set -e

usage_docs() {
  echo ""
  echo "You can use this Github Action with:"
  echo "- uses: convictional/trigger-workflow-and-wait"
  echo "  with:"
  echo "    owner: keithconvictional"
  echo "    repo: myrepo"
  echo "    github_token: \${{ secrets.GITHUB_PERSONAL_ACCESS_TOKEN }}"
  echo "    workflow_file_name: main.yaml"
}
GITHUB_API_URL="${API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}"

validate_args() {
  wait_interval=10 # Waits for 10 seconds
  if [ "${INPUT_WAIT_INTERVAL}" ]
  then
    wait_interval=${INPUT_WAIT_INTERVAL}
  fi

  propagate_failure=true
  if [ -n "${INPUT_PROPAGATE_FAILURE}" ]
  then
    propagate_failure=${INPUT_PROPAGATE_FAILURE}
  fi

  trigger_workflow=true
  if [ -n "${INPUT_TRIGGER_WORKFLOW}" ]
  then
    trigger_workflow=${INPUT_TRIGGER_WORKFLOW}
  fi

  wait_workflow=true
  if [ -n "${INPUT_WAIT_WORKFLOW}" ]
  then
    wait_workflow=${INPUT_WAIT_WORKFLOW}
  fi

  last_workflow_interval=0
  if [ -n "${INPUT_LAST_WORKFLOW_INTERVAL}" ]
  then
    last_workflow_interval=${INPUT_LAST_WORKFLOW_INTERVAL}
  fi

  last_workflow_timeout=10
  if [ -n "${INPUT_LAST_WORKFLOW_TIMEOUT}" ]
  then
    last_workflow_timeout=${INPUT_LAST_WORKFLOW_TIMEOUT}
  fi

  if [ -z "${INPUT_OWNER}" ]
  then
    echo "Error: Owner is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_REPO}" ]
  then
    echo "Error: Repo is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_GITHUB_TOKEN}" ]
  then
    echo "Error: Github token is required. You can head over settings and"
    echo "under developer, you can create a personal access tokens. The"
    echo "token requires repo access."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_WORKFLOW_FILE_NAME}" ]
  then
    echo "Error: Workflow File Name is required"
    usage_docs
    exit 1
  fi

  client_payload=$(echo '{}' | jq)
  if [ "${INPUT_CLIENT_PAYLOAD}" ]
  then
    client_payload=$(echo "${INPUT_CLIENT_PAYLOAD}" | jq)
  fi

  ref="main"
  if [ "$INPUT_REF" ]
  then
    ref="${INPUT_REF}"
  fi
}

trigger_workflow() {
  echo "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches"
  echo --data "{\"ref\":\"${ref}\",\"client_payload\":${client_payload}}"

  curl --fail -X POST "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
    --data "{\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  echo "Sleeping for ${wait_interval} seconds"
  sleep $wait_interval
}

wait_for_workflow_to_finish() {
  # Find the id of the last run using filters to identify the workflow triggered by this action
  echo "Getting the ID of the workflow..."

  query="event=workflow_dispatch&status=in_progress"
  if [ "$INPUT_GITHUB_USER" ]
  then
    query="${query}&actor=${INPUT_GITHUB_USER}"
  fi

  last_workflow="null"

  while [[ "$last_workflow" == "null" && $last_workflow_timeout -gt 0 ]]
  do
    echo "Sleeping for \"${last_workflow_interval}\" seconds"
    sleep ${last_workflow_interval}

    echo "Using the following params to filter the workflow runs to get the triggered run id -"
    echo "Query params: ${query}"

    last_workflow=$(curl -X GET "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?${query}" \
      -H 'Accept: application/vnd.github.antiope-preview+json' \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" | tr '\r\n' ' ' | jq '[.workflow_runs[]] | first')

    last_workflow_timeout=`expr $last_workflow_timeout - $last_workflow_interval`
  done

  if [ $last_workflow_timeout -lt 0 ]
  then
    echo "Timed out waiting for last_workflow"
    exit 1
  fi

  last_workflow_id=$(echo "${last_workflow}" | jq '.id')
  last_workflow_url="${GITHUB_SERVER_URL}/${INPUT_OWNER}/${INPUT_REPO}/actions/runs/${last_workflow_id}"

  echo "The workflow id is [${last_workflow_id}]."
  echo "The workflow logs can be found at ${last_workflow_url}"
  echo "::set-output name=workflow_id::${last_workflow_id}"
  echo "::set-output name=workflow_url::${last_workflow_url}"
  echo ""

  conclusion=$(echo "${last_workflow}" | jq '.conclusion')
  status=$(echo "${last_workflow}" | jq '.status')

  while [[ "${conclusion}" == "null" && "${status}" != "\"completed\"" ]]
  do
    echo "Sleeping for \"${wait_interval}\" seconds"
    sleep "${wait_interval}"

    workflow=$(curl -X GET "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/workflows/${INPUT_WORKFLOW_FILE_NAME}/runs" \
      -H 'Accept: application/vnd.github.antiope-preview+json' \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" | jq '.workflow_runs[] | select(.id == '${last_workflow_id}')')
    conclusion=$(echo "${workflow}" | jq '.conclusion')
    status=$(echo "${workflow}" | jq '.status')

    echo "Checking conclusion [${conclusion}]"
    echo "Checking status [${status}]"
  done

  if [[ "${conclusion}" == "\"success\"" && "${status}" == "\"completed\"" ]]
  then
    echo "Yes, success"
  else
    # Alternative "failure"
    echo "Conclusion is not success, its [${conclusion}]."

    if [ "${propagate_failure}" = true ]
    then
      echo "Propagating failure to upstream job"
      exit 1
    fi
  fi
}

main() {
  validate_args

  if [ "${trigger_workflow}" = true ]
  then
    trigger_workflow
  else
    echo "Skipping triggering the workflow."
  fi

  if [ "${wait_workflow}" = true ]
  then
    wait_for_workflow_to_finish
  else
    echo "Skipping waiting for workflow."
  fi
}

main
