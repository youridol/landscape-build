# 手工铺 Landscape 二进制，不用 lkit，不装 NetworkManager

Landscape 以预编译二进制 + `static.zip` 的形式随 GitHub release 发布，配套一个自写 systemd unit。不使用 lkit 安装器，因为它的全部安装动作发生在**运行时**，而本项目的 CI 不启动 ISO，那段代码永远无法验证，风险会留到用户刷机那一刻。镜像里不装 NetworkManager（releng 默认也没有），并且 mask `systemd-networkd`，把网卡独占权交给 Landscape。

## 依据

发布资产清单（v0.28.0）：`landscape-webserver-{x86_64,aarch64,riscv64,loongarch64,s390x}` 及 `-static` 变体、`redirect_pkg_handler-*`、`static.zip`、`SHASUM256sum.txt`
— <https://github.com/ThisSeanZhang/landscape/releases/expanded_assets/v0.28.0>

官方 systemd unit 模板：

```
[Service]
ExecStart=/root/landscape-webserver
Restart=always
User=root
LimitMEMLOCK=infinity
```

— <https://github.com/ThisSeanZhang/landscape>

`LimitMEMLOCK=infinity` 为硬性要求：

> `RLIMIT_MEMLOCK` 由 install 通过 systemd unit 的 `LimitMEMLOCK=infinity` 保证 ... install 必须确保该配置存在，否则 Landscape 的 eBPF 加载可能失败。

— <https://github.com/landscape-router/landscape-kit/blob/main/docs/check.md>

NetworkManager 指引（只有一句，且是"避免安装"而非"必须卸载"）：

> Avoid installing NetworkManager.

— <https://landscape.whileaway.dev/intro/requirements>

releng 的 `packages.x86_64` 实测不含 `networkmanager`，故本决策是"不得添加"，不存在删除动作。

网络管理器冲突（`systemd-networkd` 亦在拒绝之列）：

> 不受支持的活动网络管理器（`systemd-networkd`、wicked 或 connman），或 SELinux 已加载/配置为 enabled/permissive 时，在停止服务前失败。

— <https://github.com/landscape-router/landscape-kit/blob/main/docs/network/takeover.md>

Landscape 独占 DNS 端口：

> Run `ss -lutp` and check whether another DNS service is already listening on port `53`. Landscape cannot start its DNS service while that port is in use.

— <https://landscape.whileaway.dev/intro/manual-deployment>

## 关于 `systemd-resolved` 的事实纠正

用户原意是"从 `packages.x86_64` 删掉 `systemd-resolved`"。核查后该包不存在：`systemd-resolved` 的二进制与 service 文件属于 `systemd` 包（`usr/lib/systemd/systemd-resolved`、`usr/lib/systemd/system/systemd-resolved.service`、`etc/systemd/resolved.conf`），而 `systemd` 不可移除。独立存在的只有 `systemd-resolvconf`（core，`262.1-1`，3.4 KB，描述 "systemd resolvconf replacement (for use with systemd-resolved)"）。

因此落实为：**不安装 `systemd-resolvconf`，且对 `systemd-resolved.service` 执行 stop + disable + mask**。二进制仍在盘上，但永不启动。效果与用户意图一致（无兜底 DNS），机制不同。

— <https://archlinux.org/packages/core/x86_64/systemd/files/json/>

## 被否决的方案

**lkit 安装器**：官方推荐路径，但安装动作（`lkit --non-interactive install`）在运行时执行，CI 无法验证。

**容器镜像**：路由器本体无官方镜像。`ghcr.io/thisseanzhang/landscape` 与 `ghcr.io/landscape-router/landscape` 均 403/404；Docker Hub `thisseanzhang/landscape` 仅有两个 `build_base*` 镜像，为 CI 基底而非产品。

**源码编译**：官方已发预编译二进制，无必要引入 Rust 工具链与不可控构建时长。

## 后果

- `LimitMEMLOCK=infinity` 缺失会导致 eBPF 程序加载失败，unit 必须逐字包含该项。
- mask `systemd-networkd` 后，装好的系统首次开机完全无网，必须把电脑接到 LAN 口访问。
- Landscape 启动时会把 `/etc/resolv.conf` 改为 `127.0.0.1`，故该文件在目标系统中必须可写。
