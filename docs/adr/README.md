# Landscape 路由器设备构建计划

一份 archiso profile，产出一个可刷写的安装 ISO。U 盘启动即无人值守安装 Landscape 到目标盘，重启后即为一台路由器。

本文是索引与总参数表。四个具体取舍各自成篇，见文末。

## 产物

| 项 | 值 |
|---|---|
| 形态 | 单个 `.iso`，无 raw 磁盘镜像，无 live 菜单项 |
| 架构 | 仅 `x86_64` |
| ISO 引导 | BIOS（syslinux）+ UEFI（systemd-boot）双引导 |
| 装出系统的引导 | 按启动时固件单选，配置显式写 `bootloader = grub`：UEFI 起 → `--target=x86_64-efi`；BIOS 起 → `--target=i386-pc` |
| Secure Boot | 不签名 |
| 命名 | `<iso_name>-<iso_version>-x86_64.iso`（`mkarchiso` 固定格式） |
| 校验 | CI 额外生成 `.iso.sha256`（`mkarchiso` 不自带） |

## 构建

| 项 | 值 |
|---|---|
| CI 载体 | `ubuntu-latest` + `docker run --privileged archlinux:latest` |
| 构建命令 | `mkarchiso -v -w /work -o /out /profile` |
| Landscape 版本 | 钉死 `0.28.0`，取 release 资产 `landscape-webserver-x86_64` + `static.zip`，用 `SHASUM256sum.txt` 校验 |
| 本地仓库 | `airootfs/opt/localrepo/`，`repo-add` 生成，`SigLevel = Optional TrustAll` |
| 不 fork 上游 | 全程在文档化的 profile 机制内 |

## 运行时行为

| 项 | 值 |
|---|---|
| 触发 | `kernel_params_x86_64` 写死 `script=/root/install.sh`，开机直落安装脚本 |
| 目标盘选择 | 排除装机介质所在盘与已挂载盘；候选不唯一则中止并打印候选 |
| 网络 | 主机侧不配网，Landscape 独占；mask `systemd-networkd` |
| DNS | 不装 `systemd-resolvconf`，`systemd-resolved.service` stop + disable + mask |
| 首次初始化 | 纯 `--auto`，得 `https://192.168.5.1:6443` |
| 首次访问前提 | 必须把电脑接到 LAN 口 |
| 硬件前提 | 至少 2 个物理网口（lkit 明确不支持单臂 WAN/LAN 路由） |
| 装完后 | 用 `arch-chroot` 把 `pacman.conf` 恢复为标准镜像源 |

## 依赖包（在 releng 基础上增删）

新增：`ppp`（PPPoE）、`iproute2`（`ip` 与 `tc`）、`procps`（`sysctl`）、`bpf`（如需 `bpftool` 排障）

禁止新增：`networkmanager`

不安装：`systemd-resolvconf`

必须存在：`mkinitcpio`、`mkinitcpio-archiso`（archiso 强制要求）

## CI 静态验证清单

不启动 ISO。全部验证针对构建产物：

1. ISO 存在且 SHA256 已生成
2. 从 squashfs 解出 `vmlinuz`，`extract-ikconfig` 抽配置，对 Landscape 必需项逐项断言（清单见 ADR-0003）
3. `vmlinuz` 含 `.BTF` section
4. 解出的 `airootfs` 中存在 `/opt/localrepo/custom.db.tar.*` 且可读
5. 解出的 `airootfs` 中存在 `/root/install.sh` 且权限 `0755`
6. 解出的 `airootfs` 中存在 `landscape-webserver` 与 `static/`
7. 自写 systemd unit 含 `LimitMEMLOCK=infinity`
8. `packages.x86_64` 不含 `networkmanager`

## 无官方背书的自研扩展

以下三处官方文档未覆盖，实现时必须逐处标注，不得与官方行为混述：

1. 静态仓库放进 `airootfs/opt/localrepo/` 并随 squashfs 发布（Arch Wiki 自标为未完成）
2. 依赖 `/opt` 逃过 `_cleanup_pacstrap_dir()`（观察到的行为，非契约）
3. 覆盖 live 环境 `/etc/pacman.conf` 以绕开 archinstall 的硬编码路径

## 已核实的事实冲突（不得单引一方）

