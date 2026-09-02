# Divergences from Bazzite

What this image changes over its base, one entry per feature. A change enters only when
upstream does not cover it, it needs the image layer, a host that runs the image uses it and it
ships a smoke test. Each entry says what the image does, why, where the claim comes from and
which files carry it; the guards themselves live in the build script and its test.
[`gotchas.md`](gotchas.md) holds the surprises this project probed, each with its date.

Contents: three flavours · image identity · signing trust · the cleaned stage · CI.

## Three flavours, one recipe

Bazzite's KDE desktop images come one per graphics stack: `bazzite` for AMD and Intel,
`bazzite-nvidia-open` for the open kernel modules and `bazzite-nvidia` for the closed driver.
This image follows all three, and the base image and the name it maps to are the only
differences between them. A host reaches the changes below only through an image built on its
own stack's base. The recipe therefore stays one file with `BASE_IMAGE` and `IMAGE_NAME` as its
variables, and `resolve-base.sh` maps a flavour to a base image and pins it to a digest. The
closed-driver base carries a kernel of its own. Source: `bazzite`'s
`.github/workflows/build.yml`, the image matrix of the `push-ghcr` job, where the closed-driver
images, `bazzite-nvidia` and its GNOME twin, take the `ogc-lts` kernel.

Every enumeration of the three images is literal: `FLAVOURS` in `.github/scripts/lib.sh` and
the build matrix name them one by one; `resolve-base.sh --digests` loops over `FLAVOURS`.

Files: `Containerfile`, `.github/scripts/resolve-base.sh`, `.github/scripts/lib.sh`.

## Image identity and the update ref

A layer built on Bazzite keeps Bazzite's identity until something rewrites it, and the identity
is not cosmetic: `image-ref` in `/usr/share/ublue-os/image-info.json` is what Bazzite's shell
greeting (`/usr/share/ublue-os/motd/env.sh`) prints as the host's image, so an unrewritten file
calls the host `ghcr.io/ublue-os/bazzite`. Bazzite's rollback helper reads `image-name` too:
`brh rebase <tag>` builds `ghcr.io/ublue-os/<image-name>:<tag>`, a repository that does not
exist for this image. The image a host pulls from at `bootc upgrade` is the deployment's
origin, which `bootc status` prints. The build writes `image-name`, `image-vendor`,
`image-ref`, `version`, `version-pretty` and `base-version` there, `base-version` keeping the
base's own `version`; `VARIANT_ID` and `IMAGE_ID` in `/usr/lib/os-release`, the identity
os-release(5) gives an image; and `Variant` and `Website` in `/etc/xdg/kcm-about-distrorc`, the
KDE About page, the variant naming the flavour. Sources: os-release(5), bootc's upgrade
contract (https://bootc-dev.github.io/bootc/), Bazzite's own `image-info.json` and
`/usr/bin/bazzite-rollback-helper`.

Files: `build_files/10-image-info.sh` and its test.

## Signing trust for our own images

Bazzite verifies `ghcr.io/ublue-os/*` against its own key and says nothing about downstream
images. A host that follows `ghcr.io/matrixdj96/*` over `ostree-image-signed:docker://` needs
the scope, the key and the sigstore attachment stanza inside the image it boots, or the first
signed pull has nothing to verify against. The build installs `cosign.pub` at
`/etc/pki/containers/matrixdj96.pub` and writes one `sigstoreSigned` scope with
`signedIdentity: matchRepository`, which leaves the tag free: the host follows `:stable` while
the signature sits on the digest. Sources: containers-policy.json(5),
containers-registries.d(5).

Files: `build_files/11-image-signing.sh` and its test, `cosign.pub`,
`system_files/etc/containers/registries.d/matrixdj96.yaml`.

## The cleaned stage

The last build script puts back what the build's own transactions changed under `/etc` and
`/usr`, so a host boots an image that carries the features and nothing of the machine that
produced them. Three effects reach a host and belong here.

The accounts created in the build are moved out of `/etc/passwd` and `/etc/group` into
`/usr/lib/passwd` and `/usr/lib/group`, and the `-` backups removed. Their `/etc/shadow` lines
are left where they are: the base ships that file with dozens of entries whose accounts live in
`/usr/lib` already, so the few this stage adds change nothing a host reads. NSS resolves them
through `altfiles`, and `/etc` goes back to `root` and `wheel` alone. Without the move
`bootc container lint --fatal-warnings` refuses the image, its sysusers check reading an
account line in `/etc` as machine state.

The dnf5 system state under `/usr/lib/sysimage/libdnf5/` is emptied. It is the record of the
build's own transactions (install reasons, repository attribution, the transaction history),
and it would ship to hosts as the history of a machine that no longer exists; rpm-ostree reads
the rpmdb under `/usr/share/rpm`, which stays and is the base's own by hardlink. A host
therefore has no `dnf history` and no install reason for any package, the base's included.
Source: rpm-ostree's rpmdb location (coreos/rpm-ostree#4554, cited in the script).

The vendored repository files are left as they ship, `enabled=0`, and `dnf.conf` is restored
byte for byte: the build enables a repository per transaction and never leaves one enabled
behind it.

Files: `build_files/95-clean-stage.sh` and its test.

## CI: what differs from the family

How a change ships is [`workflow.md`](workflow.md), and the rule behind each choice is
[`conventions.md`](conventions.md). What follows is the delta against Bazzite, bazzite-dx and
aurora.

**A push never publishes.** Bazzite builds, rechunks, tests and pushes in one job gated on the
event (`bazzite/.github/workflows/build.yml`), where aurora takes `publish` as an input
(`aurora/.github/workflows/reusable-build.yml`). This repository is the only one of the family
whose build waits on a lint of its scripts and workflows; aurora runs zizmor and a just check
as workflows of their own (`aurora/.github/workflows/zizmor.yml`, `validate-just.yml`).

**Fewer actions, more bash.** The family is split on freeing disk: Bazzite and bazzite-dx run
`jlumbroso/free-disk-space` (`bazzite/.github/workflows/build.yml:150`,
`bazzite-dx/.github/workflows/build.yml:67`), Bazzite having dropped
`AdityaGarg8/remove-unwanted-software` in a45a310e and taken `jlumbroso/free-disk-space` in
595c121e; aurora runs `hastd/free-disk-space` v0.1.2
(`aurora/.github/workflows/reusable-build.yml`, step `free-disk-space`), and image-template
still pins `ublue-os/remove-unwanted-software` at `695eb75b`
(`image-template/.github/workflows/build.yml:39`), the commit past the apt step whose released
version fails on this runner ([`gotchas.md`](gotchas.md) § `ublue-os/remove-unwanted-software`
v9 fails on `ubuntu-26.04`). No space-freeing action runs here.

Files: `.github/workflows/` and `.github/scripts/`, one owner per script
([`architecture.md`](architecture.md)).
