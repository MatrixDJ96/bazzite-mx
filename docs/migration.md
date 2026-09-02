# Bringing a host onto this image

A Bazzite host that has never run one of these images reaches the signed origin through
`ujust migrate`. A host already on one of them is re-checked with `ujust verify-host`, which
names every defect and the recipe that fixes it. Both recipes ship in the image; their root
halves are `/usr/libexec/bazzite-mx-migrate` and `/usr/libexec/bazzite-mx-verify-host`.

Contents: what a checked host looks like · a Bazzite host that has never run this image (the
first rebase, the recipe) · a host already on one of these images · notes per class of host.

## What a checked host looks like

`ujust verify-host` prints one `OK:`, `FAIL:`, `SKIP:` or `INFO:` line per check and exits 1 on
any `FAIL:`. It is run from the user's session and runs the checks as root through `sudo`,
`bootc status` needing it; `sudo ujust verify-host` stops at the recipe's own guard, "Please do
not run this command as root". Every check passes when:

- `bootc status` reports the booted deployment compatible. bootc marks the origin incompatible
  on any rpm-ostree group. No layered package, no local package, no base removal, no requested
  module and no local initramfs regeneration may be left. A request the image already satisfies
  is no longer layered, but stays in the origin and still counts ([`gotchas.md`](gotchas.md) §
  An inactive package request stays in the origin and keeps bootc incompatible);
- the origin is `ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:stable`. A dated tag
  never receives an update, so the tag has to be `stable`;
- `/etc/containers/policy.json` carries the `ghcr.io/matrixdj96` scope as `sigstoreSigned`, the
  key file it names exists, `default` is still `reject` (a reject that covers no container
  pull: `containers-common` leaves the empty `docker` scope on `insecureAcceptAnything`, so
  only the scopes the policy names are verified), and
  `/etc/containers/registries.d/matrixdj96.yaml` sets `use-sigstore-attachments: true`;
- no modules-load file other than the one `ujust setup-msi` writes names `msi_ec` or `acpi_ec`,
  and on a Micro-Star system with the `setup-msi` opt-in both modules are loaded;
- an NVIDIA GPU on the bus means an NVIDIA flavour with the `nvidia` module loaded, and no
  NVIDIA GPU means `bazzite-mx`;
- every NTFS row of `/etc/fstab` uses `ntfs3` and is mounted with it. Rows on `ntfs-3g` are the
  explicit FUSE route, and are reported rather than failed;
- no ntfsplus residue is left under `/etc/modprobe.d` or `/etc/modules-load.d`, and no kernel
  argument mentions ntfsplus;
- every `.repo` file the image adds to the base's under `/etc/yum.repos.d` is the image's copy.
  The three-way merge of `/etc` carries a host's edit over every later copy, so an edited file
  never follows the image again; a deleted one stays deleted, the host's choice;
- `flatpak list` answers for the system installation and the invoking user's. A Firefox Flatpak
  still installed next to the RPM is an `INFO:` line, not a failure.

## A Bazzite host that has never run this image

### The first rebase goes through the unsigned transport

A signed pull is checked against the policy of the deployment that runs it. Stock Bazzite
carries no `ghcr.io/matrixdj96` scope, so the first image has to be reached once unsigned, and
`ujust migrate` exists only once that image is booted. On a booted image without the scope, an
image predating the signing policy, `ujust migrate` refuses to go further and prints the
command itself:

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
([`gotchas.md`](gotchas.md) § A local RPM the new image ships blocks the rebase; a repository
package does not). Rerun the rebase dropping the local request in the same transaction:

```bash
rpm-ostree status --json | jq '.deployments[0]["requested-local-packages"]'
sudo rpm-ostree rebase --uninstall=<name>-<version>-<release>.<arch> \
    ostree-unverified-registry:ghcr.io/matrixdj96/<image>:stable
```

### The recipe

```bash
ujust migrate                 # plan: read-only, prints what apply would do
ujust migrate apply           # every change but step 2 asks first; TAG defaults to stable
ujust migrate apply <tag>     # a dated release tag instead of the moving alias
ujust migrate help
```

Run it from a terminal: confirmations go through `ugum confirm`, and without a terminal nothing
is confirmed: steps 0, 6 and 6b are skipped and the run stops at the first of steps 3, 4 and 5
that asks. Step 2 asks nothing, so a run stopped after it leaves the backups and the pin in
place, and a second `apply` before the unpin can leave two deployments pinned.

