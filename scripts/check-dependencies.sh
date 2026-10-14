#!/usr/bin/env bash
set -Eeuo pipefail

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Falta la dependencia: %s\n' "$1" >&2
        return 1
    }
}

main() {
    local command_name
    local missing=0

    for command_name in aws gh sam git shellcheck; do
        if require_command "$command_name"; then
            printf 'OK: %s\n' "$command_name"
        else
            missing=1
        fi
    done

    return "$missing"
}

main "$@"
