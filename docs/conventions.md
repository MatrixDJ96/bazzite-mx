# Conventions

Rules for writing build scripts, tests, ujust recipes, boot hooks, CI and prose in this repo. A
rule a file enforces names that file; the rest is checked by hand at review.

Contents: Bash (Form) · build scripts · ujust recipes · boot hooks · tests · positive control ·
CI · prose · commits.

## Bash

- `#!/usr/bin/env bash` and `set -euo pipefail`. A build script carries the shebang and takes
  the `set` from `lib/env.sh`, which every `NN-<feature>.sh` sources on its first line.
- Clean under `shellcheck -x -P SCRIPTDIR --severity=warning`, formatted by
  `shfmt --indent 4 --case-indent --binary-next-line --space-redirects`. `-x -P SCRIPTDIR`
  follows the sourced libraries, so a variable a library sets is not reported as undefined.
- The `lint` job of `build.yml` runs both over every `.sh` git tracks plus every file carrying
  the repo's shebang, which is how the extensionless helpers under `system_files/usr/libexec/`
  are covered.
- The shfmt release is fixed at Fedora 44's, so the hook and the lint job cannot disagree on a
  diff. CI installs it in `quay.io/fedora/fedora:44`. The edit hook
  `.claude/hooks/lint-edit.sh` uses the host binary only when its minor matches, and the same
  container otherwise.
- A function a caller may run under `if` or `||` returns a status and never calls `exit`: under
  `if`, `exit` kills the whole script, and a `2>/dev/null` on the call hides why. The CI
  scripts follow it, and their `--self-test` exercises the failing paths as calls. An exit left
  where nothing remains to unwind is named in the function's header (`switch_fstab_rows` in the
  ntfsplus helper).
- A comment must not start with `# shellcheck` unless it is a directive: shellcheck parses the
  line as one and the file stops parsing.

### Form

A script is read by a person before bash runs it, and the person is not the author. These rules
hold for every file the lint job covers: build scripts, libraries, tests, the kmod builder, the
libexec helpers, the boot hooks, the CI scripts and the edit hook. They hold in the same spirit
for every other file of the repo: a workflow, the Containerfile, a justfile, a Plasma update
script, a `.repo` or `.conf` file gets the same blank lines between its steps, the same 100
columns and comments that carry a reason, never a restatement. Each rule carries one
before/after pair from the repo. The shapes and the width are checked by
`.github/scripts/check-form.sh`, which the edit hook runs on every shell file an edit touches
and the `lint` job on the whole shell catalogue; a line that holds a banned shape as data ends
in `# form: literal`. The rest is checked by hand at review, like § Prose.

- **Control flow is written as `if … then … fi`.** `cmd || return 1`, `a && b || c`,
  `! cmd || die`, `cmd || { … }` and a subshell `( … ) ||` used as a guard are out: they hide
  the branch in a trailing operator and read backwards. `set -e` keeps its role, a command that
  fails outside an `if` still stops the script.

  ```bash
  # before, lib/just.sh
  out=$(just --justfile "$1" --summary 2> /dev/null) || return 1
  # after
  if ! summary=$(just --justfile "$justfile" --summary 2> /dev/null); then
      return 1
  fi
  ```

  ```bash
  # before, 22-virtualization.sh
  ! rpm -q "$pkg" > /dev/null || die "$pkg was pulled in (the image keeps binfmt out)"
  # after
  if rpm -q "$package" > /dev/null; then
      fail_build "$package was pulled in (the image keeps binfmt out)"
  fi
  ```

  A function that must clean up before it fails returns a status after its own cleanup, so the
  caller needs no subshell: `(runtime_probe) || withdraw "…"` in the ntfsplus helper became
  `if ! run_runtime_probe; then roll_back_enable "…"; fi`, the probe removing its files on both
  paths.