`plan` and `apply` detect the same things and stop at the same two gates, after printing the
summary of what they found. `apply` offers step 0 before the gates, so a restore confirmed
there stays when a gate then stops the run:

- a pending deployment, staged by `uupd` or by an earlier run. rpm-ostree would queue the
  changes on it and the plan would not describe what boots next. Reboot into it, or
  `rpm-ostree cleanup -p`, then run again;
- no `ghcr.io/matrixdj96` scope in the booted policy. The abort prints the unsigned rebase
  above, unless `ostree admin config-diff` also shows `/etc/containers/policy.json` or
  `registries.d/matrixdj96.yaml` modified (`M`); a file added beside them shadows nothing. In
  that case it names the local copy and points at the restore `apply` offers from `/usr/etc`,
  which is step 0 below. The image's copy never reaches `/etc` through the three-way merge, so
  the scope would not arrive on its own.

Then, in the order the helper prints them, each skipped when already done. There is no step 1:
it is the scope precondition.

| Step | What it does                                                                                           | Why                                                                                       |
| ---- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| 0    | restores `policy.json` and `registries.d` from `/usr/etc`, backup kept                                 | only when a local copy shadows the image's; otherwise the signing scope never arrives     |
| 2    | backs up the status JSON and `fstab`, runs `ostree admin pin booted`, stops `uupd.timer`               | the booted deployment survives collection until you unpin it, and no update lands mid-run |
| 3    | `rpm-ostree uninstall --all`, the packages named in the step line                                      | layered, local and inactive requests alike: bootc counts all of them                      |
| 4    | `rpm-ostree initramfs --disable`                                                                       | the image's initramfs boots; without this bootc stays incompatible                        |
| 5    | `rpm-ostree rebase ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:<tag>`                      | same image, signed transport; rpm-ostree keeps every removal visible                      |
| 6    | verifies the rewritten `fstab` against the current one, writes it, reloads: `ntfs` rows become `ntfs3` | the in-kernel driver is the default                                                       |
| 6b   | moves ntfsplus files and foreign modules-load files to the backup, deletes ntfsplus kernel arguments   | leftovers of a host that loaded those modules on its own                                  |
| 7    | prints what stays with each user, then `rpm-ostree status`                                             | nothing is uninstalled from Flatpak                                                       |

`apply` refuses to start while `uupd.service` is activating (an update running, or its restart
queued after a failure), since rpm-ostree would refuse its steps.

Step 2 writes its backups under `/var/tmp/bazzite-mx-migrate/<timestamp>/` and restarts
`uupd.timer` on every exit path, `ERROR: uupd.timer not started again` and exit 1 when the
restart fails. Nothing puts those backups back: `fstab` goes back with
`sudo cp -a <backup>/fstab /etc/fstab && sudo systemctl daemon-reload`, and a file step 6b
moved is under `<backup>/etc/…` at its original path. `systemd-tmpfiles` removes what sits
under `/var/tmp` for 30 days (`/usr/lib/tmpfiles.d/tmp.conf`), so a backup wanted longer is
copied elsewhere. Step 6 proves `ntfs3` loadable before it writes, keeps the options, shows the
diff and checks that no `ntfs` row is left. It then compares `findmnt --verify` on the current
table and on the rewritten one: an error the rewrite adds stops the run before `fstab` is
written, an error both tables carry (a `nofail` row whose volume is unplugged, which findmnt(8)
reports as an error all the same) is counted and kept. The table is installed,
`systemctl daemon-reload` runs, and the count of pre-existing errors is printed. If `ntfs3` is
not loadable it aborts rather than leave the volumes unmounted after the reboot. Declining step
3, 4 or 5 aborts the run, an error in steps 3 to 6b stops it, and the line that ends the run
names what it changed, which stands: the backups of step 2 and the pinned booted deployment,
the restore of step 0 when it was confirmed, the pending deployment when step 3, 4 or 5 had
queued one, the `fstab` rewrite of step 6 when it was written. With a pending deployment the
next `apply` needs a reboot into it or `rpm-ostree cleanup -p`; without one `apply` can run
again at once. Declining step 6 or 6b only skips it.

