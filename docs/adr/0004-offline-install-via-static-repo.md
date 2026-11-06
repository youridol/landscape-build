# 安装期用 airootfs 内的静态 pacman 仓库，装完恢复正式镜像源

为缩短安装时间，把所需包预先打成 pacman 本地仓库放进 `airootfs/opt/localrepo/`，安装脚本在调用 archinstall 之前把带 `[localrepo]` 的 `pacman.conf` 覆盖到 live 环境的 `/etc/pacman.conf`。安装结束后、重启之前，再用 `arch-chroot` 把目标系统的 `pacman.conf` 恢复成正常镜像源。

## 为什么这样可行（四个机械前提均已实测确认）

**1. `airootfs` 在装包之前被拷贝**

> The files are copied before packages are being installed to work directory location.

`mkarchiso` 的 `_build_iso_base()` 中，第 1861 行 `_run_once _make_custom_airootfs` 先于第 1862 行 `_run_once _make_packages` 执行。

— <https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/docs/README.profile.rst>

**2. `/opt` 不被清理**

`_cleanup_pacstrap_dir()` 删除的是：`${pacstrap_dir}/boot` 内容、`var/lib/pacman` 顶层文件、`var/lib/pacman/sync`、`var/cache/pacman/pkg`、`var/log`、`var/tmp` 以及 `*.pacnew`/`*.pacsave`/`*.pacorig`。`/opt` 不在删除范围。

**3. `-r` 不改变 `file://` 的解析基准**

> This path will be prepended to all other configuration directories and any repository servers beginning with `file://`.

该行为属于 `--sysroot`，`--root`（`-r`）没有此效果。实测（pacman 7.1.0）：仓库仅存在于目标根时，`pacman -r` 报 `error: failed retrieving file 'test.db' from disk : Could not open file /opt/localrepo/test.db`。故**仓库必须位于 live 环境（即主机侧）的 `/opt/localrepo`**，不能放在目标根。archinstall 本身运行在 live 环境，恰为"主机"。

— <https://man.archlinux.org/man/pacman.8.en>

**4. archinstall 读取的正是 live 环境的 `/etc/pacman.conf`**

```
pacstrap -C /etc/pacman.conf -K {self.target} {...} --noconfirm --needed
```

`PACMAN_CONF: Final = LPath('/etc/pacman.conf')`

— <https://raw.githubusercontent.com/archlinux/archinstall/master/archinstall/lib/pacman/pacman.py>、<https://raw.githubusercontent.com/archlinux/archinstall/master/archinstall/lib/pathnames.py>

## `--offline` 挡不住下载

> Disabled online upstream services such as package search and key-ring auto update.

`--offline` 只跳过 `main.py` 中的 `_check_online()`（ping `1.1.1.1`）与 `_fetch_arch_db()`（`pacman -Sy`）。`Pacman.strap()` 仍无条件调用 `self.sync()`（`pacman -Syy`），pacstrap 默认 `pacmode=-Sy`，最终仍会访问 `Server` 条目。所以仅加 `--offline` 不构成离线安装，必须有本地仓库兜底。

— <https://raw.githubusercontent.com/archlinux/archinstall/master/archinstall/lib/args.py>

## 两个必须处理的副作用

**签名校验**：未签名的本地仓库 + archinstall 的 `-K`（空 keyring）会导致签名校验失败。本地仓库段落显式设 `SigLevel = Optional TrustAll`。

**残留的 `file://` 源**：`config.py` 的 `persist()` 会把 live 环境改过的 `pacman.conf` 复制进已安装系统。若不处理，目标系统每次 `pacman -Sy` 都会报 `file:///opt/localrepo` 不可达。因此安装脚本必须在 archinstall 结束后、重启前用 `arch-chroot` 把 `pacman.conf` 恢复为标准 `[core]`/`[extra]` 镜像源。

— <https://raw.githubusercontent.com/archlinux/archinstall/master/archinstall/lib/installer.py>

## 依据（官方配方）

Arch Wiki 记录了本地 `file://` 仓库的完整做法：

> # repo-add ./custom.db.tar.zst ./*[^sig]
> [custom]
> SigLevel = Optional
> Server = file:///mnt/repo/

并需注释掉 `[core]`/`[extra]` 以免 pacman 在默认仓库上失败。
— <https://wiki.archlinux.org/title/Offline_installation>

pacman 支持 `file://` 本地目录：

> If you want to use a local directory, you can specify the full path with a "file://" prefix, as shown above.

— <https://man.archlinux.org/man/pacman.conf.5.en>

## 无官方背书的部分

以下三处**官方文档没有覆盖**，本 ADR 明确标注为自研扩展：

1. 把 `repo-add` 生成的仓库放进 `airootfs/opt/localrepo/` 并随 squashfs 发布。Arch Wiki 自己把这步标为未完成：`{{Expansion|Add optional instructions on placing the custom repo in the ISO.}}`
2. 依赖 `/opt` 逃过 `_cleanup_pacstrap_dir()`。这是观察到的行为，没有任何规则承诺该路径安全；若上游把删除范围扩大，本方案会静默失效。
3. 覆盖 live 环境 `/etc/pacman.conf` 以绕开 archinstall 的硬编码路径。

## 被否决的方案

**fork `mkarchiso`**：用户明确不与上游脱钩。

**用 profile 的 pacman hook 拦截**：不改上游，但依赖 hook 执行早于清理这一未文档化的顺序假设，更脆。

**允许安装时联网**：用户已否决。PPPoE 场景下安装期可能拿不到网。

**`ext4+squashfs` 或 `unsquashfs` 二次提取**：产物形态复杂，且同样无官方支持。

## 后果

- CI 会下载两次包（一次供本地仓库，一次供 `mkarchiso` 自身 `pacstrap -c -G -M`）。这是构建时间成本，不是安装时间成本，符合取舍。
- 若 `/opt` 的清理豁免在未来的 archiso 版本中消失，构建仍会成功，但安装期会退化回联网下载。需在 CI 中增加一条断言：解出的 squashfs 里 `/opt/localrepo` 必须存在且 `custom.db.tar.*` 可读。
- 使用 `--sysroot` 而非 `-r` 时解析基准会反过来，本方案固定走 `-r`（archinstall 内部行为），不可混用。
