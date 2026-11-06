#!/usr/bin/env bash
# Landscape 路由器无人值守安装脚本
# 由 kernel cmdline 的 script=/root/install.sh 触发（ADR-0001）

set -euo pipefail

LOG=/tmp/install.log
exec > >(tee -a "${LOG}") 2>&1

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fatal() { printf '\033[1;31m!!!\033[0m %s\n' "$*"; exit 1; }

info "Landscape 路由器安装开始"

# ---------------------------------------------------------------------------
# 1. 等待 live 环境就绪
# ---------------------------------------------------------------------------
info "等待 systemd 启动完成"
systemctl is-system-running --wait || true

# ---------------------------------------------------------------------------
# 2. 选择目标盘（ADR-0001：显式规则，候选不唯一即中止）
# ---------------------------------------------------------------------------
info "识别装机介质与候选目标盘"

# 装机介质 = 承载 ISO 的分区所在磁盘
BOOT_SRC="$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
[[ -n "${BOOT_SRC}" ]] || fatal "无法定位装机介质（/run/archiso/bootmnt 未挂载）"

BOOT_DISK_NAME="$(lsblk -no pkname "${BOOT_SRC}" 2>/dev/null | head -1 || true)"
[[ -n "${BOOT_DISK_NAME}" ]] || fatal "无法从 ${BOOT_SRC} 解析出所属磁盘"
BOOT_DISK="/dev/${BOOT_DISK_NAME}"
info "装机介质所在盘：${BOOT_DISK}"

# 候选 = 所有物理磁盘 - 装机介质 - 已挂载盘
declare -a CANDIDATES=()
while read -r name type rm; do
    [[ "${type}" == "disk" ]] || continue
    [[ "${rm}" == "1" ]] && continue
    dev="/dev/${name}"
    [[ "${dev}" == "${BOOT_DISK}" ]] && continue
    # 排除任何已被挂载的设备
    if lsblk -no MOUNTPOINT "${dev}" | grep -qv '^$'; then
        continue
    fi
    CANDIDATES+=("${dev}")
