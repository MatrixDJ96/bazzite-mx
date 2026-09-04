# Bringing a host onto this image

A Bazzite host that has never run one of these images reaches the signed origin through `ujust
migrate`. A host already on one of them is re-checked with `ujust verify-host`, which names
every defect and the recipe that fixes it. Both recipes ship in the image; their root halves
are `/usr/libexec/bazzite-mx-migrate` and `/usr/libexec/bazzite-mx-verify-host`.

## What a checked host looks like

`ujust verify-host` prints one `OK:`, `FAIL:`, `SKIP:` or `INFO:` line per check and exits 1 on
any `FAIL:`. It runs the checks as root through `sudo`, `bootc status` needing it. Every check
passes when:

- `bootc status` reports the booted deployment compatible. bootc marks the origin incompatible
  on any rpm-ostree group. No layered package, no local package, no base removal, no requested
  module and no local initramfs regeneration may be left. A request the image already satisfies
  is no longer layered, but stays in the origin and still counts ([`gotchas.md`](gotchas.md));
  - the origin is `ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:stable`, the image
  being the booted image's own name. A dated tag never receives an update, so the tag has to be
  `stable`; - `/etc/containers/policy.json` carries the `ghcr.io/matrixdj96` scope as
  `sigstoreSigned`, the key file it names exists, `default` is still `reject`, and
  `/etc/containers/registries.d/matrixdj96.yaml` sets `use-sigstore-attachments: true`; - on a
  Micro-Star system `msi_ec` and `acpi_ec` are loaded, and no modules-load file other than the
  one `ujust setup-msi` writes names them; - an NVIDIA GPU on the bus means an NVIDIA flavour
  with the `nvidia` module loaded, and no GPU means `bazzite-mx`; - every NTFS row of
  `/etc/fstab` uses the driver this host chose and is mounted with it. That is `ntfs3`, or
  `ntfs` on a host that ran `ujust setup-ntfsplus enable`. Rows on `ntfs-3g` are the explicit
  FUSE route, and are reported rather than failed; - no ntfsplus file is left under
  `/etc/modprobe.d` or `/etc/modules-load.d`, the opt-in file `setup-ntfsplus` writes not being
  residue, and no kernel argument mentions ntfsplus.

## A Bazzite host that has never run this image

### The first rebase goes through the unsigned transport

