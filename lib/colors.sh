#!/usr/bin/env bash
# lib/colors.sh — ANSI color constants and print helpers
# Sourced by all modules; never executed directly.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Print a colored section header divider
print_header() {
    local title="$1"
    local width=60
    local line
    line=$(printf '%*s' "$width" '' | tr ' ' '─')
    echo -e "\n${CYAN}${BOLD}┌${line}┐${RESET}"
    printf "${CYAN}${BOLD}│  %-56s  │${RESET}\n" "$title"
    echo -e "${CYAN}${BOLD}└${line}┘${RESET}\n"
}

# Print a step indicator
print_step() {
    local num="$1"
    local title="$2"
    echo -e "\n${BOLD}${BLUE}  ▶  Paso ${num}: ${title}${RESET}"
    echo -e "${DIM}  $(printf '%*s' 50 '' | tr ' ' '─')${RESET}"
}

# Print a recommendation box
print_recommendation() {
    local msg="$1"
    echo -e "\n${YELLOW}${BOLD}  💡 RECOMENDACIÓN${RESET}"
    echo -e "${YELLOW}  ${msg}${RESET}"
}

# Print a warning box
print_warning() {
    local msg="$1"
    echo -e "\n${YELLOW}${BOLD}  ⚠  ADVERTENCIA${RESET}"
    echo -e "${YELLOW}  ${msg}${RESET}"
}

# Print an error box
print_error_box() {
    local msg="$1"
    echo -e "\n${RED}${BOLD}  ✖  ERROR${RESET}"
    echo -e "${RED}  ${msg}${RESET}"
}
