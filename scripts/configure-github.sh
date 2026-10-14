#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Uso: scripts/configure-github.sh ROLE_ARN

Obtiene OWNER/REPOSITORY desde el remoto origin y configura el secreto
AWS_DEPLOY_ROLE_ARN en el repositorio de GitHub.
Requiere GitHub CLI autenticada: gh auth login.
EOF
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "No se encontro '$1'. Instalalo antes de continuar."
}

validate_inputs() {
    local role_arn=$1

    [[ $role_arn =~ ^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_-]+$ ]] || \
        fail "ROLE_ARN no tiene un formato valido"
}

get_repository() {
    local remote_url
    local repository_path

    remote_url=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null) || \
        fail "No se pudo leer el remoto Git 'origin'"

    case $remote_url in
        git@github.com:*) repository_path=${remote_url#git@github.com:} ;;
        https://github.com/*) repository_path=${remote_url#https://github.com/} ;;
        *) fail "El remoto origin no apunta a GitHub: $remote_url" ;;
    esac

    repository_path=${repository_path%.git}
    [[ $repository_path =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        fail "El remoto origin no contiene OWNER/REPOSITORY valido"
    printf '%s\n' "$repository_path"
}

configure_secret() {
    local repository=$1
    local role_arn=$2

    gh secret set AWS_DEPLOY_ROLE_ARN \
        --repo "$repository" \
        --body "$role_arn"
    printf 'Secreto AWS_DEPLOY_ROLE_ARN configurado en %s\n' "$repository"
}

main() {
    [[ $# -eq 1 ]] || {
        usage
        exit 2
    }

    local role_arn=$1
    local repository

    require_command gh
    repository=$(get_repository)
    validate_inputs "$role_arn"
    configure_secret "$repository" "$role_arn"
}

main "$@"
