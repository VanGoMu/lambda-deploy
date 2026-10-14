#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Uso: scripts/configure-aws.sh [AWS_ACCOUNT_ID] [ROLE_NAME]

Obtiene OWNER/REPOSITORY desde el remoto origin y genera la trust policy para que
GitHub Actions asuma un IAM role mediante OIDC. Si no se proporciona
AWS_ACCOUNT_ID, lo obtiene de la identidad AWS activa.
La policy se escribe en .generated/aws/github-oidc-trust-policy.json.
EOF
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "No se encontro '$1'. Instalalo antes de continuar."
}

get_account_id() {
  local account_id

  require_command aws
  account_id=$(AWS_PAGER="" aws sts get-caller-identity \
    --query Account --output text 2>/dev/null) || \
    fail "No se pudo obtener AWS_ACCOUNT_ID con las credenciales activas"
  printf '%s\n' "$account_id"
}

validate_input() {
    local name=$1
    local value=$2
    local pattern=$3

    [[ $value =~ $pattern ]] || fail "$name no tiene un formato valido: $value"
}

  get_repository() {
    local remote_url
    local repository_path
    local owner
    local repository

    remote_url=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null) || \
      fail "No se pudo leer el remoto Git 'origin'"

    case $remote_url in
      git@github.com:*) repository_path=${remote_url#git@github.com:} ;;
      https://github.com/*) repository_path=${remote_url#https://github.com/} ;;
      *) fail "El remoto origin no apunta a GitHub: $remote_url" ;;
    esac

    repository_path=${repository_path%.git}
    owner=${repository_path%%/*}
    repository=${repository_path#*/}

    validate_input "OWNER" "$owner" '^[A-Za-z0-9_.-]+$'
    validate_input "REPOSITORY" "$repository" '^[A-Za-z0-9_.-]+$'
    printf '%s\n%s\n' "$owner" "$repository"
  }

generate_trust_policy() {
    local owner=$1
    local repository=$2
    local account_id=$3
    local role_name=$4
    local output_dir=$5
    local output_file="$output_dir/github-oidc-trust-policy.json"

    mkdir -p "$output_dir"
    cat > "$output_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${owner}/${repository}:ref:refs/heads/main"
        }
      }
    }
  ]
}
EOF

    printf 'Trust policy generada: %s\n' "$output_file"
    printf 'Role esperado: arn:aws:iam::%s:role/%s\n' "$account_id" "$role_name"
}

main() {
  [[ $# -le 2 ]] || {
        usage
        exit 2
    }

  local account_id=${1:-}
  local role_name=${2:-github-actions-lambda-deploy}
  local owner
  local repository
  mapfile -t repository_data < <(get_repository)
  owner=${repository_data[0]}
  repository=${repository_data[1]}

    if [[ -z $account_id ]]; then
        account_id=$(get_account_id)
    fi
    validate_input "AWS_ACCOUNT_ID" "$account_id" '^[0-9]{12}$'
    validate_input "ROLE_NAME" "$role_name" '^[A-Za-z0-9+=,.@_-]+$'

    generate_trust_policy "$owner" "$repository" "$account_id" "$role_name" ".generated/aws"
}

main "$@"
