#!/bin/bash

# Initialize variables with default tool names
FIND=find
SED=sed
GREP=grep
CP=cp
UNIQ=uniq
SORT=sort
SHA1SUM=sha1sum
XARGS=xargs
READLINK=readlink

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running on macOS and adjust tool names
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS system detected, attempt to use GNU tools
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
    echo "Non-macOS system detected, using default tools."
fi

# Export the variables so they are available in scripts that source this file
export FIND SED GREP CP UNIQ SORT SHA1SUM XARGS READLINK