- **Output is captured before `grep -q`.** `cmd | grep -q` is refused by `check-form.sh`:
  `grep -q` exits at the first match and closes the pipe, the writer dies of SIGPIPE and
  `pipefail` reports a failure on some runs, whatever the writer ([`gotchas.md`](gotchas.md) §
  `command | grep -q` under `pipefail` fails on a match). The output goes into a variable
  first, and the grep reads the variable.

  ```bash
  # before, tests/30-ide.sh
  if rpm -q gpg-pubkey --qf '%{VERSION}\n' | grep -qi 'be1229cf$'; then
  # after, tests/lib.sh
  keys=$(rpm -q gpg-pubkey --qf '%{VERSION}\n' 2> /dev/null || true)

  if grep -qi "$key_id\$" <<< "$keys"; then
  ```

- **A fallback is `${var:-…}`, never `|| echo`.** `$(cmd || echo x)` is refused by
  `check-form.sh`: a command that prints its answer and exits non-zero (`grep -c`,
  `systemctl is-enabled`, `is-active`) leaves x under what it printed, two lines for one. The
  output is captured with `|| true` and the fallback sits in the expansion.

  ```bash
  # before, 82-bazzite-sunshine.just
  enabled=$(systemctl --user is-enabled "$UNIT" 2> /dev/null || echo disabled)
  # after
  enabled=$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)
  active=$(systemctl --user is-active "$UNIT" 2>/dev/null || true)
  echo "$UNIT: ${enabled:-unknown} / ${active:-unknown}"
  ```

- **A pipeline assigned carries `|| true` or opens a condition.** `var=$(grep …)` and
  `var=$(cmd | …)` are refused by `check-form.sh` without one of the two: under `pipefail` an
  element that fails (a grep matching nothing, `just` on a broken file, `head` closing early)
  fails the assignment, `set -e` ends the script, and a `FAIL:` branch written that way died
  before its verdict ([`gotchas.md`](gotchas.md) § A FAIL branch died before its verdict).
  `|| true` when nothing found is a value, the fallback naming what was not found;
  `if ! var=$(…); then` when the failure is an error. A `FAIL:` line quoting a probe's output
  goes through `on_one_line <fallback>` of `tests/lib.sh`, which never leaves it blank.

  ```bash
  # before, tests/30-ide.sh
  gpg_lines=$(grep -E '^gpg' "$VSCODE_REPO" | tr '\n' ' ')
  echo "FAIL: vscode.repo: $gpg_lines"
  # after, tests/lib.sh
  gpg_lines=$(grep -E '^gpg' "$repo" 2>&1 | tr '\n' ' ' || true)
  echo "FAIL: $repo: ${gpg_lines:-no gpg line}"
  ```

- **A command's output enters `$(( ))` through a variable.** `check-form.sh` refuses
  `$((n + $(cmd)))`: an empty output is a syntax error `set -e` does not stop
  ([`gotchas.md`](gotchas.md) § An arithmetic syntax error escapes `set -e`).

  ```bash
  # before, check-form.sh
  findings=$((findings + $(wc -l <<< "$output")))
  # after
  count=$(wc -l <<< "$output")
  findings=$((findings + count))
  ```

- **One action per line.** No `a; b`, no `if …; then a; else b; fi` on one line, one command
  per line inside a branch, a `case` arm on its own lines.

  ```bash
  # before, bazzite-mx-ntfsplus-setup
  if [ -n "$FIXTURE" ]; then awk -v t="$1" '$1 == t { print $2 }' "$FIXTURE/cmd/mounts"; else findmnt -n -o FSTYPE --mountpoint "$1" 2> /dev/null || true; fi
  # after, host.sh
  if [ -n "$FIXTURE" ]; then
      MOUNT_TARGET="$mount_point" awk '{
          …
      }' "$FIXTURE/cmd/mounts" | tail -n 1
      return 0
  fi

  findmnt -n -o FSTYPE --mountpoint "$mount_point" 2> /dev/null | tail -n 1 || true
  ```

