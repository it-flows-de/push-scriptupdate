# Installation: push-scriptupdate

Interactive Bash script for the development PC. It releases other scripts: it checks
the working copy, raises the version, commits, pushes the branch, creates and verifies a
signed tag and pushes the tag. Runs as a normal user, no root needed.

All commands are meant to be pasted into **one terminal session**. The variables from
step 0 and step 3 only exist in that session. If you open a new terminal, repeat
step 0 and run `source "${CONFIG_FILE}"` again.

## 0. Variables

```bash
INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME=push-scriptupdate
CONFIG_FILE="${INSTALL_DIR}/${SCRIPT_NAME}.config"
TAG=v1.0.0
```

The script and its config live together in `INSTALL_DIR`, which must be in your `PATH`.
This is a tool on your PC, so it is not installed under `/usr/local/scripts`.

## 1. Prerequisites

```bash
sudo apt install git openssh-client shellcheck
git --version
```

Git must be 2.34 or newer. `shellcheck` is optional: if it is installed, the script
runs it on the script it releases.

The signing setup on this PC (signing key, `allowed_signers`, Git configuration and the
public commit mail) is described in your internal howtos. Check that it is in place:

```bash
git config --get gpg.format
git config --get user.signingkey
git config --get tag.gpgSign
git config --get gpg.ssh.allowedSignersFile
git config --get user.email
ssh -T git@github.com
```

Expected: `ssh`, the path of your signing key, `true`, the path of `allowed_signers`
and a `...@users.noreply.github.com` address. The last command should greet you with
your GitHub user name (it exits with code 1, that is normal).

## 2. Install the files

```bash
mkdir -p "${INSTALL_DIR}"
```

### Variant A: release path (signed tag)

```bash
WORK="$(mktemp -d)"
git clone "https://github.com/it-flows-de/${SCRIPT_NAME}.git" "${WORK}/${SCRIPT_NAME}"
cd "${WORK}/${SCRIPT_NAME}"
git verify-tag "${TAG}" && git checkout "${TAG}"
install -m 755 "${SCRIPT_NAME}.sh" "${INSTALL_DIR}/"
install -m 644 "${SCRIPT_NAME}.config.example" "${INSTALL_DIR}/"
cd && rm -rf "${WORK}"
```

The files are only copied if the signature check succeeds.

### Variant B: development path (only before the first release)

Create the files and copy the content from the ZIP with an editor of your choice:

```bash
cd "${INSTALL_DIR}"
touch "${SCRIPT_NAME}.sh" "${SCRIPT_NAME}.config.example"
chmod 755 "${SCRIPT_NAME}.sh"
```

### Check the PATH

```bash
echo "${PATH}" | tr ':' '\n' | grep -x "${INSTALL_DIR}"
```

If there is no output, add the directory to `~/.profile` (with `vi`) and log in again.

## 3. Config

```bash
cd "${INSTALL_DIR}"
cp "${SCRIPT_NAME}.config.example" "${SCRIPT_NAME}.config"
vi "${CONFIG_FILE}"
chmod 660 "${CONFIG_FILE}"
source "${CONFIG_FILE}"
echo "GITHUB_ORG=${GITHUB_ORG} DEFAULT_BRANCH=${DEFAULT_BRANCH} patterns=${#CUSTOMER_PATTERNS[@]}"
```

The config is sourced by bash and is therefore code. It stays on this PC and is never
committed. Fill `CUSTOMER_PATTERNS` with the words that must never appear in a public
repo, see the comments in the file.

## 4. Test

Help:

```bash
"${SCRIPT_NAME}.sh" --help
```

Error case: wrong permissions on the config (expected: error message, exit code 3):

```bash
chmod 664 "${CONFIG_FILE}"
"${SCRIPT_NAME}.sh"; echo "exit code: $?"
chmod 660 "${CONFIG_FILE}"
```

Dry-run in the working copy of any script (checks only, changes nothing):

```bash
cd /path/to/working-copy-of-a-script
"${SCRIPT_NAME}.sh" --dry-run
```

## Troubleshooting

| Exit code | Meaning | What to check |
|---|---|---|
| 0 | OK | - |
| 2 | Wrong option or selection | Run with `--help` |
| 3 | Config error | Config exists, permissions are `660`, `CONFIG_VERSION` matches, `GITHUB_ORG` is set |
| 5 | A check failed | Read the message: git setup, missing files, customer data, version mismatch |
| 6 | Aborted by you | Local changes of the run were reverted, start again |
| 7 | Git operation failed | Read the message: network, push access, signature |
