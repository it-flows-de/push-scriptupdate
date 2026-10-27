#!/usr/bin/env bash
#===============================================================================
# Name:         push-scriptupdate.sh
# Author:       flo.alt@it-flows.de
# Date:         2026-10-27
# Purpose:      Release helper for scripts with their own GitHub repo. Checks the
#               working copy, raises VERSION, commits, pushes the branch, creates
#               and verifies a signed tag and pushes that tag.
# Usage:        Run inside the working copy of the script to release:
#                 push-scriptupdate.sh [--dry-run] [--help]
#                 --dry-run  run all checks and show the plan, change nothing
# Requires:     bash, git >= 2.34, ssh-keygen; runs as a normal user on the
#               development PC (signing key and push access to GitHub needed)
# Exit codes:   0 ok | 1 error | 2 usage | 3 config | 5 check failed |
#               6 aborted by user | 7 git operation failed
#===============================================================================

set -euo pipefail

VERSION="1.0.0"
REQUIRED_CONFIG_VERSION="1"

# Resolve symlinks: the script may be started via a link in PATH, but the config
# lives next to the real script file.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
SCRIPT_NAME="$(basename "${SCRIPT_PATH}" .sh)"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.config"

# --- Exit codes ---
EXIT_OK=0
# shellcheck disable=SC2034  # documented in the header, kept for completeness
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_CONFIG=3
EXIT_CHECK=5
EXIT_ABORT=6
EXIT_GIT=7

# --- Run state (used by rollback and the flows) ---
DRY_RUN=0
TARGET_SCRIPT=""
TARGET_NAME=""
CUSTOMER_PATTERNS=()
BACKUP_DIR=""
ORIG_MODE=""
CREATED_GIT=0
COMMITTED=0
STAGED=0
BRANCH=""
SWITCHED_FROM=""
TAG_MSG=""

#--- Output helpers -----------------------------------------------------------

# Print a normal message
info() { printf '%s\n' "$*"; }

# Print a section headline
step() { printf '\n== %s ==\n' "$*"; }

# Undo local changes made by this script if the run stops before the commit:
# restore the backed-up files, unstage, and remove a .git created by this run.
rollback() {
    [[ ${COMMITTED} -eq 0 ]] || return 0
    if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
        cp -p "${BACKUP_DIR}/${TARGET_SCRIPT}" "./${TARGET_SCRIPT}"
        cp -p "${BACKUP_DIR}/${TARGET_NAME}.config.example" "./${TARGET_NAME}.config.example"
        rm -rf "${BACKUP_DIR}"
        BACKUP_DIR=""
        info "File changes made by this run were reverted."
    fi
    if [[ -n "${ORIG_MODE}" ]]; then
        chmod "${ORIG_MODE}" "./${TARGET_SCRIPT}" || true
        ORIG_MODE=""
        info "The original file mode of ${TARGET_SCRIPT} was restored."
    fi
    if [[ ${CREATED_GIT} -eq 1 ]]; then
        rm -rf ./.git
        CREATED_GIT=0
        info "The local .git created by this run was removed again."
    elif [[ ${STAGED} -eq 1 ]]; then
        git reset -q || true
    fi
    if [[ -n "${SWITCHED_FROM}" ]]; then
        git switch -q "${SWITCHED_FROM}" || true
        info "Switched back to branch ${SWITCHED_FROM}."
        SWITCHED_FROM=""
    fi
}

# Print an error and terminate with the given exit code
die() {
    local code="$1"; shift
    rollback
    if [[ "${code}" -eq "${EXIT_ABORT}" ]]; then
        printf '%s\n' "$*" >&2
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
    exit "${code}"
}

# Save the two files this script may modify, so an abort can restore them
backup_files() {
    BACKUP_DIR="$(mktemp -d)"
    cp -p "${TARGET_SCRIPT}" "${TARGET_NAME}.config.example" "${BACKUP_DIR}/"
}

