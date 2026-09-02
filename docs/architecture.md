# Architecture

How an image is built, what each stage may touch, and where the state of a build lives. How a
build reaches a host is [`workflow.md`](workflow.md); why each feature exists is
[`divergences.md`](divergences.md).

Contents: build flow · `.github/scripts/` · `build_files/` · state of a build ·
gates, in order.

## Build flow

```
Containerfile
  ctx           FROM scratch, COPY build_files                              bound at /ctx, never in the image
  image         FROM ${BASE_IMAGE}
    RUN /ctx/build_files/build.sh                  mounts: /var/cache and /var/log (cache), /run and /tmp (tmpfs)
    RUN /ctx/build_files/tests/run.sh              offline; tmpfs on /run, /tmp, /var/log, /var/cache
    RUN bootc container lint …                                          offline; tmpfs on /run
```

Why `/run` is a tmpfs is on the `RUN` itself in the `Containerfile`.

`BASE_IMAGE` is the one variable between the three flavours, mapped from the flavour by
`resolve-base.sh`. CI and `/preflight` resolve the base to a digest with
`.github/scripts/resolve-base.sh`, which also reads the base's kernel from its `ostree.linux`
label.

## .github/scripts/

Each script owns one artefact and ships a `--self-test`.

| Script                                            | Role                                                                                                                                                                                                                                                 |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib.sh`                                          | coordinates, `exit_with_error`/`print_error`, `emit`, `image_of`, `fail_self_test`; sourced by all but `check-form.sh` and `check-commits.sh`                                                                                                        |
| `resolve-base.sh <flavour> \| --digests`          | the base's digest, version and kernel, and the image name; the three digests keyed by flavour                                                                                                                                                        |
| `check-commits.sh [<rev>]`                        | the commit-message rules (§ Commits of `conventions.md`) over every commit reachable from `<rev>`                                                                                                                                                    |
| `check-form.sh <file>...`                         | the form rules (§ Bash → Form of `conventions.md`): line width, the banned control-flow shapes and the four failure shapes (`\| grep -q`, `\|\| echo` fallback, a pipeline assigned without `\|\| true`, a `$( )` inside `$(( ))`), on logical lines |

## build_files/

| Path                      | Role                                                                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `build.sh`                | runs `NN-<feature>.sh` in version order, one group each, stops at the first failure                                                              |
| `lib/env.sh`              | sourced first: `CTX`, `BUILD_FILES`, `BUILD_TMP`, `BUILD_STATE`, then every library                                                              |
| `lib/log.sh`              | `group`, `endgroup`, `log`, `fail_build`                                                                                                         |
| `lib/repos.sh`            | `install_from_repo`, `enabled_repos`                                                                                                             |
| `00-prep.sh`              | dnf keeps its cache and waits 60 s against COPR and mirror flakes; the base's repositories are recorded                                          |
| `90-validate-repos.sh`    | the repository gate, run after the last install                                                                                                  |
| `95-clean-stage.sh`       | the tree bootc lint expects                                                                                                                      |
| `tests/run.sh`            | the test runner and the pairing guard                                                                                                            |
| `tests/lib.sh`            | the checks the tests share, one `OK:`/`FAIL:` line each                                                                                          |
| `tests/NN-<feature>.sh`   | one smoke test per build script, same stem                                                                                                       |

Numbering, as the tree uses it: `00-09` preparation, `90-99` gates and cleanup. The file name
is the only statement of the order.

## State of a build

| Where                                              | Lifetime                       | Content                                                       |
| -------------------------------------------------- | ------------------------------ | ------------------------------------------------------------- |
| `/tmp/bazzite-mx-build/` (`BUILD_TMP`)             | the build `RUN` (tmpfs)        | backups a later script restores, the GitKraken RPM download   |
| `/usr/lib/bazzite-mx/build-state/` (`BUILD_STATE`) | shipped in the image           | the base's repository snapshots                               |
| `/var/cache`, `/var/log`                           | cache mounts, not in the image | the dnf cache and logs                                        |

## Gates, in order

1. `90-validate-repos.sh` after the last install: the image ships no enabled third-party
   repository, the enabled set read from `dnf5 repolist` itself, and no modified base
   repository.
2. `tests/run.sh`: every feature's smoke test on the cleaned tree, offline.
3. `bootc container lint --fatal-warnings`: the last word, offline.

Every gate is proven on a known-bad input before it counts ([`conventions.md`](conventions.md)
§ Positive control).
