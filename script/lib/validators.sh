#!/bin/bash
# validators.sh - Common logging and validation functions

# Colors for output
readonly LOG_RED='\033[0;31m'
readonly LOG_GREEN='\033[0;32m'
readonly LOG_YELLOW='\033[1;33m'
readonly LOG_BLUE='\033[0;34m'
readonly LOG_NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${LOG_BLUE}[INFO]${LOG_NC} $1"
}

log_success() {
    echo -e "${LOG_GREEN}[SUCCESS]${LOG_NC} $1"
}

log_warning() {
    echo -e "${LOG_YELLOW}[WARNING]${LOG_NC} $1"
}

log_error() {
    echo -e "${LOG_RED}[ERROR]${LOG_NC} $1" >&2
}

# Validation functions
validate_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        return 1
    fi
    return 0
}

validate_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    return 0
}

validate_directory_exists() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log_error "Directory not found: $dir"
        return 1
    fi
    return 0
}

validate_env_var() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        log_error "Required environment variable not set: $var_name"
        return 1
    fi
    return 0
}