# Ask a yes/no question. Enter selects the default, which is "yes" unless the
# optional second argument is "n". Returns 0 on yes, 1 on no.
confirm() {
    local answer hint="[Y/n]" default="y"
    if [[ "${2:-y}" == "n" ]]; then
        hint="[y/N]"
        default="n"
    fi
    read -r -p "$1 ${hint} " answer
    answer="${answer,,}"
    [[ -n "${answer}" ]] || answer="${default}"
    [[ "${answer}" == "y" || "${answer}" == "yes" ]]
}

# Ask a yes/no question (default yes) and abort the run on anything but yes
confirm_or_abort() {
    confirm "$1" || die "${EXIT_ABORT}" "Aborted."
}

# Ask for a commit or tag message with an editable pre-filled text.
# Empty input and a bare prefix like "Fix:" are rejected.
# $1 prompt, $2 name of the target variable, $3 pre-filled text
ask_message() {
    local -n target="$2"
    local value=""
    while true; do
        read -e -r -i "$3" -p "$1: " value
        if [[ -z "${value// /}" ]]; then
            info "The message must not be empty."
        elif [[ "${value}" =~ ^(Fix|Add|Breaking):[[:space:]]*$ ]]; then
            info "Please describe the change after the prefix."
        else
            break
        fi
    done
    # shellcheck disable=SC2034  # assigned through the nameref
    target="${value}"
}

# Print usage information
usage() {
    cat <<USAGE
${SCRIPT_NAME} ${VERSION}
Release helper: checks the repo, raises VERSION, commits, pushes the branch,
creates a signed tag, verifies it and pushes the tag.

Run inside the working copy of the script to release:
  ${SCRIPT_NAME}.sh [--dry-run] [--help]

  --dry-run  run all checks and show the plan, change nothing
  --help     this help
USAGE
}

#--- Generic helpers ----------------------------------------------------------

# Abort unless the file exists and has the expected octal permissions
check_file() {
    local file="$1" expected="$2" actual
    [[ -f "${file}" ]] || die "${EXIT_CONFIG}" "Missing file: ${file}"
    actual="$(stat -c '%a' "${file}")"
    [[ "${actual}" == "${expected}" ]] \
        || die "${EXIT_CONFIG}" "Wrong permissions on ${file}: ${actual} (expected ${expected})"
}

# Return 0 if version $1 is greater than or equal to version $2
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# Read VAR="value" from a file: get_var <file> <VAR>
get_var() {
    sed -n "s/^$2=\"\([^\"]*\)\".*/\1/p" "$1" | head -n1
}

# Return 0 if the current directory is inside a git work tree
in_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# List all files that would be part of the repo (NUL separated)
list_files() {
    if in_repo; then
        git ls-files -z --cached --others --exclude-standard
    else
        find . -type f ! -name '*.config' ! -name '*.secrets' ! -name 'last-successful' -print0
    fi
}

#--- Checks -------------------------------------------------------------------

# Check git version, signing setup and commit mail on this PC
preflight() {
    local gv allowed mail
    command -v git >/dev/null || die "${EXIT_CHECK}" "git is not installed."
    gv="$(git --version | awk '{print $3}')"
    version_ge "${gv}" "${MIN_GIT_VERSION}" \
        || die "${EXIT_CHECK}" "git ${gv} is too old (at least ${MIN_GIT_VERSION} required)."
    [[ "$(git config --get gpg.format || true)" == "ssh" ]] \
        || die "${EXIT_CHECK}" "git config gpg.format is not 'ssh' (SSH tag signing is not set up, see your internal howtos)."
    [[ -n "$(git config --get user.signingkey || true)" ]] \
        || die "${EXIT_CHECK}" "git config user.signingkey is not set."
    [[ "$(git config --get tag.gpgSign || true)" == "true" ]] \
        || die "${EXIT_CHECK}" "git config tag.gpgSign is not 'true'."
    allowed="$(git config --get gpg.ssh.allowedSignersFile || true)"
    allowed="${allowed/#\~/${HOME}}"
    [[ -n "${allowed}" && -f "${allowed}" ]] \
        || die "${EXIT_CHECK}" "gpg.ssh.allowedSignersFile is not set or the file is missing (needed for 'git tag -v')."
    if [[ -n "${COMMIT_MAIL_DOMAIN}" ]]; then
        mail="$(git config --get user.email || true)"
        [[ "${mail}" == *"@${COMMIT_MAIL_DOMAIN}" ]] \
            || die "${EXIT_CHECK}" "Commit mail '${mail}' is not an @${COMMIT_MAIL_DOMAIN} address (the mail is public in the history)."
    fi
    if ! ssh-add -l >/dev/null 2>&1; then
        info "Note: no key in the ssh-agent. You will be asked for the passphrase when signing."
    fi
}

