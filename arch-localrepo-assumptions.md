# Primary-source verification: `file://` pacman repo inside the live environment's root

Workspace had no existing notes convention (directory was empty), so this file sits at the repo root.

Sources are primary: archiso `mkarchiso` + `README.profile.rst`, `pacman.8` / `pacman.conf.5` man pages,
`arch-install-scripts/pacstrap.in`, archinstall source. Plus a direct empirical test on the local
`pacman 7.1.0 - libalpm v16.0.1`.

---

## ASSUMPTION 1 — airootfs copy timing

### What the docs say

`https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/docs/README.profile.rst`, section `airootfs`:

> This optional directory may contain files and directories that will be copied to the work directory of the resulting
> image's root filesystem.
> The files are copied before packages are being installed to work directory location.

### What the code does

`https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/archiso/mkarchiso`

Copy function, line 315:

```bash
_make_custom_airootfs() {
    ...
    if [[ -d "${profile}/airootfs" ]]; then
        _msg_info "Copying custom airootfs files..."
        _unshare cp -af --no-preserve=ownership,mode -- "${profile}/airootfs/." "${pacstrap_dir}"
```

Install function, line 348:

```bash
_make_packages() {
    local -a _pacstrap_options
    _pacstrap_options=(-C "${work_dir}/${buildmode}.pacman.conf" -c -G -M -- "${pacstrap_dir}" "${buildmode_pkg_list[@]}")
    ...
    env -u TMPDIR pacstrap "${_pacstrap_options[@]}"
```

Call order inside `_build_iso_base()` (function starts line 1843):

```
1859:    _run_once _make_pacman_conf
1861:    _run_once _make_custom_airootfs
1862:    _run_once _make_packages
1863:    _run_once _make_version
1867:    _run_once _make_customize_airootfs
1884:    _run_once _cleanup_pacstrap_dir
```

**Order is definitive: airootfs copy (line 1861) happens BEFORE pacstrap (line 1862).**

Consequence: anything placed in `airootfs/opt/localrepo/` exists in the pacstrap dir before pacman runs, so
packages installed later may overwrite the same paths, and `file_permissions` apply before install too.

### `_cleanup_pacstrap_dir()` — full text, lines 162–185

```bash
# Cleanup airootfs
_cleanup_pacstrap_dir() {
    _msg_info "Cleaning up in pacstrap location..."

    # Delete all files in /boot
    [[ -d "${pacstrap_dir}/boot" ]] && _unshare find "${pacstrap_dir}/boot" -mindepth 1 -delete
    # Delete pacman database sync cache files (*.tar.gz)
    [[ -d "${pacstrap_dir}/var/lib/pacman" ]] && _unshare find "${pacstrap_dir}/var/lib/pacman" -maxdepth 1 -type f -delete
    # Delete pacman database sync cache
    [[ -d "${pacstrap_dir}/var/lib/pacman/sync" ]] && _unshare find "${pacstrap_dir}/var/lib/pacman/sync" -delete
    # Delete pacman package cache
    [[ -d "${pacstrap_dir}/var/cache/pacman/pkg" ]] && _unshare find "${pacstrap_dir}/var/cache/pacman/pkg" -type f -delete
    # Delete all log files, keeps empty dirs.
    [[ -d "${pacstrap_dir}/var/log" ]] && _unshare find "${pacstrap_dir}/var/log" -type f -delete
    # Delete all temporary files and dirs
    [[ -d "${pacstrap_dir}/var/tmp" ]] && _unshare find "${pacstrap_dir}/var/tmp" -mindepth 1 -delete
    # Delete package pacman related files.
    _unshare find "${work_dir}" \( -name '*.pacnew' -o -name '*.pacsave' -o -name '*.pacorig' \) -delete
    # Create /etc/machine-id with special value 'uninitialized': the final id is
    # generated on first boot, systemd's first-boot mechanism applies (see machine-id(5))
    _unshare rm -f -- "${pacstrap_dir}/etc/machine-id"
    printf 'uninitialized\n' | _unshare install -m 0444 /dev/stdin "${pacstrap_dir}/etc/machine-id"

    _msg_info "Done!"
}
```

Exactly what it deletes:

