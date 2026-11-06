# AGENTS.md

> **本文件是经验总结，不是证据。**
> 内容来自历史调试过程，可能已过期。任何结论都必须用当前代码、构建产物或运行时行为重新取证。
> 与本文件冲突时，以实际取证为准。不确定就写"不确定"，不要据本文件推断。

## 项目是什么

把 [Landscape](https://github.com/ThisSeanZhang/landscape)（Rust 写的路由器系统）打包成 archiso 安装 ISO。U 盘启动 → 无人值守装到目标盘 → 重启后是一台路由器。

## 关键文件

| 路径 | 作用 |
|---|---|
| `profile/` | archiso profile，基线来自 archiso releng 裁剪 |
| `profile/airootfs/root/install.sh` | 无人值守安装脚本，ISO 启动后自动执行 |
| `ci/build-in-container.sh` | 容器内构建：拉二进制、建本地仓库、mkarchiso、静态验证 |
| `.github/workflows/build-iso.yml` | CI 入口，产物发到 Release `iso-latest` |
| `docs/adr/` | 决策记录，含否决方案与依据 |

## 构建

CI 触发：push 到 master，或手动 `workflow_dispatch`。

```bash
docker run --privileged --rm -v "$PWD:/work" \
  -e LANDSCAPE_VERSION=0.28.0 archlinux:latest \
  bash /work/ci/build-in-container.sh
```

本地构建未经验证。CI 用 `ubuntu-latest` + `archlinux:latest`。
`--privileged` 从未做过对照测试，不加能否成功未知；保留它是为了排除容器内 unshare 的不确定性。

产物：`landscape-router-<时间戳>-<短sha>.iso`，同时生成 `.sha256`。

## 已验证的事实

分两类。**运行时**指真机刷写后通过 API 或系统命令观察到的；**构建期**指 CI 对产物做的静态检查，不代表运行时行为。

### 运行时（2026-11-06，Hyper-V 桥接，单网卡 `eth0`，两次独立复测结果一致）

- Web UI 可登录：`POST /api/auth/login`，账号 `root`/`root`，返回 JWT
- 抽查 17 个核心端点全部 200；另一轮抽查 52 个只读端点，51 个 200，1 个（`dns/service/check`）400 因缺必填参数 `flow_id`，属正常
- `br_lan` 建立成功，MAC 与 `eth0` 一致，`carrier: true`
- `br_lan` 拿到 `192.168.3.245/24`，`mode: Reachable`
- LAN 侧 DHCP、路由、DNS、metrics 服务均 `running`
- LAN 设备能被 ARP 发现（复测两次分别 16、18 台，数量随环境变化，不是固定值）
- 进程 RSS 约 128 MB

### 构建期（CI 静态检查，不启动 ISO）

- 内核配置断言 19 项通过（`REQ_Y` 15 项要求 `=y`，`REQ_ANYM` 4 项接受 `=y`/`=m`）
- `.BTF` section 存在
- Landscape 二进制与 `static.zip` 的 SHA256 与官方 release 一致

### 未验证

- WAN 上线后的 NAT / 转发 / 实际出网
- eBPF 数据面真实转发效果（`xdp_redirect_able` 在无 WAN 时恒为 `false`）
- DHCP 服务端真实下发（当前环境已有别的 DHCP，设备均 `source=arp`）
- 双网口 WAN/LAN 场景
- DNS 对外解析（无 WAN 时实测 `SERVFAIL`，属预期）

## 踩过的坑（每条都有实测依据）

**1. `DATABASE_URL` 会让数据库建不出来**

systemd unit 里写 `DATABASE_URL=sqlite:///...` 导致 `SqliteError code 14: unable to open database file`，重试 5 次后失败。去掉该变量、只用 `LANDSCAPE_CONF_PATH` 即可。

**2. `landscape_init.toml` 与 `--auto` 互斥**

存在 toml 时 `--auto` 被跳过。toml 走 `truncate_and_fit_from` **整体替换**数据库，必须给全 网桥/成员网卡/DHCP/RouteLAN 四段。`version` 字段必须精确等于二进制版本，否则启动拒绝。

**3. 网桥 MAC 与物理网卡不一致会导致不通**

`init_devs` 建 `br_lan` 时不给 MAC，内核分配随机地址。实测内核不会让网桥继承从属口的 MAC（建桥、up、加入从属口，三步 MAC 均不变）。

真机上表现为 `br_lan` 有 IP 且 UP，但 ping 不通。预建网桥并 `ip link set address <物理网卡 MAC>` 后恢复。`landscape-bridge-prep.service` 负责这一步。

注意：为何设置 MAC 后就好了，机制未确证。可能与该虚拟交换机的源 MAC 过滤有关，未做对照实验。

**4. archinstall 写死 `linux-firmware`**

`installer.py` 的 `__packages__` 含 `linux-firmware` 及其 12 个依赖子包，无法通过配置移除。本地仓库必须提供完整依赖闭包，否则 `pacstrap` 报 `target not found`。

**5. `pacman -Syw` 在构建机会漏包**

容器已装的包（`gzip`/`systemd`/`kmod` 等）被认为依赖已满足而不下载，导致仓库闭包不完整。必须用 `--sysroot` 指向干净 root 解析。注意 `--sysroot` 会 prepend 到 `--config`，需给 root 内路径 `/etc/pacman.conf`。

**6. `mkarchiso` 清空 `/boot`**

`_cleanup_pacstrap_dir()` 删除 airootfs 的 `/boot` 内容，内核实际位于 ISO 的 `arch/boot/x86_64/`。验证脚本别在 rootfs 里找 `vmlinuz`。

**7. `vmlinuz` 是压缩的 bzImage**

直接搜 `IKCFG_ST` 找不到，必须先按 magic 解压再取配置。`.BTF` 同理。

**8. `airootfs` 拷贝不保留权限**

`cp -af --no-preserve=ownership,mode` 会重置权限，可执行文件需在 `profiledef.sh` 的 `file_permissions` 显式列出。

**9. `archinstall` 的 `script` 值决定执行路径**

`script: "minimal"` 会加载开发示例脚本，强制 `add_bootloader(Systemd)` 并忽略配置里的 bootloader/hostname。`systemd-boot` 只支持 UEFI，实测 BIOS 机器上装出的盘报 `Boot failure`。用 `guided`。

**10. `PartitionModification` 的 JSON 键是 `size`**

不是 dataclass 字段名 `length`。分区长度还必须按 1 MiB 对齐，且 `start + size` 不能超出磁盘。

## 改代码时注意

- `profile/airootfs/` 里的文件权限靠 `profiledef.sh` 的 `file_permissions`，不靠文件本身
- 控制台无 CJK 字形，`motd` 与脚本输出只用 ASCII
- `install.sh` 不用 `set -e`，每步显式判断退出码；新增步骤同样要检查
- 包清单有三处，**职责不同，不是三份副本**：
  - `profile/packages.x86_64` — live 环境装什么（当前不含 `linux-firmware`）
  - `ci/build-in-container.sh` 的 `TARGET_PKGS` — 本地仓库要有哪些包（当前含 `linux-firmware` 全量）
  - `install.sh` 的 `packages` — 装到目标盘的额外包（`base`/`linux`/`linux-firmware` 由 archinstall 硬编码，此处不列）

  改任一处都要检查另外两处是否需要跟着动，但三者不必相同。
- 固件裁剪开关 `TRIM_FIRMWARE` 默认 `0`（关闭），改 `1` 才执行

## 改代码或验证后必须同步文档

任何代码修改、依赖变更、重新构建或真机验证之后，**同一次提交内**更新下列文档。不允许"稍后补"。

检查清单：

1. **AGENTS.md** — 若行为、命令、路径、约束、已验证/未验证边界发生变化，逐条改。踩坑清单新增或修正。
2. **docs/adr/README.md** — 产物参数（文件名格式、大小、校验方式）、静态检查项、运行时验证状态。
3. **docs/adr/000*.md** — 若某条决策被推翻或修订，改原文或标注 `superseded by ADR-NNNN`。不要留与现状矛盾的内容。
4. **GLOSSARY.md** — 术语定义若与实现不符，改定义。

判断是否"过期"的标准：把文档里的每一句当成断言，问「现在还是这样吗」。答不上来就去查代码、产物或运行时；查不到就把该断言删掉或标为未验证。

明确不要做的：

- 不要为了让文档好看而保留旧数字。过期的精确数字比模糊描述更危险。
- 不要把"曾经验证过"写成"已验证"。验证有时间点和条件，环境变了就失效。
- 不确定的事实写成"不确定"或删掉，不要补一个看起来合理的值。

## 验证方式

CI 只做静态验证，**不启动 ISO**：解 squashfs → 查文件 → 从 `vmlinuz` 抽内核配置断言 → 查 `.BTF` section。

运行时的正确性只能靠刷机。安装脚本把全流程 tee 到 `/tmp/install.log`，失败时先看它。

刷机后如需验证网络，在目标机执行：

```bash
ip -br addr
ip link show master br_lan
ip link show br_lan | grep link/ether    # 应与 eth0 一致
journalctl -u landscape -n 50
```

再通过 API 确认（`POST /api/auth/login` 取 token 后）：

```bash
curl -sk -H "Authorization: Bearer $TOKEN" https://192.168.3.245:6443/api/v1/services/routing/status
curl -sk -H "Authorization: Bearer $TOKEN" https://192.168.3.245:6443/api/v1/services/dhcp_v4/status
```