# Find the one *.sh file in the current directory; its name is the script/repo name
find_target() {
    local files=( ./*.sh )
    [[ -e "${files[0]}" ]] || die "${EXIT_CHECK}" "No *.sh in the current directory. Run this in the directory of the script."
    [[ ${#files[@]} -eq 1 ]] || die "${EXIT_CHECK}" "More than one *.sh in the current directory, exactly one is expected."
    TARGET_SCRIPT="$(basename "${files[0]}")"
    TARGET_NAME="${TARGET_SCRIPT%.sh}"
}

# Check the repo files: required files, .gitignore, versions, syntax, customer data
check_files() {
    local f example script_cfg example_cfg p hit=0
    example="${TARGET_NAME}.config.example"

    for f in "${TARGET_SCRIPT}" .gitignore README.md INSTALL.md "${example}"; do
        [[ -f "${f}" ]] || die "${EXIT_CHECK}" "Missing file: ${f}"
    done
    # A missing executable bit is fixed here (it often gets lost through copying or
    # syncing). The old mode is remembered so an abort can restore it. On a file
    # system that cannot keep the bit, the Git index is set to 755 before the commit anyway.
    if [[ ! -x "${TARGET_SCRIPT}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            info "Dry run: would set the executable bit on ${TARGET_SCRIPT}."
        else
            ORIG_MODE="$(stat -c '%a' "${TARGET_SCRIPT}")"
            chmod +x "${TARGET_SCRIPT}"
            info "Set the executable bit on ${TARGET_SCRIPT}."
        fi
    fi
    grep -qxF '*.config' .gitignore  || die "${EXIT_CHECK}" ".gitignore does not contain '*.config'."
    grep -qxF '*.secrets' .gitignore || die "${EXIT_CHECK}" ".gitignore does not contain '*.secrets'."

    # Config and secrets must never be tracked
    if in_repo && git ls-files --cached | grep -Eq '\.(config|secrets)$|(^|/)last-successful$'; then
        die "${EXIT_CHECK}" "A config, secrets or marker file is tracked in Git (git rm --cached ...)."
    fi

    # Versions in the script and the config example
    [[ "$(get_var "${TARGET_SCRIPT}" VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "${EXIT_CHECK}" "VERSION=\"x.y.z\" not found in ${TARGET_SCRIPT}."
    script_cfg="$(get_var "${TARGET_SCRIPT}" REQUIRED_CONFIG_VERSION)"
    example_cfg="$(get_var "${example}" CONFIG_VERSION)"
    [[ "${script_cfg}" =~ ^[0-9]+$ ]] || die "${EXIT_CHECK}" "REQUIRED_CONFIG_VERSION not found in ${TARGET_SCRIPT}."
    [[ "${script_cfg}" == "${example_cfg}" ]] \
        || die "${EXIT_CHECK}" "REQUIRED_CONFIG_VERSION (${script_cfg}) and CONFIG_VERSION in ${example} (${example_cfg:-missing}) do not match."

    # Syntax (and shellcheck, if installed)
    bash -n "${TARGET_SCRIPT}" || die "${EXIT_CHECK}" "Syntax error in ${TARGET_SCRIPT}."
    if command -v shellcheck >/dev/null; then
        shellcheck -S warning "${TARGET_SCRIPT}" || die "${EXIT_CHECK}" "shellcheck reports problems in ${TARGET_SCRIPT}."
    fi

    # Customer data must not appear in a public repo
    if [[ ${#CUSTOMER_PATTERNS[@]} -gt 0 ]]; then
        while IFS= read -r -d '' f; do
            for p in "${CUSTOMER_PATTERNS[@]}"; do
                if grep -I -i -n -F -- "${p}" "${f}" 2>/dev/null | sed "s|^|${f}:|"; then hit=1; fi
            done
        done < <(list_files)
        [[ ${hit} -eq 0 ]] || die "${EXIT_CHECK}" "Customer data found in the repo files (see above)."
    else
        info "Note: customer data check skipped (CUSTOMER_PATTERNS is empty)."
    fi
    info "File checks: ok"
}

# Abort if a text (commit or tag message) contains one of the customer patterns
check_text() {
    local p
    for p in "${CUSTOMER_PATTERNS[@]}"; do
        if grep -q -i -F -- "${p}" <<< "$1"; then
            die "${EXIT_CHECK}" "The message contains '${p}'. Customer data does not belong in the public history."
        fi
    done
}

#--- Version handling ---------------------------------------------------------

# Compute the next version: next_version <current> <patch|minor|major>
next_version() {
    local major minor patch
    IFS=. read -r major minor patch <<< "$1"
    case "$2" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
    esac
    printf '%s.%s.%s' "${major}" "${minor}" "${patch}"
}

# Write the new VERSION into the script
set_version() {
    sed -i "s/^VERSION=\"[^\"]*\"/VERSION=\"$1\"/" "${TARGET_SCRIPT}"
}

# Write the new config version into the script and the config example
set_config_version() {
    sed -i "s/^REQUIRED_CONFIG_VERSION=\"[^\"]*\"/REQUIRED_CONFIG_VERSION=\"$1\"/" "${TARGET_SCRIPT}"
    sed -i "s/^CONFIG_VERSION=\"[^\"]*\"/CONFIG_VERSION=\"$1\"/" "${TARGET_NAME}.config.example"
}

#--- Git steps ----------------------------------------------------------------

# Stage everything, show the result, ask, commit and push the branch.
# $1 pre-filled commit message, $2 extra push option (e.g. -u) or empty
commit_and_push() {
    local prefill="$1" push_args=("$2") msg
    git add -A
    STAGED=1
    git update-index --chmod=+x -- "${TARGET_SCRIPT}"
    step "Changes"
    git status --short
    if confirm "Show the full diff?" n; then
        git --no-pager diff --cached
    fi
    confirm_or_abort "Commit these changes and push ${BRANCH}?"
    ask_message "Commit message" msg "${prefill}"
    check_text "${msg}"
    ask_message "Tag message (stored with the tag, default = commit message)" TAG_MSG "${msg}"
    check_text "${TAG_MSG}"
    git commit -q -m "${msg}" || die "${EXIT_GIT}" "git commit failed."
    COMMITTED=1
    rm -rf "${BACKUP_DIR}"
    BACKUP_DIR=""
    # shellcheck disable=SC2086
    git push ${push_args[0]} origin "${BRANCH}" || die "${EXIT_GIT}" "git push of ${BRANCH} failed."
}

# Create the signed tag (if it does not exist yet), verify it locally and push
# only this tag
tag_and_push() {
    local tag="$1"
    step "Tag ${tag}"
    if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        if [[ -z "${TAG_MSG}" ]]; then
            ask_message "Tag message" TAG_MSG ""
            check_text "${TAG_MSG}"
        fi
        git tag -s "${tag}" -m "${TAG_MSG}" || die "${EXIT_GIT}" "Could not create the tag."
    fi
    if ! git tag -v "${tag}"; then
        die "${EXIT_GIT}" "The signature of ${tag} is not valid. The tag was not pushed, remove it locally with: git tag -d ${tag}"
    fi
    confirm "Signature ok. Push tag ${tag} now?" \
        || die "${EXIT_ABORT}" "Aborted. The tag ${tag} stays local, starting again continues the release."
    git push origin "${tag}" || die "${EXIT_GIT}" "Push of ${tag} failed."
    git --no-pager tag -n -l "${tag}"
    info "Done: ${tag} is pushed."
}

# Continue an interrupted release: VERSION is raised and committed, but the tag is
# missing (commit pushed) or only exists locally. Returns 0 if it handled the
# situation, 1 if this is a normal new release.
resume_release() {
    local cur="$1" tag="v$1" last_tag
    git ls-remote --tags origin "refs/tags/${tag}" | grep -q . && return 1
    if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        info "The tag ${tag} exists locally but is not on GitHub yet."
    else
        last_tag="$(git tag -l 'v*' --sort=-v:refname | head -n1)"
        if [[ -n "${last_tag}" ]]; then
            version_ge "${cur}" "${last_tag#v}" || return 1
            [[ "${cur}" != "${last_tag#v}" ]] || return 1
        fi
        [[ -z "$(git status --porcelain)" ]] || return 1
        [[ "$(git rev-list --count "origin/${BRANCH}..HEAD")" -eq 0 ]] || return 1
        info "Version ${cur} is committed and pushed, but not tagged yet."
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        info "Dry-run: starting again would create or push the tag ${tag}."
        return 0
    fi
    confirm_or_abort "Continue release ${tag} now?"
    tag_and_push "${tag}"
    return 0
}

#--- Flows --------------------------------------------------------------------

# Existing repo: compare the local branch with the GitHub branches. If everything
# is the expected default branch, nothing is asked. Otherwise show the situation
# and let the user choose one of the branches that exist on GitHub.
select_branch() {
    local local_branch remote_default heads=() name i choice
    git symbolic-ref -q --short HEAD >/dev/null || die "${EXIT_CHECK}" "Detached HEAD, please switch to a branch first."
    local_branch="$(git symbolic-ref --short HEAD)"
    remote_default="$(git ls-remote --symref origin HEAD | sed -n 's|^ref: refs/heads/\(.*\)\tHEAD$|\1|p')"
    [[ -n "${remote_default}" ]] || die "${EXIT_CHECK}" "There is no branch on GitHub yet (empty repo?)."
    if [[ "${local_branch}" == "${remote_default}" && "${remote_default}" == "${DEFAULT_BRANCH}" ]]; then
        BRANCH="${local_branch}"
        return 0
    fi

    step "Branch"
    info "Local branch:          ${local_branch}"
    info "GitHub default branch: ${remote_default}"
    info "Expected (config):     ${DEFAULT_BRANCH}"
    mapfile -t heads < <(git ls-remote --heads origin | sed 's|.*refs/heads/||')
    echo "Branches on GitHub:"
    for i in "${!heads[@]}"; do
        name="${heads[${i}]}"
        printf '  [%d] %s%s%s\n' "$((i + 1))" "${name}" \
            "$([[ "${name}" == "${remote_default}" ]] && printf ' (GitHub default)')" \
            "$([[ "${name}" == "${local_branch}" ]] && printf ' (active locally)')"
    done
    if [[ ${DRY_RUN} -eq 1 ]]; then
        info "Dry-run: the branch would be asked here. The dry-run ends at this point."
        exit "${EXIT_OK}"
    fi
    read -r -p "Which branch should the release run on? [number]: " choice
    [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le ${#heads[@]} ]] \
        || die "${EXIT_USAGE}" "Invalid selection."
    BRANCH="${heads[$((choice - 1))]}"
    if [[ "${BRANCH}" != "${local_branch}" ]]; then
        if git show-ref -q --verify "refs/heads/${BRANCH}"; then
            git switch -q "${BRANCH}" || die "${EXIT_GIT}" "Switching to ${BRANCH} failed (local changes in the way?)."
        else
            git switch -q -c "${BRANCH}" --track "origin/${BRANCH}" || die "${EXIT_GIT}" "Switching to ${BRANCH} failed."
        fi
        SWITCHED_FROM="${local_branch}"
        info "Now on branch ${BRANCH}."
    fi
}

# New repository: start with v1.0.0
flow_new() {
    local url web cur refs
    in_repo && die "${EXIT_CHECK}" "There is already a Git repo here. Please choose 'existing repo'."
    # shellcheck disable=SC2059
    url="$(printf "${REMOTE_URL_TEMPLATE}" "${TARGET_NAME}")"
    web="https://github.com/${GITHUB_ORG}/${TARGET_NAME}"
    cur="$(get_var "${TARGET_SCRIPT}" VERSION)"

    step "Plan: new repo ${TARGET_NAME}"
    info "Remote:  ${url}"
    info "Version: 1.0.0 (tag v1.0.0), the script says ${cur}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        info "Dry-run: nothing was changed."
        info "Before the real run, create the EMPTY public repo: ${web} (no README, .gitignore or license)."
        return 0
    fi

    confirm_or_abort "README.md, INSTALL.md and ${TARGET_NAME}.config.example are up to date?"
    echo
    info "NOW create the empty public repo on GitHub:"
    info "  ${web}"
    info "  (organisation ${GITHUB_ORG}, public, without README, .gitignore and license)"
    read -r -p "Press Enter when the repo is created... " _
    if ! refs="$(git ls-remote "${url}" 2>&1)"; then
        die "${EXIT_GIT}" "Repo ${url} is not reachable: ${refs}"
    fi
    [[ -z "${refs}" ]] || die "${EXIT_CHECK}" "The repo ${url} is not empty."

    backup_files
    if [[ "${cur}" != "1.0.0" ]]; then
        confirm_or_abort "VERSION in the script is ${cur}. Set it to 1.0.0?"
        set_version "1.0.0"
    fi
    BRANCH="${DEFAULT_BRANCH}"
    git init -q -b "${BRANCH}"
    CREATED_GIT=1
    git remote add origin "${url}"
    commit_and_push "Initial version" "-u"
    tag_and_push "v1.0.0"
}

# Existing repository: raise the version
flow_existing() {
    local top last_tag cur level new cfg_now cfg_tag new_cfg="" url prefill
    in_repo || die "${EXIT_CHECK}" "There is no Git repo here. Please choose 'new repo'."
    top="$(git rev-parse --show-toplevel)"
    [[ "${top}" == "$(pwd -P)" ]] || die "${EXIT_CHECK}" "Please run this in the top directory of the repo (${top})."
    # shellcheck disable=SC2059
    url="$(printf "${REMOTE_URL_TEMPLATE}" "${TARGET_NAME}")"
    [[ "$(git remote get-url origin 2>/dev/null || true)" == "${url}" ]] \
        || die "${EXIT_CHECK}" "Remote 'origin' is not ${url}."
    git fetch -q origin --tags || die "${EXIT_GIT}" "git fetch failed."
    select_branch
    [[ "$(git rev-list --count "HEAD..origin/${BRANCH}")" -eq 0 ]] \
        || die "${EXIT_CHECK}" "origin/${BRANCH} has newer commits. Run git pull first."

    cur="$(get_var "${TARGET_SCRIPT}" VERSION)"
    if resume_release "${cur}"; then
        return 0
    fi
    last_tag="$(git tag -l 'v*' --sort=-v:refname | head -n1)"
    [[ -n "${last_tag}" ]] || die "${EXIT_CHECK}" "No tag found. Is this a new repo?"
    [[ "${cur}" == "${last_tag#v}" ]] \
        || die "${EXIT_CHECK}" "VERSION in the script (${cur}) does not match the last tag (${last_tag}). Do not change VERSION by hand, this script does it. If a release was interrupted: commit and push all other changes (or set them aside) first, then starting again continues the release."
    if git diff --quiet "${last_tag}" && [[ -z "$(git status --porcelain)" ]]; then
        die "${EXIT_CHECK}" "No changes since ${last_tag}."
    fi

    step "Plan: ${TARGET_NAME}, branch ${BRANCH}, last tag ${last_tag}"
    echo "Which level?"
    echo "  [1] Patch  (bug fix)"
    echo "  [2] Minor  (new feature, config unchanged)"
    echo "  [3] Major  (config or behaviour incompatible)"
    read -r -p "Selection [1/2/3]: " level
    case "${level}" in
        1) level="patch"; prefill="Fix: " ;;
        2) level="minor"; prefill="Add: " ;;
        3) level="major"; prefill="Breaking: " ;;
        *) die "${EXIT_USAGE}" "Invalid selection." ;;
    esac
    new="$(next_version "${cur}" "${level}")"

    # Config version rules: a changed CONFIG_VERSION always means a major release
    cfg_now="$(get_var "${TARGET_NAME}.config.example" CONFIG_VERSION)"
    cfg_tag="$(git show "${last_tag}:${TARGET_NAME}.config.example" 2>/dev/null | sed -n 's/^CONFIG_VERSION="\([^"]*\)".*/\1/p' | head -n1)"
    [[ -n "${cfg_tag}" ]] || die "${EXIT_CHECK}" "Cannot read CONFIG_VERSION in ${last_tag}."
    if [[ "${cfg_now}" != "${cfg_tag}" && "${level}" != "major" ]]; then
        die "${EXIT_CHECK}" "CONFIG_VERSION was changed (${cfg_tag} -> ${cfg_now}). That is always a major release."
    fi
    if [[ "${level}" == "major" && "${cfg_now}" == "${cfg_tag}" ]]; then
        new_cfg=$((cfg_now + 1))
    fi

    info "New version: ${new} (tag v${new})"
    if [[ -n "${new_cfg}" ]]; then
        info "CONFIG_VERSION: ${cfg_now} -> ${new_cfg} (script and .config.example)"
    fi
    git ls-remote --tags origin "refs/tags/v${new}" | grep -q . \
        && die "${EXIT_CHECK}" "Tag v${new} already exists on GitHub."
    git rev-parse -q --verify "refs/tags/v${new}" >/dev/null \
        && die "${EXIT_CHECK}" "Tag v${new} already exists locally."
    if [[ ${DRY_RUN} -eq 1 ]]; then
        info "Dry-run: nothing was changed."
        return 0
    fi

    confirm_or_abort "README.md, INSTALL.md and ${TARGET_NAME}.config.example are up to date?"
    backup_files
    set_version "${new}"
    if [[ -n "${new_cfg}" ]]; then
        set_config_version "${new_cfg}"
    fi
    commit_and_push "${prefill}" ""
    tag_and_push "v${new}"
}

# Ctrl-C ends the run like an abort (with rollback)
trap 'echo; die "${EXIT_ABORT}" "Aborted (Ctrl-C)."' INT

# Whatever ends the run (also set -e after Ctrl-D or an unexpected error), the
# rollback runs. It does nothing once the commit exists or if nothing was changed.
trap rollback EXIT

#--- Options ------------------------------------------------------------------

for arg in "$@"; do
    case "${arg}" in
        --help|-h) usage; exit "${EXIT_OK}" ;;
        --dry-run) DRY_RUN=1 ;;
        *)         usage >&2; exit "${EXIT_USAGE}" ;;
    esac