- **Blank lines separate the steps.** One after the `local` line, one between the steps of a
  function (gather, check, act, report), one around each `if` block that is not the function's
  only statement. A file with more than a handful of functions groups them under banners,
  `# --- <group> ---` padded to 80 columns, in the order a reader needs them: helpers first,
  commands after, `main` last.

  ```bash
  # before, bazzite-mx-ntfsplus-setup: the checks of cmd_enable ran on as one block
  # after
      opt_in_written_by_this_run=0
      write_opt_in

      # The mask must work through the kernel's own route before anything else:
      # at boot the fstab units mount by type and the kernel asks for fs-ntfs.
      if ! ntfs_alias_resolves; then
  ```

- **A line stops at 100 columns.** A long command breaks after `\` with one argument per line;
  a long pattern or message goes into a variable named for what it holds. The one exception is
  the description comment above a `.just` recipe, which `just --list` prints whole from that
  single line ([`gotchas.md`](gotchas.md) § A recipe's description is the LAST comment line
  above it).

  ```bash
  # before, bazzite-mx-ntfsplus-setup (109 columns)
  sed -E 's/^([^#[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)ntfs3([[:space:]])/\1ntfs\2/' "$1" > "$2"
  # after, host.sh
  local fields='[[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+'
  local row="^(${fields})${from}([[:space:]]|\$)" typed="^(${fields}${to})"
  …
  sed -E "${edits[@]}" "$input" > "$output"
  ```

- **A name says what the function does or what the variable holds.** No private vocabulary:
  `withdraw` is `roll_back_enable`, `need_root` is `require_root`, `f` is `host_file`, `t` and
  `fn` are `mount_point` and `rewrite`. `die` is named by its effect: `fail_build` in
  `lib/log.sh` (prints `FAIL:`, the build stops), `exit_with_error` in the host helpers (prints
  `ERROR:`, the command stops) and in the CI scripts (`.github/scripts/lib.sh`, prints
  `<script>: …`, the script stops), where `print_error` prints the same line and returns 1 for
  a function a caller runs under `if`. A function a caller runs under `if` is named as the
  question its status answers: `ntfs_alias_resolves`, `has_recipe`.

  ```bash
  # before, bazzite-mx-ntfsplus-setup
  alias_resolves || withdraw "$NTFSPLUS_OPTIN does not mask the image's blacklist"
  # after
  if ! ntfs_alias_resolves; then
      reason="$NTFSPLUS_OPTIN does not mask the image's blacklist (modprobe -c | grep ntfs)"
      roll_back_enable "$reason"
  fi
  ```

- **Every script opens with a header**: what it does in one or two sentences; `Usage:` with
  each argument and option on its own line; the exit status; what it writes, files and the
  output lines a test or a recipe reads. A library says who sources it and what it expects.

  ```bash
  # before, bazzite-mx-ntfsplus-setup
  #   status | enable | disable | --self-test
  # after
  # Usage: bazzite-mx-ntfsplus-setup [status | enable | disable | --self-test]
  #   status       module, opt-in, driver, fstab rows by type, mounted volumes
  #                (the default; no root needed)
  #   enable       write the opt-in, prove the driver on a loop image, rewrite
  #                the ntfs3 rows of fstab to ntfs without force, prealloc and
  #                delalloc, give every ntfs row without an errors= option
  #                errors=remount-ro, remount them (root)
  # …
  # Exit status: 0 done; 1 refused or failed, the reason on stderr as `ERROR: …`
  ```

- **A comment says what the code cannot.** The contract of a function when its name does not
  carry it (empty when…, status 0 when…), or the reason for a choice the reader would otherwise
  question. A comment that restates the name or the next line is deleted; a function whose name
  and arguments say it all has none. The history behind a choice (dates, versions,
  measurements, the bug that forced it) lives in `docs/gotchas.md` and the comment points at
  its heading.

  ```bash
  # before, bazzite-mx-ntfsplus-setup (eight lines, two measurements, a kmod version)
  # … `-n -v` prints nothing for a loaded module, so it read a working
  # opt-in as a failed mask (measured 2026-09-06, kmod 34.2 on 7.2.1-ogc4.1, docs/gotchas.md).
  # after
  # Status 0 when the kernel's own route, request_module("fs-ntfs"), would load
  # the driver, loaded now or not. The config is captured before the grep and
  # the dry run is --show-depends: docs/gotchas.md § `modprobe -n -v` is silent
  # for a loaded module; `--show-depends` is not.
  ```

- **A function stays short**, about 25 statements as the guide (blank and comment lines do not
  count): a function that does two things is two functions, and a step sequence reads as a list
  of calls. A library is written to share functions between scripts, never to make one file
  shorter: a long script stays one file, grouped under banners.

  ```bash
  # before, bazzite-mx-ntfsplus-setup: one self_test of 105 lines
  # after: self_test calls seven checks named for what they prove
  self_test_fstab_rewrites "$dir"
  self_test_install_fstab_refuses "$dir"
  self_test_remount_unescapes_mount_point "$dir"
  self_test_remount_names_the_refused_option "$dir"
  self_test_status_on_fixture "$dir"
  self_test_status_refuses_an_unreadable_mount_table "$dir"
  self_test_alias_resolves "$dir"
  ```

- **Output to the user is a complete sentence**: what happened, and for a failure what to do
  next. The prefixes a contract reads (`OK:`, `FAIL:`, `ERROR:`, `self-test ok`) stay.

  ```bash
  # before, bazzite-mx-migrate
  abort "step 5 not confirmed; the pending deployment keeps the changes made so far"
  # after, describe_what_the_run_changed and abort_declined_step
  next="reboot into it, or rpm-ostree cleanup -p, then apply again"
  …
  echo "what the run changed stands ($changed): $next"
  …
  abort "step $step not confirmed; $(describe_what_the_run_changed)"
  ```

A rewrite for form proves behaviour unchanged: the same arguments, the same exit status, the
same messages where a test or a doc cites them, every self-test green before and after, every
known-bad still red after it. The rules above add to the earlier bullets of this section and to
§ Positive control; they replace none.

## Build scripts

- One script per feature, `NN-<feature>.sh` under `build_files/`, sourcing `lib/env.sh` first.
  `build.sh` runs them in version order and stops at the first failure.
- Third-party packages come from a `.repo` vendored under `system_files/etc/yum.repos.d/` with
  every section `enabled=0`, installed with `install_from_repo <section> <pkg>...`, which
  enables the section for one dnf5 transaction. A COPR the base already ships disabled
  (`ublue-os/packages`) goes through the same `install_from_repo`, with its
  `copr:copr.fedorainfracloud.org:<owner>:<project>` id, as bazzite-dx does; the base's file is
  never touched.
- The gate `90-validate-repos.sh` runs after the installs and refuses a vendored file that is
  absent, differs from the vendored copy or carries `enabled=1`; a base repository file the
  build modified; any other added file left enabled; and an enabled set, as `dnf5 repolist`
  reports it, that differs from the base's. It reads the snapshots `00-prep.sh` recorded, so a
  file under a name nobody listed is caught too.
- The enablement lives in the `.repo` file, never in `dnf5 config-manager setopt`. `setopt`
  writes to an override file under `/etc/dnf/repos.override.d/` and leaves the repository file
  untouched (`man dnf5-config-manager`), so the state would sit in a file the gate's byte
  comparison never reads; its `dnf5 repolist` comparison is what fails the build on it.
  1Password forces the rule: its `%post` rewrites the vendored file with `enabled=1`, the build
  puts the vendored copy back, and the gate proves it.
- Nothing is pinned to a release for vendor RPMs and GitHub releases: the build resolves the
  latest, and a pin enters only against an observed problem, with the observation cited. Two
  exceptions. The base image is pinned to the digest CI resolved (`resolve-base.sh`), so the
  three flavours build against a known base; the out-of-tree kernel modules are pinned to a
  full commit, so a rebuild against a new base kernel cannot also change the module's source.
  pahole is neither latest nor pinned: the kmod-builder stage builds it from the tag the
  kernel's `CONFIG_PAHOLE_VERSION` names, so it moves with the base kernel.
- A vendor's signing key is pinned on purpose: the armored key ships under
  `system_files/etc/pki/rpm-gpg/`, the `.repo` reads it with `gpgkey=file://`, and the feature
  script calls `assert_key_fingerprint` before the install. The fingerprint is pinned once in
  the `KEY_FPR` table of `lib/gpg.sh`, with the URL each key was read from, so a rotation is a
  reviewable diff and never a download at build time. The one exception is the base's own
  `ublue-os/packages` COPR file, used as the base ships it, its key read over https as
  bazzite-dx reads it.
