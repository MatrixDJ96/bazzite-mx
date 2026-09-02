# Conventions

Rules for writing scripts, CI and prose in this repo. A rule a file enforces names that file;
the rest is checked by hand at review.

Contents: Bash (Form) · positive control · CI · prose · commits.

## Bash

- `#!/usr/bin/env bash` and `set -euo pipefail`.
- Clean under `shellcheck -x -P SCRIPTDIR --severity=warning`, formatted by
  `shfmt --indent 4 --case-indent --binary-next-line --space-redirects`. `-x -P SCRIPTDIR`
  follows the sourced libraries, so a variable a library sets is not reported as undefined.
- The `lint` job of `build.yml` runs both over every `.sh` git tracks plus every file carrying
  the repo's shebang, so an extensionless script is covered too.
- The shfmt release is fixed at Fedora 44's, so the hook and the lint job cannot disagree on a
  diff. CI installs it in `quay.io/fedora/fedora:44`. The edit hook
  `.claude/hooks/lint-edit.sh` uses the host binary only when its minor matches, and the same
  container otherwise.
- A function a caller may run under `if` or `||` returns a status and never calls `exit`: under
  `if`, `exit` kills the whole script, and a `2>/dev/null` on the call hides why. The CI
  scripts follow it, and their `--self-test` exercises the failing paths as calls. An exit left
  where nothing remains to unwind is named in the function's header.
- A comment must not start with `# shellcheck` unless it is a directive: shellcheck parses the
  line as one and the file stops parsing.

### Form

A script is read by a person before bash runs it, and the person is not the author. These rules
hold for every file the lint job covers: libraries, the CI scripts and the edit hook. They hold
in the same spirit for every other file of the repo: a workflow or the Containerfile gets the
same blank lines between its steps, the same 100 columns and comments that carry a reason,
never a restatement. The shapes and the width are checked by `.github/scripts/check-form.sh`,
which the edit hook runs on every shell file an edit touches and the `lint` job on the whole
shell catalogue; a line that holds a banned shape as data ends in `# form: literal`. The rest
is checked by hand at review, like § Prose.

- **Control flow is written as `if … then … fi`.** `cmd || return 1`, `a && b || c`,
  `! cmd || die`, `cmd || { … }` and a subshell `( … ) ||` used as a guard are out: they hide
  the branch in a trailing operator and read backwards. `set -e` keeps its role, a command that
  fails outside an `if` still stops the script.

- **Output is captured before `grep -q`.** `cmd | grep -q` is refused by `check-form.sh`:
  `grep -q` exits at the first match and closes the pipe, the writer dies of SIGPIPE and
  `pipefail` reports a failure on some runs, whatever the writer. The output goes into a
  variable first, and the grep reads the variable.

- **A fallback is `${var:-…}`, never `|| echo`.** `$(cmd || echo x)` is refused by
  `check-form.sh`: a command that prints its answer and exits non-zero (`grep -c`,
  `systemctl is-enabled`, `is-active`) leaves x under what it printed, two lines for one. The
  output is captured with `|| true` and the fallback sits in the expansion.

- **A pipeline assigned carries `|| true` or opens a condition.** `var=$(grep …)` and
  `var=$(cmd | …)` are refused by `check-form.sh` without one of the two: under `pipefail` an
  element that fails (a grep matching nothing, `just` on a broken file, `head` closing early)
  fails the assignment and `set -e` ends the script.
  `|| true` when nothing found is a value, the fallback naming what was not found;
  `if ! var=$(…); then` when the failure is an error.

- **A command's output enters `$(( ))` through a variable.** `check-form.sh` refuses
  `$((n + $(cmd)))`: an empty output is a syntax error `set -e` does not stop.

  ```bash
  # before, check-form.sh
  findings=$((findings + $(wc -l <<< "$output")))
  # after
  count=$(wc -l <<< "$output")
  findings=$((findings + count))
  ```

- **One action per line.** No `a; b`, no `if …; then a; else b; fi` on one line, one command
  per line inside a branch, a `case` arm on its own lines.

- **Blank lines separate the steps.** One after the `local` line, one between the steps of a
  function (gather, check, act, report), one around each `if` block that is not the function's
  only statement. A file with more than a handful of functions groups them under banners,
  `# --- <group> ---` padded to 80 columns, in the order a reader needs them: helpers first,
  commands after, `main` last.