| Path | Scope |
|---|---|
| `${pacstrap_dir}/boot` | contents only (`-mindepth 1`), dir kept |
| `${pacstrap_dir}/var/lib/pacman` | files at `-maxdepth 1` only |
| `${pacstrap_dir}/var/lib/pacman/sync` | everything |
| `${pacstrap_dir}/var/cache/pacman/pkg` | files only |
| `${pacstrap_dir}/var/log` | files only, dirs kept |
| `${pacstrap_dir}/var/tmp` | contents only |
| `${work_dir}` (whole tree) | `*.pacnew`, `*.pacsave`, `*.pacorig` |
| `${pacstrap_dir}/etc/machine-id` | removed, then rewritten as `uninitialized` |

`/opt/localrepo` is in none of those paths.

**VERDICT: CONFIRMED.** Copy precedes pacstrap; `_cleanup_pacstrap_dir()` does not touch `/opt` — a
`${pacstrap_dir}/opt/localrepo` survives cleanup and is therefore baked into the airootfs image
(`_run_mksquashfs "${pacstrap_dir}"`, called right after from `_prepare_airootfs_image`).

---

## ASSUMPTION 2 — pacman `--config` + `-r` path resolution

### `--root` / `-r` — `https://man.archlinux.org/man/pacman.8.en` (lines 129–137)

> -r, --root <path>
>     Specify an alternative installation root (default is /). This
>     should not be used as a way to install software into /usr/local
>     instead of /usr.  NOTE: If database path or log file are not
>     specified on either the command line or in pacman.conf(5), their
>     default location will be inside this root path.  NOTE: This option
>     is not suitable for performing operations on a mounted guest
>     system. See --sysroot instead.

It says nothing about `--config` and nothing about `file://` under `-r`.

### `--config` — `pacman.8` (lines 158–159)

> --config <file>
>     Specify an alternate configuration file.

Nothing about root-relative resolution.

### `--sysroot` — `pacman.8` (lines 197–202)

> --sysroot <dir>
>     Specify an alternative system root. This path will be prepended to
>     all other configuration directories and any repository servers
>     beginning with file://. Any paths or URLs passed as targets will
>     not be modified. This allows mounted guest systems to be properly
>     operated on.

This is decisive by contrast: **only** `--sysroot` prepends the root to configuration directories and to
`file://` servers. `-r` does not.

### `Server` directive — `https://man.archlinux.org/man/pacman.conf.5.en` (lines 227–234)

> Each repository section defines a section name and at least one
> location where the packages can be found. The section name is defined
> by the string within square brackets (the two above are core and
> custom). Repository names must be unique and the name local is reserved
> for the database of installed packages. Locations are defined with the
> Server directive and follow a URL naming structure. If you want to use
> a local directory, you can specify the full path with a "file://"
> prefix, as shown above.

Example from the same page (line 31): `Server = file:///home/pkgs`.

Also, `pacman.conf.5` `RootDir` (lines 41–46) only discusses DB path / log file defaults going inside the root —
not `Server`.

### Empirical test (local `pacman 7.1.0 - libalpm v16.0.1`)

Test A — repo at host path `/tmp/pt/repoA`, `-r /tmp/pt/rootA`, `Server = file:///tmp/pt/repoA`:

```
:: Synchronizing package databases...
 test downloading...
exitA=0
```

Test B — repo **only** inside the new root at `<root>/opt/localrepo`, host has no `/opt/localrepo`,
`Server = file:///opt/localrepo`:

```
error: failed retrieving file 'test.db' from disk : Could not open file /opt/localrepo/test.db
error: failed to synchronize all databases (download library error)
exitB=1
```

The error path `/opt/localrepo/test.db` carries no root prefix. Host-side resolution.

Test D — same config under `--sysroot` instead:

```
error: config file /tmp/pt/rootB/tmp/pt/cfg/B.conf could not be read: No such file or directory
```

i.e. `--sysroot` **did** prepend the root to the `--config` path (and would have to `file://` servers too),
exactly as the man page states — the opposite of `-r`.

Test E — `--config=/etc/pacman.conf` where that absolute path exists in both host and root with different
content, under `-r`:

```
:: Synchronizing package databases...
 core downloading...
 extra downloading...
exitE1=0
```

The **host's** `/etc/pacman.conf` was read (real upstream mirrors), not the root-local copy.

Verbose resolution under `-r` (`-Syv`):