- A package that unpacks under `/opt` needs `mkdir -p /var/opt` before its install: `/opt` is a
  symlink to `var/opt` and the directory does not exist in a build. Nothing else is needed,
  because `80-fix-opt.sh` moves every `/var/opt/<name>` to `/usr/lib/opt/<name>` and writes one
  tmpfiles `L+` line per name to recreate the link on the host. Paths baked into the
  application keep their `/opt/...` form, so its smoke test checks them with `readlink` and not
  with `-x`: the link dangles in the build.
- An out-of-tree kernel module is a `build_files/kmods/<name>/source.env`, built by the
  kmod-builder stage against the base's own `kernel-devel`. It carries `URL`, the full
  `COMMIT`, `KO_NAME`, `KO_BUILD_PATH`, `KO_VERSION`, and `KO_BUILD_ARGS` when kbuild needs a
  config symbol forced on the make line. The builder proves the checkout is the pinned commit.
  Then `assert_module` requires a readable module stamped for the image's kernel and, when
  `KO_VERSION` is set, that `MODULE_VERSION`. The modules are unsigned: when modprobe refuses
  one, the helper's `ERROR:` line carries modprobe's own reason and names Secure Boot as the
  cause of a rejected key.
- A package `%post` runs in the build, not on the host. Read it with `rpm -qp --scripts` before
  the package enters a script, and handle every effect that belongs to a host explicitly. A
  `groupadd` in a `%post` lands in `/etc/group`; `95-clean-stage.sh` relocates the accounts to
  `/usr/lib/passwd` and `/usr/lib/group`, where NSS reads them, so a host's `/etc` merge cannot
  drop them. Membership for humans is a boot hook's job.