Step 6 keeps an option only ntfs-3g reads (`big_writes`, `locale=`, `remove_hiberfile`), which
`ntfs3` refuses at the next boot, and `findmnt --verify` lists mount options without judging
them: take it out of `/etc/fstab` before `apply`, or decline step 6 and edit the row by hand.

The three rpm-ostree steps land in one pending deployment. What step 7 prints:

```bash
# per user, BEFORE the first start of the Firefox RPM (it reads ~/.mozilla when it exists,
# ~/.config/mozilla otherwise; the Flatpak keeps either tree under ~/.var/app, and nothing
# migrates it otherwise)
[ -e ~/.mozilla ] || [ ! -d ~/.var/app/org.mozilla.firefox/.mozilla ] \
    || cp -a ~/.var/app/org.mozilla.firefox/.mozilla ~/
[ -e ~/.config/mozilla ] || [ ! -d ~/.var/app/org.mozilla.firefox/config/mozilla ] \
    || cp -a ~/.var/app/org.mozilla.firefox/config/mozilla ~/.config/
flatpak uninstall org.mozilla.firefox          # when you are done with it
# Teams (its config is in ~/.var/app, not in ~/.config/teams-for-linux)
flatpak install flathub com.github.IsmaelMartinez.teams_for_linux
systemctl reboot
```

After the reboot, run `ujust verify-host`. Rollback at any point before the unpin:
`rpm-ostree rollback && systemctl reboot` boots the previous deployment; after a second `apply`
the one from before the migration is the older of the two pinned, which `rpm-ostree rollback`
does not reach: pick it in the boot menu, which lists the deployments in `rpm-ostree status`
order. Once the new deployment has been used for a day, unpin every deployment that
`ostree admin status` marks `Pinned: yes`: `sudo ostree admin pin -u <index>`, the index being
its position in that list, counted from 0 (no command prints it). A second `ujust migrate` on
the migrated host prints `nothing to do` and `apply` stops before the pin and the backups.