```
Root      : /tmp/pt/rootA/
Conf File : /tmp/pt/cfg/A.conf
DB Path   : /tmp/pt/rootA/var/lib/pacman/
Hook Dirs : /tmp/pt/rootA/usr/share/libalpm/hooks/  /etc/pacman.d/hooks/
```

`Conf File` is reported unmodified; `DB Path` is root-prefixed. Config path is host-side.

### Answer

For `pacman -r /mnt --config=/etc/pacman.conf` with `Server = file:///opt/localrepo`:
the **host (live environment)** filesystem must contain `/opt/localrepo`. The target root `/mnt` must not be
relied on. Both the `--config` file and the `file://` server path are resolved on the host; `-r` only relocates
pacman's own state (database, cache, log, target paths).

**VERDICT: CONFIRMED.** The man pages settle it by explicit contrast (`--sysroot` prepends; `-r` does not), and
the behaviour reproduces on pacman 7.1.0.

---

## ASSUMPTION 3 — archinstall and `/etc/pacman.conf`

### pacstrap argv — `archinstall/lib/pacman/pacman.py` lines 108–114

```python
		self.ask(
			'Could not strap in packages',
			'Pacstrap failed. See /var/log/archinstall/install.log or above message for error details',
			SysCommand,
			f'pacstrap -C {PACMAN_CONF} -K {self.target} {" ".join(packages)} --noconfirm --needed',
			peek_output=True,
		)
```

`-C` value is `PACMAN_CONF`, i.e. the literal live-environment path `/etc/pacman.conf`.

### `PACMAN_CONF` — `archinstall/lib/pathnames.py` line 8

```python
PACMAN_CONF: Final = LPath('/etc/pacman.conf')
```

(`LPath` is a `pathlib.Path` subclass, so the f-string renders `/etc/pacman.conf`.)

### Every `pacman.conf` hit in `installer.py`

```
 63:from archinstall.lib.pacman.config import PacmanConfig
 65:from archinstall.lib.pathnames import MIRRORLIST, PACMAN_CONF
 72:# pacman picks the first initramfs provider from the host's pacman.conf, which on non-Arch
586:			pacman_config = self.target / PACMAN_CONF.relative_to_root()
589:			pacman_config = PACMAN_CONF
595:			with pacman_config.open('a') as fp:
894:		pacman_config: PacmanConfiguration | None = None,
932:		pacman_conf = PacmanConfig(self.target)
933:		pacman_conf.enable(optional_repositories)
934:		pacman_conf.apply()
942:		pacman_conf.persist()
944:		if pacman_config:
945:			pacman_conf.configure(pacman_config)
```

Context for 586–595 (`set_mirrors`, `on_target` branch): if `on_target` is false the code writes to the **live**
`/etc/pacman.conf`:

```python
		if on_target:
			mirrorlist_config = self.target / MIRRORLIST.relative_to_root()
			pacman_config = self.target / PACMAN_CONF.relative_to_root()
		else:
			mirrorlist_config = MIRRORLIST
			pacman_config = PACMAN_CONF
		...
			with pacman_config.open('a') as fp:
				fp.write(repositories_config)
```

### Does archinstall rewrite the target's `pacman.conf`?

Order in `minimal_installation` (`installer.py` 930–945):

```python
		pacman_conf = PacmanConfig(self.target)
		pacman_conf.enable(optional_repositories)
		pacman_conf.apply()

		if locale_config:
			self.set_vconsole(locale_config)

		self.pacman.strap(self._base_packages)      # line 940
		self._helper_flags['base-strapped'] = True

		pacman_conf.persist()                        # line 942
```

`archinstall/lib/pacman/config.py`:

```python
	def apply(self) -> None:              # writes the LIVE /etc/pacman.conf in place
		...
		content = PACMAN_CONF.read_text().splitlines(keepends=True)
		...
		with PACMAN_CONF.open('w') as f:
			f.writelines(content)

	def persist(self) -> None:            # copies LIVE -> target, after pacstrap
		if self._config_remote_path:
			PACMAN_CONF.copy(self._config_remote_path, preserve_metadata=True)
```

So: no rewrite happens before pacstrap. `apply()` mutates the **live** file (and returns early when no optional
repositories were requested). `persist()` copies live → target **after** pacstrap succeeds. `configure()` only
tweaks `Color` / `ParallelDownloads` on the target copy.

Note the comment at line 930: *"This action takes place on the host system as pacstrap copies over package
repository lists."*

### Answer to the question