- Writes to files the base image ships end on a fresh inode (`mv`, `install`, `sed -i`,
  `rsync`) where it costs nothing. What a runner change would reopen is in
  [`gotchas.md`](gotchas.md) § Torn writeback on a 6.17-azure runner kernel.

## ujust recipes

- A recipe that replaces one of Bazzite's ships in a file with the same name under
  `system_files/usr/share/ublue-os/just/`. The base justfile imports the path, so our file
  takes the base file's place and nothing else changes. It only works when the base file holds
  exactly the recipes we replace, and `70-justfile.sh` refuses the build when the base's recipe
  set, recorded by `00-prep.sh` before the copy, differs from ours.
- When the base file holds other recipes too, the recipe goes in the `OVERRIDES` list of
  `70-justfile.sh`. That cuts the recipe out of the base file, proves the removal changed
  nothing else and proves our file defines the name. `install-jetbrains-toolbox` is the one
  entry.
- Our own recipes live in `95-bazzite-mx.just`, imported last into the master justfile on a
  fresh inode. With `allow-duplicate-recipes` the earlier import wins
  ([`gotchas.md`](gotchas.md) § `just`: the earlier import wins on a duplicate recipe name), so
  `70-justfile.sh` fails the build on any name defined in two files and checks that the master
  justfile exposes every name of ours and still parses.