A signed pull is checked against the policy of the deployment that runs it. Stock Bazzite
carries no `ghcr.io/matrixdj96` scope, so the first image has to be reached once unsigned;
`ujust migrate` refuses to go further until then and prints the command itself:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/matrixdj96/<image>:stable
systemctl reboot
```

`<image>` is `bazzite-mx`, `bazzite-mx-nvidia-open` or `bazzite-mx-nvidia`. The rebase keeps
whatever the host had layered and its initramfs setting; the next step removes them, on a
deployment whose policy knows the scope.

One transaction can fail here. A package installed from a file that the new image also ships is
reinstalled verbatim on the new base, and rpm-ostree refuses the depsolve. The same package
layered from a repository is re-resolved instead and survives as an inactive request
([`gotchas.md`](gotchas.md)). Drop the local request in the same transaction:

```bash
rpm-ostree status --json | jq '.deployments[0]["requested-local-packages"]'
sudo rpm-ostree upgrade --uninstall=<name>-<version>-<release>.<arch>
```

### The recipe

```bash
ujust migrate                 # plan: read-only, prints what apply would do
ujust migrate apply           # every step asks first; TAG defaults to stable
ujust migrate apply <tag>     # a dated release tag instead of the moving alias
ujust migrate help
```

Run it from a terminal: confirmations go through `ugum confirm`, and without a terminal nothing
is confirmed and the run stops.

`plan` and `apply` detect the same things and stop at the same two gates, after the plan has
been printed:

- a pending deployment, staged by `uupd` or by an earlier run. rpm-ostree would queue the
  changes on it and the plan would not describe what boots next. Reboot into it, or `rpm-ostree
  cleanup -p`, then run again;
- no `ghcr.io/matrixdj96` scope in the booted policy. The abort prints the unsigned rebase
  above, unless `ostree admin config-diff` also shows a local `/etc/containers/policy.json` or
  `registries.d/`. In that case it names the local copy and points at the restore `apply`
  offers from `/usr/etc`, which is step 0 below. The image's copy never reaches `/etc` through
  the three-way merge, so the scope would not arrive on its own.

Then, in the order the helper prints them, each behind its own confirmation and skipped when
already done. There is no step 1: it is the scope precondition.

| Step | What it does | Why |
|---|---|---|
| 0 | restores `policy.json` and `registries.d` from `/usr/etc`, backup kept | only when a local copy shadows the image's; otherwise the signing scope never arrives |
| 2 | backs up the status JSON and `fstab`, runs `ostree admin pin booted`, stops `uupd.timer` | the booted deployment survives collection until you unpin it, and no update lands mid-run |
| 3 | `rpm-ostree uninstall --all`, its dry run shown first | layered, local and inactive requests alike: bootc counts all of them |
| 4 | `rpm-ostree initramfs --disable` | the image's initramfs boots; without this bootc stays incompatible |
| 5 | `rpm-ostree rebase ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:<tag>` | same image, signed transport; rpm-ostree keeps every removal visible |
| 6 | rewrites the type column of `ntfs` rows to `ntfs3`, then reloads and verifies `fstab` | the in-kernel driver is the default; skipped on a host that opted into NTFSPLUS |
| 6b | moves ntfsplus files and foreign modules-load files to the backup, deletes ntfsplus kernel arguments | leftovers of a host that loaded those modules on its own |
| 7 | prints what stays with each user, then `rpm-ostree status` | nothing is uninstalled from Flatpak |

Step 2 writes its backups under `/var/tmp/bazzite-mx-migrate/<timestamp>/` and restarts
`uupd.timer` on every exit path. Step 6 proves `ntfs3` loadable before it writes, leaves the
options untouched, shows the diff and checks that no `ntfs` row is left. It then runs
`systemctl daemon-reload` and `findmnt --verify --fstab`. If `ntfs3` is not loadable it aborts
rather than leave the volumes unmounted after the reboot, and if `findmnt --verify` fails it
stops and names the backup. Declining step 3, 4 or 5 aborts the run and leaves the pending
deployment with whatever ran before it. Declining step 6 or 6b only skips it.

The three rpm-ostree steps land in one pending deployment. What step 7 prints:

```bash
# per user, BEFORE the first start of the Firefox RPM (its profile lives in ~/.mozilla,
# the Flatpak's in ~/.var/app; nothing migrates it otherwise)
[ -d ~/.mozilla ] || cp -a ~/.var/app/org.mozilla.firefox/.mozilla ~/
flatpak uninstall org.mozilla.firefox          # when you are done with it
# Teams (its config is in ~/.var/app, not in ~/.config/teams-for-linux)
flatpak install flathub com.github.IsmaelMartinez.teams_for_linux
systemctl reboot
```

After the reboot, run `ujust verify-host`. Rollback at any point before the unpin: `rpm-ostree
rollback && systemctl reboot`. Unpin the old deployment once the new one has been used for a
day: `sudo ostree admin pin -u <index>`, the index being the one `rpm-ostree status` prints.

## A host already on one of these images

`ujust verify-host` is the whole procedure. Every `FAIL:` line names its own fix; this is the
map from the line to the recipe.

| FAIL line | What it means | Fix |
|---|---|---|
| `bootc status reports the booted deployment incompatible` | an rpm-ostree group is left in the origin | `ujust migrate` |
| `origin is not ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:<tag>` | the origin is on the unsigned transport or on another registry | `ujust migrate apply` |
| `origin image <a> but the booted image calls itself <b>` | the origin names another flavour than the one booted | rebase to the flavour the hardware needs |
| `origin tag is <tag>, not stable` | a dated tag never updates | `ujust migrate apply stable` |
| `rpm-ostree mutations in the origin: <list>` | layered, local or inactive package requests | `ujust migrate`, which runs `rpm-ostree uninstall --all` |
| `initramfs is regenerated locally` | a local initramfs keeps bootc incompatible | `rpm-ostree initramfs --disable`, or `ujust migrate` |
| `policy.json has no sigstoreSigned scope for ...` | the booted image predates the signing trust, or `/etc` holds a local copy | `ostree admin config-diff`, then `ujust migrate apply` (step 0) |
| `policy.json: ... scope names key '<path>', which is missing` | the key the scope points at is absent | restore `/etc` from the image, as in step 0 |
| `policy.json: default is ...` | a local edit replaced the image's `reject` | same |
| `<registries.d file> missing or without use-sigstore-attachments` | the sigstore attachments are not enabled | same |
| `MSI host: msi_ec not loaded` / `acpi_ec not loaded` | the MSI modules are not up | `ujust setup-msi enable`; they are unsigned, so Secure Boot has to be off |
| `MSI residue: <files>` | a modules-load file of the host's own names those modules | `ujust migrate` offers the removal |
| `NVIDIA GPU present but the image is ...` | wrong flavour for the hardware | rebase to `bazzite-mx-nvidia-open`, or `bazzite-mx-nvidia` for the closed driver |
| `no NVIDIA GPU on the bus but the image is ...` | wrong flavour for the hardware | rebase to `bazzite-mx` |
| `nvidia module not loaded` | the driver did not come up | `nvidia-smi`, `dmesg` |
| `fstab: <target> uses type ntfs without the ntfsplus opt-in` | an `ntfs` row on a host that did not opt in | `ujust setup-ntfsplus enable`, or `ujust migrate` for `ntfs3` |
| `fstab: <target> uses type ntfs3 while the ntfsplus opt-in is active` | a row the opt-in did not reach | `ujust setup-ntfsplus enable` rewrites it |
| `fstab: <target> uses type <type>, not <want>` | an NTFS row on neither driver this host expects | `ujust migrate` rewrites it |
| `fstab: <target> is <type> but not mounted` | the volume did not mount, a dirty NTFS volume being the usual reason | `journalctl -b`, then a full shutdown on Windows or `ntfsfix -d` |
| `fstab: <target> is <type> in fstab but mounted as <other>` | something else mounted it first | unmount and mount it again, or reboot |
| `ntfsplus residue: <files>` / `kernel arguments mention ntfsplus: ...` | leftovers of a host that loaded the driver on its own | `ujust migrate` offers the removal |

Three lines are not failures. `INFO: the Firefox Flatpak is still installed next to the RPM`
asks for the profile copy above. `INFO: the ntfs driver is not registered yet` is normal under
the NTFSPLUS opt-in, the kernel loading the driver at the first mount of type `ntfs`. `INFO:
fstab rows on ntfs-3g` reports volumes deliberately left on FUSE. Two more lines are skips:
`not an MSI host` and `no NTFS entry in fstab`.

## Notes per class of host

| Class | Flavour | What is specific |
|---|---|---|
| AMD or Intel desktop | `bazzite-mx` | nothing beyond the recipe; the MSI check skips and no NVIDIA module is expected |
| NVIDIA desktop | `bazzite-mx-nvidia-open`, or `bazzite-mx-nvidia` for the closed driver | `verify-host` requires the `nvidia` module loaded |
| MSI laptop | the flavour the GPU needs | after the reboot, `ujust setup-msi enable`; the modules are unsigned, so check `bootctl status` first |

A host with NTFS volumes is the one case worth planning: run `ujust migrate` in its read-only
form first and read the `fstab` rows it lists. Bulk deletions on NTFS are a reason to try
`ujust setup-ntfsplus enable` on that host ([`divergences.md`](divergences.md)), whose
`disable` reverts.
