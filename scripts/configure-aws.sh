#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OIDC_URL=https://token.actions.githubusercontent.com

usage() {
    cat <<'EOF'
Uso: scripts/configure-aws.sh [AWS_ACCOUNT_ID] [ROLE_NAME]

Obtiene OWNER/REPOSITORY desde el remoto origin y configura el proveedor OIDC y
el IAM role para que GitHub Actions pueda asumirlo. Si no se proporciona
AWS_ACCOUNT_ID, lo obtiene de la identidad AWS activa.
La trust policy se escribe en .generated/aws/github-oidc-trust-policy.json.
La policy de despliegue se escribe en .generated/aws/github-actions-deploy-policy.json.
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
    local temp_file

    mkdir -p "$output_dir"
    temp_file=$(mktemp "$output_dir/.github-oidc-trust-policy.json.XXXXXX")
    cat > "$temp_file" <<EOF
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
          "token.actions.githubusercontent.com:sub": [
            "repo:${owner}/${repository}:ref:refs/heads/main",
            "repo:${owner}@*/${repository}@*:ref:refs/heads/main",
            "repo:${owner}/${repository}:environment:dev",
            "repo:${owner}/${repository}:environment:staging",
            "repo:${owner}/${repository}:environment:prod",
            "repo:${owner}@*/${repository}@*:environment:dev",
            "repo:${owner}@*/${repository}@*:environment:staging",
            "repo:${owner}@*/${repository}@*:environment:prod"
          ]
        }
      }
    }
  ]
}
EOF

  if [[ -f "$output_file" ]] && cmp -s "$temp_file" "$output_file"; then
    rm -f -- "$temp_file"
    printf 'Trust policy sin cambios: %s\n' "$output_file"
  else
    mv -- "$temp_file" "$output_file"
    printf 'Trust policy generada: %s\n' "$output_file"
  fi
    printf 'Role esperado: arn:aws:iam::%s:role/%s\n' "$account_id" "$role_name"
}

  configure_oidc_provider() {
    local account_id=$1
    local provider_arn="arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"

    if AWS_PAGER="" aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "$provider_arn" >/dev/null 2>&1; then
      printf 'Proveedor OIDC sin cambios: %s\n' "$provider_arn"
      return
    fi

    AWS_PAGER="" aws iam create-open-id-connect-provider \
      --url "$OIDC_URL" \
      --client-id-list sts.amazonaws.com >/dev/null
    printf 'Proveedor OIDC creado: %s\n' "$provider_arn"
  }

  configure_role() {
    local account_id=$1
    local role_name=$2
    local policy_file=$3
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    if AWS_PAGER="" aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
      AWS_PAGER="" aws iam update-assume-role-policy \
        --role-name "$role_name" \
        --policy-document "file://${policy_file}"
      printf 'Trust policy del role actualizada: %s\n' "$role_arn"
      return
    fi

    AWS_PAGER="" aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "file://${policy_file}" \
      --description "GitHub Actions OIDC deployment role" >/dev/null
    printf 'Role creado: %s\n' "$role_arn"
  }

configure_role_permissions() {
    local role_name=$1
    local policy_file=$2

    AWS_PAGER="" aws iam put-role-policy \
      --role-name "$role_name" \
      --policy-name github-actions-deploy \
      --policy-document "file://${policy_file}" >/dev/null
    printf 'Policy de despliegue aplicada al role: %s\n' "$role_name"
  }

generate_deployment_policy() {
    local output_dir=$1
    local output_file="$output_dir/github-actions-deploy-policy.json"
    local temp_file

    mkdir -p "$output_dir"
    temp_file=$(mktemp "$output_dir/.github-actions-deploy-policy.json.XXXXXX")
    cat > "$temp_file" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateChangeSet",
        "cloudformation:CreateStack",
        "cloudformation:DeleteChangeSet",
        "cloudformation:DeleteStack",
        "cloudformation:Describe*",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:GetTemplate",
        "cloudformation:List*",
        "cloudformation:UpdateStack",
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:DeleteObject",
        "s3:GetBucketLocation",
        "s3:GetBucketPolicy",
        "s3:GetBucketTagging",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketVersioning",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:PutBucketTagging",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketPolicy",
        "s3:PutEncryptionConfiguration",
        "s3:PutBucketVersioning",
        "s3:TagResource",
        "s3:UntagResource",
        "s3:DeleteBucketPolicy",
        "iam:SimulatePrincipalPolicy",
        "lambda:AddPermission",
        "lambda:CreateAlias",
        "lambda:CreateFunction",
        "lambda:DeleteAlias",
        "lambda:DeleteFunction",
        "lambda:DeleteFunctionUrlConfig",
        "lambda:Get*",
        "lambda:List*",
        "lambda:PublishVersion",
        "lambda:RemovePermission",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:UpdateAlias",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "iam:AttachRolePolicy",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:GetRole",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:TagRole",
        "iam:UntagRole",
        "apigateway:DELETE",
        "apigateway:GET",
        "apigateway:PATCH",
        "apigateway:POST",
        "apigateway:PUT",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:Describe*",
        "elasticloadbalancing:ModifyListener",
        "cloudwatch:DeleteAlarms",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:PutMetricAlarm",
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:GetTopicAttributes",
        "sns:ListSubscriptionsByTopic",
        "sns:SetTopicAttributes",
        "sns:Subscribe",
        "sns:Unsubscribe",
        "codedeploy:CreateApplication",
        "codedeploy:CreateDeploymentGroup",
        "codedeploy:DeleteApplication",
        "codedeploy:DeleteDeploymentGroup",
        "codedeploy:Get*",
        "codedeploy:List*",
        "codedeploy:UpdateDeploymentGroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF

    if [[ -f "$output_file" ]] && cmp -s "$temp_file" "$output_file"; then
        rm -f -- "$temp_file"
    else
        mv -- "$temp_file" "$output_file"
    fi
    printf '%s\n' "$output_file"
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
    deployment_policy_file=$(generate_deployment_policy ".generated/aws")
    configure_oidc_provider "$account_id"
    configure_role "$account_id" "$role_name" ".generated/aws/github-oidc-trust-policy.json"
    configure_role_permissions "$role_name" "$deployment_policy_file"
}

main "$@"
