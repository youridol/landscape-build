# 内核配置在 CI 静态断言，断言集合排除两处与 Arch 冲突的项

CI 不做运行时验证，因此内核配置的正确性必须在构建阶段从**产物本身**证明，而不是信任上游仓库的配置文件。做法：从构建出的 squashfs 中解出 `vmlinuz`，用内核自带的 `scripts/extract-ikconfig` 抽出真实配置，再对 Landscape 文档给出的清单逐项断言。

断言集合**不等于**文档清单原文。文档示例中有两项与 Arch 官方内核实际值相反，若逐字断言会直接构建失败。

## 依据

Landscape 要求的完整配置清单：

```
CONFIG_BPF=y
CONFIG_HAVE_EBPF_JIT=y
CONFIG_ARCH_WANT_DEFAULT_BPF_JIT=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
# CONFIG_BPF_JIT_ALWAYS_ON is not set
CONFIG_BPF_JIT_DEFAULT_ON=y
CONFIG_BPF_UNPRIV_DEFAULT_OFF=y
# CONFIG_BPF_PRELOAD is not set
CONFIG_BPF_LSM=y
CONFIG_CGROUP_BPF=y
CONFIG_IPV6_SEG6_BPF=y
CONFIG_NETFILTER_BPF_LINK=y
CONFIG_NETFILTER_XT_MATCH_BPF=m
CONFIG_NET_CLS_BPF=m
CONFIG_NET_ACT_BPF=m
CONFIG_BPF_STREAM_PARSER=y
CONFIG_LWTUNNEL_BPF=y
# CONFIG_HID_BPF is not set
CONFIG_BPF_EVENTS=y
```

— <https://landscape.whileaway.dev/intro/requirements>

关键需求概述：

> The key requirements are BTF generation, BPF support, and cgroup CPU control.

— 同上

Arch 官方 `linux` 包（pkgver `7.2.14.arch1`）实际值：

| 符号 | Arch 实际 | 文档示例 | 判定 |
|---|---|---|---|
| `CONFIG_BPF_JIT_ALWAYS_ON` | `=y` | `is not set` | **冲突** |
| `CONFIG_HID_BPF` | `=y` | `is not set` | **冲突** |
| `CONFIG_BPF_PRELOAD` | `is not set` | `is not set` | 一致 |
| 其余 18 项 | 全部符合 | 全部符合 | 一致 |

— <https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/raw/main/config.x86_64>

`BPF_JIT_ALWAYS_ON=y` 与 `HID_BPF=y` 均为**多余的启用项**，不是缺失项：它们不会让 Landscape 的功能失效，只是比文档示例更严格/更完整。因此断言只校验"必需项存在"，不校验"文档标明不启用者必须不启用"。

BTF 生成机制：

> This option enables access to the kernel configuration file through `/proc/config.gz`.

— <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/init/Kconfig>

运行时 config 与 BTF 的可得性：Arch 的 `linux` 包**不含**磁盘上的 config（`/files/` 中无 `boot/` 项，`usr/lib/modules/7.2.14-arch1-1/` 下仅 `modules.builtin*`、`modules.order`、`pkgbase`、`vmlinuz`），`build/.config` 由独立的 `linux-headers` 提供。故静态侧只能从 `vmlinuz` 抽取。`/sys/kernel/btf/vmlinux` 由内核自身在 `subsys_initcall` 创建，权限 `0444`，无需额外包。

— <https://archlinux.org/packages/core/x86_64/linux/files/>

内核版本要求存在**两处官方来源冲突**：

- README（中英双语）：`Linux kernel ≥ 6.12 with BTF/BPF enabled, root privileges` — <https://github.com/ThisSeanZhang/landscape>
- 文档站与 lkit 检查器：`6.9` — <https://landscape.whileaway.dev/intro/requirements>、<https://github.com/landscape-router/landscape-kit/blob/main/docs/check.md>

Arch 当前 `7.2.14` 高于两者，不构成阻断。ADR 记录该冲突，不单引一方。

## 被否决的方案

**逐字断言文档清单**：会在两处冲突项上失败，且冲突方向是"Arch 更严格"，属误报。

**改用 `linux-lts`**：LTS 内核版本可能低于 6.12（README 口径），且 loss 掉当前高于要求的优势。

**在 profile 里自建内核**：控制力最强但构建时间翻倍，且当前官方内核已满足全部必需项，无必要。

**运行时验证（启动 ISO 后查 `/proc/config.gz`）**：违反 CI 不启动 ISO 的约束。

## 后果

- 断言失败即构建失败，不做降级、不吞错误。
- 断言对象是产物内的 `vmlinuz`，因此上游哪天改了配置会立刻被发现，而不是沿用旧假设。
- `.BTF` section 的存在性需单独检查（`CONFIG_DEBUG_INFO_BTF=y` 只说明编译开关，实际 section 由链接脚本决定）。