A host that ran Bazzite's `ujust setup-virtualization virt-on` keeps the `libvirt` line it
added to `/etc/group`, on a dynamic gid. At the first boot the image's groups hook moves it,
and a `docker` line on another number, to the gids the image fixes, 954 and 995, with the files
under `/run` (Docker's socket), `/etc` and `/var/lib/libvirt`; a number another group holds is
left, and `journalctl -b -u ublue-system-setup | grep bazzite-mx-groups` names it. A member
gets the new gid at the next login.

## A host already on one of these images

`ujust verify-host` is the whole procedure. Every `FAIL:` line names its fix, or the tool's
reason when a check could not run; this is the map from the line to the recipe.

| FAIL line                                                                     | What it means                                                                                | Fix                                                                              |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `bootc status reports the booted deployment incompatible`                     | an rpm-ostree group is left in the origin                                                    | `ujust migrate`                                                                  |
| `origin is not ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:<tag>` | the origin is on the unsigned transport or on another registry                               | `ujust migrate apply`                                                            |
| `origin tag is <tag>, not stable`                                             | a dated tag never updates                                                                    | `ujust migrate apply stable`                                                     |
| `rpm-ostree mutations in the origin: <list>`                                  | layered, local or inactive package requests, base removals or replacements                   | `ujust migrate`; an override: `sudo rpm-ostree override reset --all`             |
| `initramfs is regenerated locally`                                            | a local initramfs keeps bootc incompatible                                                   | `rpm-ostree initramfs --disable`, or `ujust migrate`                             |
| `policy.json has no sigstoreSigned scope for ...`                             | the booted image predates the signing trust, or `/etc` holds a local copy                    | `sudo ostree admin config-diff`, then `ujust migrate apply` (step 0)             |
| `policy.json: ... scope names key '<path>', which is missing`                 | the key the scope points at is absent                                                        | `sudo ostree admin config-diff`, then restore the file from `/usr/etc`           |
| `policy.json: default is ...`                                                 | a local edit replaced the image's `reject`                                                   | same                                                                             |
| `<registries.d file> missing or without use-sigstore-attachments`             | the sigstore attachments are not enabled                                                     | same                                                                             |
| `MSI host: msi_ec not loaded` / `acpi_ec not loaded`                          | the MSI modules are not up                                                                   | `ujust setup-msi enable`; they are unsigned, so Secure Boot has to be off        |
| `MSI residue: <files>`                                                        | a modules-load file of the host's own names those modules                                    | `ujust migrate` offers the removal                                               |
| `NVIDIA GPU present but the image is ...`                                     | wrong flavour, or a GPU no NVIDIA flavour drives: older than Maxwell, or passed to a guest   | a signed rebase, shown below; in the second case none: stay on `bazzite-mx`      |
| `no NVIDIA GPU on the bus but the image is ...`                               | wrong flavour for the hardware                                                               | a signed rebase, shown below, to `bazzite-mx`                                    |
| `nvidia module not loaded`                                                    | the driver did not come up, or the flavour's driver does not cover the GPU's generation      | `nvidia-smi`, `journalctl -k -b`; for that GPU, the signed rebase to its flavour |
| `fstab: <target> uses type <type>, not <want>`                                | an NTFS row on a driver this host does not expect                                            | `ujust migrate` rewrites it                                                      |
| `fstab: <target> is <type> but not mounted`                                   | on `ntfs3` usually a dirty volume                                                            | `journalctl -b \| grep ntfs`; dirty: full Windows shutdown or `ntfsfix -d <dev>` |
| `fstab: <target> is <type> but its device <source> is absent`                 | the volume is unplugged and its row lacks `nofail`, so the boot waits for it                 | plug it in, or add `nofail` to the row                                           |
| `fstab: <target> is <type> in fstab but mounted as <other>`                   | something else mounted it first                                                              | unmount and mount it again, or reboot                                            |
| `ntfsplus residue: <files>` / `kernel arguments mention ntfsplus: ...`        | leftovers of a host that loaded the driver on its own                                        | `ujust migrate` offers the removal                                               |
| `/etc/yum.repos.d/<file> differs from the image's copy`                       | a host edit of a repository file the image ships, kept over every later copy by the merge    | `sudo cp -a /usr/etc/yum.repos.d/<file> /etc/yum.repos.d/`                       |
| `cannot read the PCI bus: <reason>`                                           | `lspci` did not answer, so the flavour was never compared with the hardware                  | the reason is the tool's own; the check is not evidence either way               |
| `cannot read the kernel arguments: <reason>`                                  | `rpm-ostree kargs` did not answer, so the ntfsplus residue was never read                    | same                                                                             |
| `cannot list the Flatpaks: <reason>`                                          | `flatpak list` did not answer, so the Firefox Flatpak was never looked for                   | same                                                                             |

A flavour changes with the signed rebase, `<image>` being the one the fix names; for an NVIDIA
GPU, `bazzite-mx-nvidia-open` from Turing on and `bazzite-mx-nvidia`, the closed driver, for
Maxwell, Pascal and Volta, and `bazzite-mx` for an older one
(`/usr/share/doc/nvidia-driver/supported-gpus.json` in each NVIDIA image):

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:stable
```

The `<dev>` of `ntfsfix`, run as root, is the row's source as a device path, which
`findfs UUID=<uuid>` prints for a `UUID=` source.

Four lines are not failures. `INFO: the Firefox Flatpak is still installed next to the RPM`
asks for the profile copy above. `INFO: fstab rows on ntfs-3g` reports volumes deliberately
left on FUSE. `INFO: fstab: <target> (<type>, nofail): device absent, not mounted` is an
external volume that is not plugged in, which its `nofail` row allows for, and
`INFO: fstab: <target> (<type>, noauto): not mounted, as the row asks` a volume mounted by
hand. Three more lines are skips: `not an MSI host`, `MSI host without the setup-msi opt-in`
and `no NTFS entry in fstab`.

## Notes per class of host

| Class                | Flavour                                                                | What is specific                                                                                      |
| -------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| AMD or Intel desktop | `bazzite-mx`                                                           | nothing beyond the recipe; the MSI check skips and no NVIDIA module is expected                       |
| NVIDIA desktop       | `bazzite-mx-nvidia-open` from Turing, and `bazzite-mx-nvidia` to Volta | `verify-host` requires the `nvidia` module loaded; a GPU older than Maxwell stays on `bazzite-mx`     |
| MSI laptop           | the flavour the GPU needs                                              | after the reboot, `ujust setup-msi enable`; the modules are unsigned, so check `bootctl status` first |

A host with NTFS volumes is the one case worth planning: run `ujust migrate` in its read-only
form.