done

#--- Startup ------------------------------------------------------------------

# Load config (SCRIPT_DIR and SCRIPT_NAME are available inside it)
check_file "${CONFIG_FILE}" 660
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Config must match the version this script expects
[[ "${CONFIG_VERSION:-}" == "${REQUIRED_CONFIG_VERSION}" ]] \
    || die "${EXIT_CONFIG}" "CONFIG_VERSION '${CONFIG_VERSION:-unset}' does not match, expected ${REQUIRED_CONFIG_VERSION}."
[[ -n "${GITHUB_ORG:-}" ]] || die "${EXIT_CONFIG}" "GITHUB_ORG is not set in ${CONFIG_FILE}."
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is missing in the config}"
: "${REMOTE_URL_TEMPLATE:?REMOTE_URL_TEMPLATE is missing in the config}"
: "${MIN_GIT_VERSION:?MIN_GIT_VERSION is missing in the config}"
COMMIT_MAIL_DOMAIN="${COMMIT_MAIL_DOMAIN:-}"

# --- Main logic ---
[[ ${DRY_RUN} -eq 1 ]] && info "*** DRY-RUN: nothing will be changed ***"
preflight
find_target
info "Script in the current directory: ${TARGET_SCRIPT}"
check_files

echo
echo "What should happen?"
echo "  [1] Create a new repo (start with v1.0.0)"
echo "  [2] Existing repo: script changed, raise the version"
read -r -p "Selection [1/2]: " mode
case "${mode}" in
    1) flow_new ;;
    2) flow_existing ;;
    *) die "${EXIT_USAGE}" "Invalid selection." ;;
esac

exit "${EXIT_OK}"
