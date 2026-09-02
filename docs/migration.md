# Migrating a host to v2

How a host that runs a v1 image (unsigned transport, layered packages, locally regenerated
initramfs, NTFS volumes on the `ntfs` driver) reaches the state the v2 image expects, and how
that state is checked. Two recipes do the work: `ujust migrate` and `ujust verify-host`
(`docs/divergences.md` § ujust recipes has the design references). Order of hosts (decision
1.7): the AMD hub first, with a console and the rollback ready; the two NVIDIA hosts only after
the hub has run 24 hours.

## What "done" looks like

`ujust verify-host` prints one line per check and exits 0:

- `bootc status` reports the booted deployment compatible: no layered, local or removed
  packages, no requested modules, no local initramfs regeneration (bootc marks the origin
  incompatible on any rpm-ostree group, `crates/lib/src/utils.rs:23-32`; with it, uupd stays on
  the rpm-ostree driver). A request the image already satisfies is not layered any more but
  stays in the origin (`requested-packages`) and counts: the hub's `1password` after the
  unsigned rebase ([`gotchas.md`](gotchas.md));
- the origin is `ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:stable`, the image
  name being the booted image's own (`/usr/share/ublue-os/image-info.json`); a dated tag never
  receives an update;
- `/etc/containers/policy.json` carries the `ghcr.io/matrixdj96` scope (`sigstoreSigned`, key
  `/etc/pki/containers/matrixdj96.pub`), `registries.d/matrixdj96.yaml` enables the sigstore
  attachments, `default` is still `reject`;
- on an MSI host `msi_ec` and `acpi_ec` are loaded; an NVIDIA GPU means the `nvidia-open`
  flavour with the `nvidia` module loaded, and no GPU means the other flavour;
- every NTFS entry in fstab uses `ntfs3` and is mounted with it; no ntfsplus file under
  `/etc/modprobe.d` or `/etc/modules-load.d`, no ntfsplus kernel argument;
- a Firefox Flatpak still installed is reported, not failed.

## The egg and the chicken

The signed pull is verified against the policy of the deployment that runs it. A v1 image has
no `ghcr.io/matrixdj96` scope, so the first v2 image is reached once through the unsigned
transport; `ujust migrate` refuses to go further until then and prints the command:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/matrixdj96/<image>:<tag>
systemctl reboot
```

`<image>` is `bazzite-mx` or `bazzite-mx-nvidia-open`; `<tag>` is `stable` (a dated tag pins
one release and never updates). The rebase keeps the layered packages and the initramfs setting: they are removed by the next step,
on a deployment whose policy knows the scope.

One exception, measured on both NVIDIA hosts (2026-09-04): a package the v2 image ships that the
host installed as a **local** RPM (from a file, `requested-local-packages`) is reinstalled
verbatim on the new base and rpm-ostree refuses the transaction ("cannot install both
1password-8.12.28 from @commandline and 1password-8.12.34 from @System"). A package layered from a
repository becomes an inactive request instead (the hub). Drop the local request in the same
transaction:

```bash
sudo rpm-ostree upgrade --uninstall=1password-8.12.28-1.x86_64    # the origin already follows :stable
```

`rpm-ostree status --json | jq '.deployments[0]["requested-local-packages"]'` lists the local
requests; the other ones go with `ujust migrate apply` on the next boot.

## The recipe

```bash
ujust migrate            # plan: read-only, prints what apply would do, aborts on what blocks it
ujust migrate apply      # every step asks; default TAG stable
ujust migrate apply 44.20260903   # the pilot: the dated release tag first
```

`plan` and `apply` detect the same things and stop on the same conditions:

- a pending deployment (staged by uupd, or an earlier run): rpm-ostree would queue the changes
  on it and the plan would not describe what boots next. Reboot into it, or
  `rpm-ostree cleanup -p`, then run again;
- `/etc/containers/policy.json` or `registries.d/` modified locally
  (`ostree admin config-diff`): the image's copy never reaches `/etc` through the three-way
  merge, so the scope would never arrive. `apply` offers to restore them from `/usr/etc` with a
  backup;
- no `ghcr.io/matrixdj96` scope in the booted policy: the unsigned rebase above, first.

Then, in order, each behind a confirmation and skipped when already done:

| Step | Command | Why |
|---|---|---|
| backups and pin | status JSON and fstab under `/var/tmp/bazzite-mx-migrate/<timestamp>/`; `ostree admin pin booted`; `uupd.timer` stopped until the end | the booted deployment survives the garbage collection until you unpin it; no update lands mid-run |
| packages | `rpm-ostree uninstall --all` (dry run shown first) | layered and local packages alike; v2 ships 1Password in the image, Teams is a Flatpak |
| initramfs | `rpm-ostree initramfs --disable` | the image's initramfs boots; without this bootc stays incompatible |
| origin | `rpm-ostree rebase ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:TAG` | same image, signed transport; rpm-ostree rather than `bootc switch` so every removal is visible and the same origin results |
| fstab | `ntfs3` proven loadable, the type column of `ntfs` rows rewritten to `ntfs3` (options untouched), zero `ntfs` rows after, `systemctl daemon-reload`, `findmnt --verify --fstab` | decision 1.5a: the in-kernel driver; `nofail` is already on every row of the fleet |
| residue | ntfsplus files moved to the backup directory, ntfsplus kernel arguments deleted | leftovers of the ntfsplus round on the NVIDIA hosts |

The three rpm-ostree steps land in one pending deployment. Nothing is done to Flatpak: at the
end the recipe prints what stays with each user and with you:

```bash
# per user, BEFORE the first start of the Firefox RPM (its profile lives in ~/.mozilla,
# the Flatpak's in ~/.var/app; nothing migrates it otherwise)
[ -d ~/.mozilla ] || cp -a ~/.var/app/org.mozilla.firefox/.mozilla ~/
flatpak uninstall org.mozilla.firefox          # when you are done with it
# Teams (its config is in ~/.var/app, not in ~/.config/teams-for-linux)
flatpak install flathub com.github.IsmaelMartinez.teams_for_linux
systemctl reboot
```

After the reboot: `ujust verify-host`.
Rollback at any point before the unpin: `rpm-ostree rollback && systemctl reboot`. Unpin after
24 hours of use: `sudo ostree admin pin -u <index of the old deployment>` (`rpm-ostree status`
lists the index).

## Per-host notes

| Host | Expected plan | Watch |
|---|---|---|
| hub (AMD) | `1password` removed, initramfs disabled, rebase; no fstab row | `verify-host` clean |
| desktop (RTX 5070 Ti) | two local RPMs removed, initramfs disabled, rebase, 4 fstab rows to `ntfs3` | after the reboot `findmnt -t ntfs3` shows the 4 volumes and the Steam bind mounts are active; a volume left dirty by Windows fast startup does not mount (ntfs3 refuses it without `force`, which is never added): full shutdown on Windows or `ntfsfix -d` |
| laptop (MSI, RTX 4070) | as the desktop with 2 fstab rows, plus the ntfsplus kernel-argument mask | inventory first (`bootctl status`: with Secure Boot on, the unsigned `msi-ec` and `acpi_ec` do not load); physical console, the host has a known boot hang |

One caution measured on the fleet: never run `rsync --delete` toward a volume mounted with
`ntfs3` (the driver wedges in D state under sustained metadata work; only a reboot recovers).
Bulk deletions on NTFS volumes wait for the ntfsplus round.
