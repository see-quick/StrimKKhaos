#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

function log() {
    local level="${1}"
    shift
    echo -e "[$(date -u +"%Y-%m-%d %H:%M:%S")] [${level}]: ${@}"
}

function err_and_exit() {
    log "${RED}ERROR${NC}" "${1}" >&2
    exit ${2:-1}
}

function err() {
    log "${RED}ERROR${NC}" "${1}" >&2
}

function info() {
    log "${GREEN}INFO${NC}" "${1}"
}

function warn() {
    log "${YELLOW}WARN${NC}" "${1}"
}


# Initialize variables with default tool names
FIND=find
SED=sed
GREP=grep
CP=cp
UNIQ=uniq
SORT=sort
SHA1SUM=sha1sum
XARGS=xargs
DATE=date
READLINK=readlink

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running on macOS and adjust tool names
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS system detected, attempt to use GNU tools
    if command_exists gdate; then
        DATE=gdate
    fi
    if command_exists gfind; then
        FIND=gfind
    fi
    if command_exists gsed; then
        SED=gsed
    fi
    if command_exists ggrep; then
        GREP=ggrep
    fi
    if command_exists gcp; then
        CP=gcp
    fi
    if command_exists guniq; then
        UNIQ=guniq
    fi
    if command_exists gsort; then
        SORT=gsort
    fi
    if command_exists gsha1sum; then
        SHA1SUM=gsha1sum
    fi
    if command_exists gxargs; then
        XARGS=gxargs
    fi
    if command_exists greadlink; then
        READLINK=greadlink
    fi
else
    # Non-macOS system, use default tools
    info "Non-macOS system detected, using default tools."
fi

# Export the variables so they are available in scripts that source this file
export FIND SED GREP CP UNIQ SORT SHA1SUM XARGS READLINK