If a user overwrites `/etc/pacman.conf` in the live environment before running archinstall, pacstrap **will** use
that modified file. `-C /etc/pacman.conf` is an absolute host path, and nothing copies or regenerates a target
config before `strap()`. Two caveats that are visible in the code:

1. `apply()` will rewrite the live file when `--optional-repositories` is non-empty — but it only uncomments
   `#[repo]` sections it was asked for; it does not delete a hand-added `[local]` block.
2. `persist()` copies the live file into the installed system, so a `Server = file:///opt/localrepo` line lands in
   the target's `/etc/pacman.conf` even though `/opt/localrepo` is not installed there.

**VERDICT: CONFIRMED.**

---

## ASSUMPTION 4 — does pacstrap run pacman hooks

### `pacstrap.in` argument construction

`https://raw.githubusercontent.com/archlinux/arch-install-scripts/master/pacstrap.in`, lines 141–148:

```bash
pacman_args+=("$pacmode" "${@:-base}" --config="$pacman_config")

if (( ! hostcache )); then
  pacman_args+=(--cachedir="$newroot/var/cache/pacman/pkg")
fi

if (( ! interactive )); then
  pacman_args+=(--noconfirm)
fi
```

Plus optional `-dd` from `-D` (line 99: `pacman_args+=(-dd)`), default `pacmode=-Sy` (line 18), and
`pacman_config=/etc/pacman.conf` (line 19). Invocation (line 74):

```bash
  if ! $pid_unshare pacman -r "$newroot" "${pacman_args[@]}"; then
```

Full assembled form: `pacman -r <root> -Sy <targets> --config=<conf> [--cachedir=<root>/var/cache/pacman/pkg] [--noconfirm]`.

`grep -c "nohooks\|hookdir" pacstrap.in` → **0 matches**. Neither `--nohooks` nor `--hookdir` is passed.

### Answer

PostTransaction hooks execute during pacstrap. With no `--nohooks`, pacman uses its default hook behaviour; the
hook directories in effect come from the config passed by `--config`. Under `-r` the resolved hook dirs are a mix
of root-prefixed and host-absolute:

```
Hook Dirs : <root>/usr/share/libalpm/hooks/  /etc/pacman.d/hooks/
```

archiso itself depends on this, and pins the hook dir into the target in `_make_pacman_conf()`
(`mkarchiso` line 290), which explicitly generates the pacman config used for pacstrap:

```bash
    pacman-conf --config "${pacman_conf}" \
        | sed "/CacheDir/d;/DBPath/d;/HookDir/d;/LogFile/d;/RootDir/d;/[options]/a CacheDir = ${_cache_dirs}
        /[options]/a HookDir = ${pacstrap_dir}/etc/pacman.d/hooks/" >"${work_dir}/${buildmode}.pacman.conf"
```

**VERDICT: CONFIRMED.** Hooks run during pacstrap; pacstrap passes no `--nohooks` and no `--hookdir`.

---

## Blocking problems found

- **`file://` servers resolve on the host, not in `--root`.** A repo at `<target>/opt/localrepo` is invisible to
  pacstrap. The repo must be at `/opt/localrepo` in the live environment. `--sysroot` is the flag that would
  prepend the root — `-r` does not, and pacstrap only ever passes `-r`.
- **assumption 1 survives, but only by absence of a deletion rule.** `_cleanup_pacstrap_dir()` happens to skip
  `/opt`; nothing guarantees it in future. A path under `/var`, `/boot`, or any `*.pacnew` name inside `work_dir`
  would be destroyed.
- **The `Server = file:///opt/localrepo` line is copied into the installed system.** `PacmanConfig.persist()`
  copies the live `/etc/pacman.conf` to the target after pacstrap, so the finished system keeps a dangling
  `file://` server unless it is stripped or `/opt/localrepo` is also installed.
- **`pacman -Sy` during pacstrap against a locally-built repo needs signatures or `SigLevel` lowered.** pacstrap
  passes no `--noconfirm`-adjacent trust override and archinstall adds `-K` (fresh empty keyring in the target),
  so an unsigned local repo will fail signature checks unless the config says so. Not tested here; flagged.
- **archiso's own pacstrap invocation is not the same as archinstall's.** archiso builds a generated config in
  `work_dir` and passes `-c -G -M`; archinstall passes `-C /etc/pacman.conf -K`. Any guidance must say which one
  it targets.