- A recipe that needs more than a few lines of logic calls a helper under
  `system_files/usr/libexec/bazzite-mx-<x>`, the recipe staying a thin front: the `help` text,
  the not-as-root check, `sudo` where root is needed, the call. A recipe that prints a line
  after the call prints it only when the call succeeded, so a failed helper is the recipe's own
  status (`tests/70` runs those recipes as `nobody` against a stub). The helper takes fixture
  knobs (`ROOT=`, `FIXTURE=`, `DMI_VENDOR_FILE=`, a `file://` feed) so the smoke test runs the
  real code, positive and known-bad, inside the build.
- Recipes are `just --unstable --fmt --check` clean and start with
  `source /usr/lib/ujust/ujust.sh`, which brings the colours and `Choose`. The `help` action
  comes before the not-as-root check so the smoke test can run the recipe body in the build.
  Two guards: the `lint` job checks every tracked `.just` file with Fedora 44's `just`, the
  release the image ships, and `70-justfile.sh` checks ours again inside the build.
- What the image already does, a unit enabled or a package installed or a module option, is not
  redone by a recipe: the recipe reports it under `status` and does only what needs the host,
  an opt-in module or a per-user choice.

## Boot hooks

Scripts under `system_files/usr/share/ublue-os/system-setup.hooks.d/` run as root at every boot
through `ublue-system-setup.service`, before user sessions. The dispatcher is a loop of
`bash $script` and reads no exit status, which sets three rules:

- a hook converges on every boot, checking first and changing only what differs. It does not
  stamp a version with libsetup's `version-script`, which records the run before the body
  executes, so it never repeats a failed run nor reaches a user created later;
- a hook that cannot do its job prints one `ERROR:` line to stderr and exits 1, because the
  journal line is the only signal it can leave;
- a hook takes a fixture prefix (`usermod --prefix`, files under a temporary tree) so its smoke
  test exercises the real script, positive and known-bad, without touching the image.

User hooks (`user-setup.hooks.d/`, `ublue-user-setup.service`) follow the same three rules
through the same kind of dispatcher. Their check must be cheap enough for every login, so it
reads a file and never spawns the application. Their fixture is `HOME` plus a stub binary first
in `PATH`.

## Tests

- `tests/NN-<feature>.sh` with the same stem as the build script. `tests/run.sh` refuses a
  build script without a test and a test without a build script, so a feature cannot land
  without its test.
- `tests/helpers/<name>.sh` for the helper `system_files/usr/libexec/bazzite-mx-<name>`, when
  its cases need fixtures rather than the helper's own `--self-test`. The runner runs both
  classes and counts them in one `tests: N passed` line, and its guard holds one way here: a
  test must name an installed helper, a helper need not have a test.
- A test prints `OK: <what>` or `FAIL: <what>` per check and exits 0. The runner fails the
  build on any `FAIL:` line and on a non-zero exit. It also fails on a test that printed no
  `OK:` line, which is what catches a test whose checks never ran.
- Tests run offline (`--network=none`) on the tree `95-clean-stage.sh` left, with tmpfs on
  `/run`, `/tmp`, `/var/log` and `/var/cache`: they see what the image ships, not what the
  build had, and a test that touches dnf5 cannot leave a log behind for `bootc container lint`.
