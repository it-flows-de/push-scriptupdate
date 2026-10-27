# push-scriptupdate

Interactive Bash script that releases other scripts which have their own public GitHub
repo. It checks the working copy, raises the version, commits, pushes the branch,
creates a signed Git tag, verifies the signature and pushes the tag.

## How it works

Run it in the working copy of the script you want to release and choose:

- **New repo:** after you created the empty public repo on GitHub, the script runs `git init`, commits, pushes and creates the tag `v1.0.0`.
- **Existing repo:** you choose the level (patch, minor, major). The script raises `VERSION` (and `CONFIG_VERSION` on a major release), commits, pushes the branch and creates the next tag.

Before anything is changed it checks, among other things:

- the signing setup of Git on this PC and the public commit mail
- required files, `.gitignore` and that no config or secrets file is tracked; a missing executable bit on the script is set (and restored if the run is aborted)
- `VERSION` and `CONFIG_VERSION` are consistent (a changed `CONFIG_VERSION` is always a major release), syntax and, if installed, `shellcheck`
- optional customer words that must not appear in the repo files or in commit and tag messages
- the branch: if the local branch or the GitHub default branch is not the expected one, you choose one of the branches that exist on GitHub

Commit and tag messages are pre-filled (`Initial version`, `Fix: `, `Add: `,
`Breaking: `). The tag message defaults to the commit message. If a run is aborted
before the commit, all changes of the run are reverted. An interrupted release (commit
pushed, tag missing or only local) is continued by starting the script again.

## Requirements

- Bash, Git 2.34 or newer, `ssh-keygen`; `shellcheck` is optional
- A normal user on the development PC, with the signing key and push access to GitHub

## Installation

See [INSTALL.md](INSTALL.md).

## Configuration

Copy `push-scriptupdate.config.example` to `push-scriptupdate.config` next to the
script, edit it and set permissions to `660`. The example file is commented and
documents every parameter. The config is never committed to Git.

| Parameter             | Block    | Meaning                                                         | Default                               |
|-----------------------|----------|-----------------------------------------------------------------|---------------------------------------|
| `CONFIG_VERSION`      | \-       | Config format version, must match the script                    | `1`                                   |
| `GITHUB_ORG`          | required | GitHub organisation that holds the script repos                 | `it-flows-de`                         |
| `CUSTOMER_PATTERNS`   | optional | Words that must never appear in the repo, empty = check skipped | empty                                 |
| `DEFAULT_BRANCH`      | default  | Branch for new repos and the expected branch                    | `main`                                |
| `REMOTE_URL_TEMPLATE` | default  | SSH remote, `%s` is the script name                             | `git@github.com:${GITHUB_ORG}/%s.git` |
| `MIN_GIT_VERSION`     | default  | Minimum Git version                                             | `2.34`                                |
| `COMMIT_MAIL_DOMAIN`  | default  | Required domain of the commit mail, empty = check skipped       | `users.noreply.github.com`            |

## Usage

```
push-scriptupdate.sh [--dry-run] [--help]
```

| Option      | Meaning                                          |
|-------------|--------------------------------------------------|
| `--dry-run` | Run all checks and show the plan, change nothing |
| `--help`    | Show the help                                    |

## Exit codes

| Code | Meaning                                                                                      |
|------|----------------------------------------------------------------------------------------------|
| 0    | OK                                                                                           |
| 2    | Wrong option or selection                                                                    |
| 3    | Config error (missing file, wrong permissions, wrong `CONFIG_VERSION`, `GITHUB_ORG` not set) |
| 5    | A check failed                                                                               |
| 6    | Aborted by the user (local changes of the run were reverted)                                 |
| 7    | A Git operation failed (network, push access, signature)                                     |