- **内核版本**：README 写 `≥ 6.12`，文档站与 lkit 写 `6.9`。Arch 当前 `7.2.14` 高于两者。
- **内核配置**：文档示例写 `# CONFIG_BPF_JIT_ALWAYS_ON is not set` 与 `# CONFIG_HID_BPF is not set`，Arch 实际均为 `=y`。冲突方向是 Arch 更严格，断言只校验必需项存在。
- **`systemd-resolved` 包名**：不存在该独立包，实现为不装 `systemd-resolvconf` + mask 服务。

## 相关 ADR

- [ADR-0001 用单个 archiso 安装 ISO 交付](./0001-iso-appliance-delivery.md)
- [ADR-0002 手工铺二进制，不用 lkit，不装 NetworkManager](./0002-bundle-binary-not-lkit.md)
- [ADR-0003 内核配置在 CI 静态断言](./0003-kernel-config-assertion-in-ci.md)
- [ADR-0004 安装期用静态 pacman 仓库](./0004-offline-install-via-static-repo.md)

## 证据附录

[`arch-localrepo-assumptions.md`](../../arch-localrepo-assumptions.md)：ADR-0004 所依赖的四个机械前提的逐条验证，含 pacman 7.1.0 实测输出。

## 构建验证结果

CI 已跑通，最新产物：

| 项 | 值 |
|---|---|
| 文件名 | `landscape-router-<时间戳>-<短sha>.iso`（例：`landscape-router-20261106-1252-1f26a35a.iso`） |
| 大小 | 1 806 368 768 字节 |
| SHA256 | 见 Release 页面的同名 `.iso.sha256` |
| 发布位置 | Release tag `iso-latest`，每次构建覆盖 |
| 内核 | `7.2.14-arch1-1` |

产物名带时间戳与提交号，直接来自 `git rev-parse --short`，所以具体值随每次构建变化，不写死在文档里。

静态检查全部通过：Landscape 二进制与 static 就位、本地仓库完整依赖闭包、安装脚本语法与执行位、无 NetworkManager、无 `systemd-resolvconf`、内核配置 19 项断言全过、`.BTF` section 存在。

### 调试中修正的认知

1. **`airootfs` 拷贝不保留权限**。`mkarchiso` 用 `cp -af --no-preserve=ownership,mode`，二进制会退化为 `644`。必须在 `file_permissions` 里显式列出 `/opt/landscape/landscape-webserver`。

2. **`modemmanager` 会拉进 NetworkManager**。releng 包列表里没有 `networkmanager`，但 `modemmanager` 依赖它。同时移除 `iwd`、`dhcpcd` 等竞争网络管理器。

3. **`vmlinuz-linux` 是 bzImage**。以 `MZ` 开头，zstd 压缩流不在文件开头。取解压结果最大者作为内核镜像，再用 `readelf -S` 找 `.BTF`。直接搜索 `IKCFG_ST` 原始字节找不到，必须先解压。

4. **`DATABASE_URL` 会让数据库建不出来**。unit 里写 `DATABASE_URL=sqlite:///...` 导致 `SqliteError code 14`，数据库无法创建。去掉该变量即可。

5. **网桥 MAC 需显式设置**。`init_devs` 建 `br_lan` 时不给 MAC，内核分配随机地址。真机上表现为有 IP、UP 但 ping 不通。用 `landscape-bridge-prep.service` 预建并固定 MAC 后恢复。

完整的踩坑清单见根目录 [AGENTS.md](../../AGENTS.md)。注意 AGENTS.md 是经验总结，不是证据。

### 运行时验证状态

以下已在真机刷写后实测（Hyper-V 桥接，单网卡 `eth0`）：

- Web UI 可登录，`root`/`root`
- `br_lan` 建立成功，MAC 与 `eth0` 一致，`carrier: true`
- LAN 侧 DHCP / 路由 / DNS / metrics 服务均 `running`
- `br_lan` 拿到 `192.168.3.245/24`，`mode: Reachable`
- 抽查 17 个核心 API 端点全部 200
- LAN 设备能被 ARP 发现

尚未验证：WAN 上线后的 NAT/转发、eBPF 数据面实际转发、DHCP 服务端真实下发（当前环境已有其他 DHCP）、双网口场景、DNS 对外解析（无 WAN 时实测 SERVFAIL，属预期）。