- A check several tests make is a function of `tests/lib.sh`, sourced first: `check_pkg`,
  `check_unit_state`, `check_rpm_key`, `check_key_fingerprint`, `check_repo_reads_key`,
  `check_self_test`, `check_desktop_file`, `check_recipe_help`, `check_flatpak_deny`,
  `check_portal_group_removed`, and `on_one_line` for a probe's output quoted in a `FAIL:`
  line. A check made once stays in its test.

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
reader expects. A count is safe or not by where its subject comes from, never by being a count:
`tests/22-virtualization.sh` walks the `/var` directories rpm lists for the libvirt and swtpm
packages, with the mode, user and group of each, and catches a missing one, while a check that
counts or walks a list read out of the very thing it tests shrinks with the defect and stays
green: a required number of `OK:` lines lets a check stop reporting unnoticed, and a group list
read from the hook's own summary shrinks with the hook. Name what a count stands for. The same
reading condemns a tolerant `else` that prints `OK:` on the failure it meant to excuse:
`check_desktop_file` passed a file `desktop-file-validate` calls an error, not a warning.
Neither shape holds a counter, so neither is found by grepping for one.

Where each one runs:

| Self-test                                                 | Where it runs                                                                                                                                             |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/scripts/*.sh`                                    | `lint` job, `build.yml`                                                                                                                                   |
| `check-form.sh`                                           | `lint` job, `build.yml`, which then runs the check itself over the whole shell catalogue; `.claude/hooks/lint-edit.sh` runs it on every edited shell file |
| `kmods/build-kmods.sh`                                    | kmod-builder stage, before the real build                                                                                                                 |
| `70-justfile.sh`, `80-fix-opt.sh`, `90-validate-repos.sh` | the test RUN, called by their paired test                                                                                                                 |
| `bazzite-mx-ntfsplus-setup`, `bazzite-mx-migrate`         | the test RUN, called by `tests/55-ntfsplus.sh` and `tests/70-justfile.sh`; their cases live here, so neither has a file under `tests/helpers/`            |
| `tests/run.sh`                                            | `lint` job, `build.yml`, after the CI scripts                                                                                                             |

## CI

- Names follow `ublue-os/bazzite`'s workflows (`bazzite/.github/workflows/build.yml`: jobs
  `Version`, `Make`, `Generate Release`; steps `Build Image`, `Apply Labels`, `Push to GHCR`,
  `Install Cosign`). Workflow `name:` Title Case. A job name is the phase in one Title Case
  word: `Lint`, `Build`, `Version`, `Gate`, `Release`, `Prune`, `Promote`, `Sign`, `Trigger`,
  `Compare`; the matrix job of the reusable build is named by its flavour, so a run reads
  `Build / bazzite-nvidia`. A step name is Title Case, verb + object, no article, a tool in its
  own casing: `Checkout`, `Resolve Base`, `Build Image`, `Install Cosign`, `Push to GHCR`,
  `Run shfmt, yamllint and just`. Env vars `SCREAMING_SNAKE_CASE`; outputs `snake_case`, one
  key name across workflows.
- Concurrency groups are literal `bazzite-mx-<phase>[-<key>]` and never built from
  `${{ github.workflow }}`. A called workflow reports the caller's name there, so a group built
  from it would put caller and callee in the same group and the callee would wait for the run
  that started it.
- Every third-party `uses:` is pinned to a commit SHA with the version in a trailing comment
  ([`workflow.md`](workflow.md) § Keeping the pins fresh).
- `ubuntu-26.04` for jobs that need podman or skopeo; `ubuntu-slim` only for `gh`, `jq`, `curl`
  and `python3` work, since it has no container engine and an older
  shellcheck. `ubuntu-26.04` is also the runner whose kernel keeps in-place writeback intact,
  so a runner change is a change to that measurement ([`gotchas.md`](gotchas.md) § Torn
  writeback on a 6.17-azure runner kernel).
- `runner.temp` is not available in a job-level `env:`; steps read `$RUNNER_TEMP`.
- A dispatch on a branch runs that branch's copy of the file,
  `gh workflow run build.yml --ref <branch>`, and `-f rechunk=true` runs the main profile; the
  file has to be on the default branch too ([`gotchas.md`](gotchas.md) § A workflow that is not
  on the default branch has no runs endpoint).
- Two profiles, one reusable workflow: what `main` and a release run add to the sandbox is an
  input (`rechunk`, then `publish`), never a second copy of the steps.
- Every check CI runs on an image is a script under `.github/scripts/` with a `--self-test` the
  `lint` job runs; the workflow calls the script and does not restate the checks.
- One labels file per build (`image-labels.sh`), passed to `podman build` and again to the
  chunked compose: a composed image inherits no config, and a `podman build` without labels
  keeps the base's ([`gotchas.md`](gotchas.md) § `podman build` keeps the base's labels).
- Values an expression computes reach a step through `env:`, never inline in `run:`: an input
  or a label carrying a quote would break the script (GitHub docs, "Security hardening for
  GitHub Actions").
- A secret proves itself before it is needed. The main profile derives the public half of
  `SIGNING_SECRET` and requires it to be `cosign.pub` byte for byte, so a rotated or mispasted
  key fails on a push to `main`, not in the release run.
- Publishing is an input, never an event: every step that reaches GHCR sits behind
  `if: inputs.publish`, `publish` is passed by `release.yml` alone, and `release.yml` has one
  trigger. A job's permissions cannot follow an input, so the callee declares the set its
  publishing steps need and every caller grants it (GitHub docs, reusing workflows: permissions
  can only be maintained or reduced through the chain).
- An image travels between jobs by digest, never by tag: the build job writes
  `release-<flavour>.env`, uploads it as an artifact, and the gate inspects
  `docker://<image>@<digest>`. A `:staging` tag left by an earlier run of the same day would
  carry the same version and the gate could not tell the two apart.
- A verifier is shown failing before its first pass. The gate runs `cosign verify --key` and
  `gh attestation verify --repo` on the flavour's own base and requires both to reject it. Only
  a signature-class rejection counts, matched on cosign's own message: a network error also
  exits non-zero and would pass a control that simply saw no signature.
- A release tag is written once: the gate refuses to copy onto a `:<tag>` that already points
  at another digest, and treats the same digest as a no-op. `:stable` and `:staging` are the
  tags that move: `:staging` at every release run's push, `:stable` only through the gate or
  `promote.yml`.
- Binaries the workflows install take their version from an input or an env var
  (`cosign-release`, `syft-version`, `ORAS_VERSION`), never "latest", and `refresh-pins.sh`
  reads exactly those three names.
- Retries are loops in the step or the tool's own flag (`skopeo inspect --retry-times 3`),
  never an action: one pin fewer for a `for` loop.
- A cron's minute sits off `:00`, because the `schedule` event is delayed at the start of every
  hour (GitHub docs). A scheduled workflow never publishes on its own: it dispatches
  `release.yml`, which keeps its single trigger and puts the reason in its run name. A
  scheduled dispatch of `release.yml` is gated on the repository variable `PROMOTE_STABLE`, in
  the script where there is one and as a job `if:` where there is none, so a skipped run shows
  why.
- A GHCR package is named in full in `clean.yml`, never by pattern ([`gotchas.md`](gotchas.md)
  § `ghcr-cleanup-action` matches `packages` by pattern only with `expand-packages`), and a
  pattern would also reach any other package of the owner.

## Prose

A claim in a doc, a comment or a script's output names its source (a file, a manual page, a
URL) or the `docs/gotchas.md` entry that records the measurement with its date; a date or a
"measured" anywhere else is deleted. No linter reads prose: it is checked by hand at review.

## Commits

`.github/scripts/check-commits.sh` checks every message over the whole history of the pushed
ref in the `lint` job:

- the subject is `<type>(<scope>): <what>` (Conventional Commits; `feat`, `fix`, `docs`,
  `chore`, `refactor`, `ci`, `test`, `build`), at most 72 columns, no trailing period;
- a blank line before an optional body;
- no trailer (`Signed-off-by`, `Co-authored-by`, a session link): the author is the metadata.

A body is natural lines, one per point, never hard-wrapped; no linter reads it, review does.