done < <(lsblk -dn -o NAME,TYPE,RM)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    fatal "未找到可用的目标盘。请确认目标机除 U 盘外还有一块磁盘。"
elif [[ ${#CANDIDATES[@]} -gt 1 ]]; then
    printf '\033[1;31m!!!\033[0m 找到多个候选目标盘，拒绝猜测：\n' >&2
    for c in "${CANDIDATES[@]}"; do
        printf '    %s  (%s, %s)\n' \
            "${c}" \
            "$(lsblk -dno SIZE "${c}")" \
            "$(lsblk -dno MODEL "${c}" | tr -s ' ')" >&2
    done
    fatal "请手工指定目标盘后重试。"
fi

TARGET_DISK="${CANDIDATES[0]}"
info "目标盘：${TARGET_DISK} ($(lsblk -dno SIZE "${TARGET_DISK}"), $(lsblk -dno MODEL "${TARGET_DISK}" | tr -s ' '))"

# 二次确认：目标盘不得是装机介质
[[ "${TARGET_DISK}" != "${BOOT_DISK}" ]] || fatal "目标盘与装机介质相同，中止以免擦除 U 盘"

# ---------------------------------------------------------------------------
# 3. 局域网直连提示（无 live 环境，无交互，仅打印）
# ---------------------------------------------------------------------------
info "安装期间请保持目标机与操作机在同一链路的 LAN 口直连"
info "安装完成后首次访问地址：https://192.168.5.1:6443"

# ---------------------------------------------------------------------------
# 4. 切换 pacman 到本地静态仓库（ADR-0004）
# ---------------------------------------------------------------------------
info "切换到本地静态仓库 /opt/localrepo"

if [[ ! -f /opt/localrepo/custom.db.tar.gz && ! -f /opt/localrepo/custom.db.tar.zst ]]; then
    fatal "本地仓库缺失：/opt/localrepo/custom.db.tar.* 不存在。构建阶段未正确生成仓库。"
fi

cat > /etc/pacman.conf <<'PACMAN_EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[localrepo]
SigLevel = Optional TrustAll
Server = file:///opt/localrepo
PACMAN_EOF

# archiso 会清空 var/lib/pacman，需重建
mkdir -p /var/lib/pacman
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

info "本地仓库可用性检查"
pacman -Sy --noconfirm >/dev/null || fatal "无法从本地仓库同步数据库"
pacman -Si landscape-webserver >/dev/null 2>&1 || \
  info "警告：本地仓库中没有 landscape-webserver（由 airootfs 直接提供，非包形式）"

# ---------------------------------------------------------------------------
# 5. 生成 archinstall 配置
# ---------------------------------------------------------------------------
info "生成 archinstall 配置"

# 密码哈希：默认 root/root（与 Landscape 默认一致）
ROOT_HASH="$(openssl passwd -6 root)"

# 引导器：BIOS 必须 grub；UEFI 也用 grub 以保持行为一致
# archinstall 在 BIOS 下自动用 MBR，UEFI 下用 GPT（device_handler.py:49）
BOOTLOADER="Grub"

python3 - "$TARGET_DISK" <<'PYGEN'
import json, subprocess, sys

disk = sys.argv[1]

# 磁盘实际大小（字节），留 1 GiB 余量给分区表与对齐
out = subprocess.run(['lsblk','-dbno','SIZE',disk], capture_output=True, text=True, check=True)
disk_bytes = int(out.stdout.strip())
boot_mib = 1024
boot_bytes = boot_mib * 1024 * 1024
root_bytes = disk_bytes - boot_bytes - (1024*1024*1024)
if root_bytes <= 0:
    sys.exit(f'{disk} 太小，剩余空间不足')

def size(value, unit):
    return {"value": value, "unit": unit,
            "sector_size": {"value": 512, "unit": "B"}}

cfg = {
  "archinstall-language": "English",
  "audio_config": None,
  "bootloader_config": {"bootloader": "Grub", "uki": False, "removable": False},
  "debug": False,
  "disk_config": {
    "config_type": "manual_partitioning",
    "device_modifications": [{
      "device": disk,
      "wipe": True,
      "partitions": [
        {
          "status": "create", "type": "primary",
          "start": size(1, "MiB"),
          "length": size(boot_mib, "MiB"),
          "fs_type": "fat32",
          "mountpoint": "/boot",
          "mount_options": [],
          "flags": ["boot", "esp"],
          "btrfs": [], "dev_path": None,
          "obj_id": "00000000-0000-4000-8000-000000000001"
        },
        {
          "status": "create", "type": "primary",
          "start": size(1 + boot_mib, "MiB"),
          "length": size(root_bytes, "B"),
          "fs_type": "ext4",
          "mountpoint": "/",
          "mount_options": [],
          "flags": [],
          "btrfs": [], "dev_path": None,
          "obj_id": "00000000-0000-4000-8000-000000000002"
        }
      ]
    }]
  },
  "hostname": "landscape",
  "kernels": ["linux"],
  "locale_config": {"kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US"},
  "mirror_config": {"custom_servers": [], "mirror_regions": {}},
  "network_config": {"type": "manual", "nics": []},
  "no_pkg_lookups": True,
  "ntp": False,
  "offline": True,
  "packages": [
    "base", "linux", "linux-firmware", "mkinitcpio", "sudo", "openssh",
    "iproute2", "procps-ng", "ppp", "grub", "efibootmgr", "dosfstools",
    "e2fsprogs", "bpf", "tcpdump", "ethtool", "iputils", "curl", "jq",
    "vim", "zsh", "parted", "gptfdisk"
  ],
  "pacman_config": {"color": False, "parallel_downloads": 5},
  "profile_config": None,
  "script": "minimal",
  "silent": True,
  "swap": {"enabled": False},
  "timezone": "Asia/Shanghai",
  "version": "4.5"
}

with open('/tmp/config.json','w') as f:
    json.dump(cfg, f, indent=2)
print(f'目标盘 {disk}: {disk_bytes} 字节, root 分区 {root_bytes} 字节')
PYGEN

[[ -s /tmp/config.json ]] || fatal "archinstall 配置生成失败"

ROOT_HASH="$(openssl passwd -6 "${ROOT_PASSWORD:-root}")"
[[ -n "${ROOT_HASH}" ]] || fatal "root 密码哈希生成失败"

cat > /tmp/creds.json <<CREDS_EOF
{
    "users": [],
    "root_enc_password": "${ROOT_HASH}"
}
CREDS_EOF

python3 -c "import json; json.load(open('/tmp/creds.json'))" || fatal "creds.json 非法"

cat > /tmp/creds.json <<JSON_EOF
{
    "users": [],
    "root_enc_password": "${ROOT_HASH}"
}
JSON_EOF

python3 -c "import json; json.load(open('/tmp/config.json')); json.load(open('/tmp/creds.json'))" \
    || fatal "生成的 archinstall 配置不是合法 JSON"

# ---------------------------------------------------------------------------
# 6. 执行安装
# ---------------------------------------------------------------------------
info "开始安装到 ${TARGET_DISK}"

archinstall \
    --config /tmp/config.json \
    --creds /tmp/creds.json \
    --silent \
    --offline \
    || fatal "archinstall 失败，详见 ${LOG}"

info "archinstall 完成"

# ---------------------------------------------------------------------------
# 7. 安装后置：恢复正式镜像源（ADR-0004）
# ---------------------------------------------------------------------------
info "恢复目标系统的标准 pacman 配置"

cat > /mnt/etc/pacman.conf <<'PACMAN_EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
PACMAN_EOF

# ---------------------------------------------------------------------------
# 8. 部署 Landscape（ADR-0002）
# ---------------------------------------------------------------------------
info "部署 Landscape 到目标系统"

install -d -m 0755 /mnt/opt/landscape
cp -a /opt/landscape/. /mnt/opt/landscape/

# 二进制
if [[ -f /opt/landscape/landscape-webserver ]]; then
    install -m 0755 /opt/landscape/landscape-webserver /mnt/usr/local/bin/landscape-webserver
else
    fatal "缺少 landscape-webserver 二进制"
fi

# 静态资源
if [[ -d /opt/landscape/static ]]; then
    install -d -m 0755 /mnt/opt/landscape/static
    cp -a /opt/landscape/static/. /mnt/opt/landscape/static/
else
    fatal "缺少 Landscape static 资源"
fi

# systemd unit（含 LimitMEMLOCK=infinity，硬性要求）
cat > /mnt/etc/systemd/system/landscape.service <<'UNIT_EOF'
[Unit]
Description=Landscape Router
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
Environment=LANDSCAPE_CONF_PATH=/root/.landscape-router
Environment=LANDSCAPE_WEB_ROOT=/opt/landscape/static
Environment=DATABASE_URL=sqlite:///root/.landscape-router/landscape_db.sqlite
ExecStart=/usr/local/bin/landscape-webserver
Restart=always
RestartSec=3
LimitMEMLOCK=infinity
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT_EOF

# 配置目录
install -d -m 0750 /mnt/root/.landscape-router

# 启用 Landscape
ln -sf /etc/systemd/system/landscape.service \
       /mnt/etc/systemd/system/multi-user.target.wants/landscape.service

# ---------------------------------------------------------------------------
# 9. 屏蔽与 Landscape 冲突的服务（ADR-0002）
# ---------------------------------------------------------------------------
info "屏蔽冲突服务"

# systemd-networkd：由 Landscape 接管网卡
ln -sf /dev/null /mnt/etc/systemd/system/systemd-networkd.service
ln -sf /dev/null /mnt/etc/systemd/system/systemd-networkd.socket
# systemd-resolved：Landscape 独占 53 端口
ln -sf /dev/null /mnt/etc/systemd/system/systemd-resolved.service

# 移除 releng 留下的启用符号链接
rm -f /mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
rm -f /mnt/etc/systemd/system/multi-user.target.wants/systemd-resolved.service
rm -f /mnt/etc/systemd/system/sockets.target.wants/systemd-networkd.socket
rm -f /mnt/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service

# /etc/resolv.conf 必须可写（Landscape 会写入 127.0.0.1）
rm -f /mnt/etc/resolv.conf
printf 'nameserver 127.0.0.1\n' > /mnt/etc/resolv.conf

# ---------------------------------------------------------------------------
# 10. 内核参数：确保 bpffs 自动挂载
# ---------------------------------------------------------------------------
info "配置内核参数"

install -d -m 0755 /mnt/etc/systemd/system/systemd-networkd.service.d 2>/dev/null || true

# systemd 会自动挂载 /sys/fs/bpf，无需 fstab

# ---------------------------------------------------------------------------
# 11. 收尾
# ---------------------------------------------------------------------------
info "同步并卸载"

sync
umount -R /mnt 2>/dev/null || true

info "安装完成。请移除 U 盘后重启。"
info "首次访问：https://192.168.5.1:6443 （账号 root / root）"
info "把电脑接到目标机的 LAN 口。"

# 阻止后续重试
touch /tmp/install-done

exit 0
