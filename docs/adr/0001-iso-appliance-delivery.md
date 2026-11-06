# 用单个 archiso 安装 ISO 交付 Landscape 路由器设备

Landscape 是路由器本体，交付物必须是一块 U 盘：插上、启动、系统自己装到目标盘、重启后就是一台路由器。archiso 只提供三种 buildmode（`bootstrap`/`iso`/`netboot`），没有 raw 磁盘镜像模式，也无法产出可持久运行的 live 系统。因此只做一个 ISO，去掉 live 菜单项，把 `kernel_params_x86_64` 写死为 `script=/root/install.sh`，U 盘启动即进入无人值守安装。ISO 本身支持 BIOS + UEFI 双引导，但装出来的系统按启动时的固件单选一种引导器。

## 依据

`mkarchiso` 用法文本：

```
-m [mode ..]     Build mode(s) to use (valid modes are: 'bootstrap', 'iso' and 'netboot').
```

源码仅实现 `_build_buildmode_bootstrap`、`_build_buildmode_netboot`、`_build_buildmode_iso`；未知模式报 `${_buildmode} is not a valid build mode!`
— <https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/archiso/mkarchiso>

ISO 混合引导能力：

> All ISO images are BIOS and UEFI bootable via "El Torito" in no-emulation mode.

— <https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/docs/README.transfer.rst>

无人值守触发机制（`kernel_params_x86_64` 经模板占位符 `%KERNEL_PARAMS%` 注入启动项）：

> `%KERNEL_PARAMS%`: Set this using an architecture-specific variable in `profiledef.sh`, such as `kernel_params_aarch64` or `kernel_params_x86_64`.

— <https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/docs/README.profile.rst>

`script=` 参数语义：

> `script=` Takes a local file path or a URL to a script file which is executed from a temporary location after boot.

— <https://gitlab.archlinux.org/archlinux/mkinitcpio/mkinitcpio-archiso/-/raw/master/docs/README.bootparams>

实际链路（三跳）：`/root/.zlogin` → `~/.automated_script.sh` → 从 `/proc/cmdline` 取 `script=` 并执行 `/tmp/startup_script`。

引导器固件支持矩阵（archinstall `installer.py`）：

```
if not SysInfo.has_uefi():
    raise HardwareIncompatibilityError
```

`SysInfo.has_uefi()` 定义为 `Path('/sys/firmware/efi').is_dir()`，判断的是 **live 环境当前以何种固件启动**。GRUB 分支为单一 `if/else`：UEFI 走 `--target=x86_64-efi`，BIOS 走 `--target=i386-pc --recheck <disk>`，二者互斥。

— <https://raw.githubusercontent.com/archlinux/archinstall/master/archinstall/lib/installer.py>

## 被否决的方案

**raw 磁盘镜像（`.img`）**：archiso 无此 buildmode；`airootfs_image_type` 的三个取值（`squashfs`/`ext4+squashfs`/`erofs`）都不产出可刷写的根。`ext4+squashfs` 的 ext4 只是临时容器，打完 squashfs 即 `rm` 删除。第三方 `archuseriso` 虽有 `-m img`，但 Arch Wiki 的 See also 未列本项目，且其 img 仍是带 COW 分区的 live 镜像，非装好的系统。

**保留 live 启动项**：用户明确要求去掉，U 盘启动只做安装。

**装好的系统同时支持 BIOS 与 UEFI**：archinstall 的 GRUB 分支二选一，且 `_boot_partition` 从不创建 BIOS boot 分区（`PartitionFlag` 枚举无该标志），而 Arch Wiki 明确 BIOS+GPT 必须有该分区：

> On a BIOS/GPT configuration, a BIOS boot partition is required. GRUB embeds its core.img into this partition.

唯一具有官方双固件部署文档的是 limine，但引入它需偏离 archinstall 的默认路径，本 ADR 不采纳。

## 后果

- ISO 无法用于排障：出问题时进不了 shell 看现场。这是去掉 live 的直接代价。
- 单 ISO 只能安装，不能像原版 Arch ISO 那样交互式安装。
- 目标机固件类型决定装出系统的引导方式；同一块盘不能跨固件搬动。