- **A line stops at 100 columns.** A long command breaks after `\` with one argument per line;
  a long pattern or message goes into a variable named for what it holds.

- **A name says what the function does or what the variable holds.** No private vocabulary.
  `die` is named by its effect: `exit_with_error` in the CI scripts (`.github/scripts/lib.sh`,
  prints `<script>: …`, the script stops), where `print_error` prints the same line and returns
  1 for a function a caller runs under `if`. A function a caller runs under `if` is named as
  the question its status answers.

- **Every script opens with a header**: what it does in one or two sentences; `Usage:` with
  each argument and option on its own line; the exit status; what it writes, files and the
  output lines a test or a recipe reads. A library says who sources it and what it expects.

- **A comment says what the code cannot.** The contract of a function when its name does not
  carry it (empty when…, status 0 when…), or the reason for a choice the reader would otherwise
  question. A comment that restates the name or the next line is deleted; a function whose name
  and arguments say it all has none.

- **A function stays short**, about 25 statements as the guide (blank and comment lines do not
  count): a function that does two things is two functions, and a step sequence reads as a list
  of calls. A library is written to share functions between scripts, never to make one file
  shorter: a long script stays one file, grouped under banners.

- **Output to the user is a complete sentence**: what happened, and for a failure what to do
  next. The prefixes a contract reads (`OK:`, `FAIL:`, `ERROR:`, `self-test ok`) stay.

A rewrite for form proves behaviour unchanged: the same arguments, the same exit status, the
same messages where a test or a doc cites them, every self-test green before and after, every
known-bad still red after it. The rules above add to the earlier bullets of this section and to
§ Positive control; they replace none.

## Positive control

Every guard ships a `--self-test` that feeds it known-bad input and requires the failure, and a
new probe is seen red on a lesion before its first green counts. Each check also accepts the
good input, on its own or in the composition that runs it, so a check that silently disappeared
turns the self-test red instead of passing every input alike. The rule cuts both ways: a guard,
a stub branch or a case enters only for a state a host, a build or CI actually reaches, and a
state only a hand call or a hypothesis produces gets one sentence in the header instead.

Removing a case asks a different question from adding one: not "is it needed?" but "who else
proves this?". Name the surviving owner of the fact and run it before the case goes. A fact
that lives outside the repo (in the base image, on the host, in a registry) has no lint
covering it, and the case stays: shellcheck sees the repo alone, so "the lint already parses
that file" is no owner of a `declare -r` name the base image's libraries set.

An assertion also has to be able to go red, and the shape that quietly cannot is not the one a
reader expects. A count is safe or not by where its subject comes from, never by being a count.
A check that counts or walks a list read out of the very thing it tests shrinks with the defect
and stays green: a required number of `OK:` lines lets a check stop reporting unnoticed. Name
what a count stands for. The same reading condemns a tolerant `else` that prints `OK:` on the
failure it meant to excuse. Neither shape holds a counter, so neither is found by grepping for
one.

Where each one runs:

| Self-test                                                 | Where it runs                                                                                                                                             |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/scripts/*.sh`                                    | `lint` job, `build.yml`                                                                                                                                   |
| `check-form.sh`                                           | `lint` job, `build.yml`, which then runs the check itself over the whole shell catalogue; `.claude/hooks/lint-edit.sh` runs it on every edited shell file |

## CI

- Names follow `ublue-os/bazzite`'s workflows (`bazzite/.github/workflows/build.yml`: jobs
  `Version`, `Make`, `Generate Release`; steps `Build Image`, `Apply Labels`, `Push to GHCR`,
  `Install Cosign`). Workflow `name:` Title Case. A job name is the phase in one Title Case
  word: `Lint`, `Build`; the matrix job of the reusable build is named by its flavour, so a run
  reads `Build / bazzite-nvidia`. A step name is Title Case, verb + object, no article, a tool
  in its own casing: `Checkout`, `Resolve Base`, `Build Image`, `Run shfmt and yamllint`. Env
  vars `SCREAMING_SNAKE_CASE`; outputs `snake_case`, one key name across workflows.
- Concurrency groups are literal `bazzite-mx-<phase>[-<key>]` and never built from
  `${{ github.workflow }}`. A called workflow reports the caller's name there, so a group built
  from it would put caller and callee in the same group and the callee would wait for the run
  that started it.
- Every third-party `uses:` is pinned to a commit SHA with the version in a trailing comment.
- `ubuntu-26.04` for jobs that need podman or skopeo, which every job here does.
- `runner.temp` is not available in a job-level `env:`; steps read `$RUNNER_TEMP`.
- A dispatch on a branch runs that branch's copy of the file,
  `gh workflow run build.yml --ref <branch>`.
- Values an expression computes reach a step through `env:`, never inline in `run:`: an input
  or a label carrying a quote would break the script (GitHub docs, "Security hardening for
  GitHub Actions").
- Retries are loops in the step or the tool's own flag (`skopeo inspect --retry-times 3`),
  never an action: one pin fewer for a `for` loop.

## Prose

A claim in a doc, a comment or a script's output names its source (a file, a manual page, a
URL). No linter reads prose: it is checked by hand at review.

## Commits

`.github/scripts/check-commits.sh` checks every message over the whole history of the pushed
ref in the `lint` job:

- the subject is `<type>(<scope>): <what>` (Conventional Commits; `feat`, `fix`, `docs`,
  `chore`, `refactor`, `ci`, `test`, `build`), at most 72 columns, no trailing period;
- a blank line before an optional body;
- no trailer (`Signed-off-by`, `Co-authored-by`, a session link): the author is the metadata.

A body is natural lines, one per point, never hard-wrapped; no linter reads it, review does.
