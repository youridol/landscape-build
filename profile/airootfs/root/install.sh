#!/usr/bin/env bash
# Landscape 路由器无人值守安装脚本
# 由 kernel cmdline 的 script=/root/install.sh 触发（ADR-0001）
#
# 控制台输出一律使用 ASCII：live 环境的 Linux 控制台没有中日韩字形，
# 打印中文会显示为方块。注释可以写中文。
#
# set -u 但不用 -e：home 部分需要自己判断每一步的结果再决定是否中止，
# 避免某个 subshell 的非零退出让整个脚本静默死掉。

set -uo pipefail

LOG=/tmp/install.log
exec > >(tee -a "${LOG}") 2>&1

info()  { printf '[ .. ] %s\n' "$*"; }
ok()    { printf '[ OK ] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*"; }
fatal() { printf '[FAIL] %s\n' "$*"; printf '[FAIL] Log: %s\n' "${LOG}"; exit 1; }

info "Landscape Router installer starting"

# ---------------------------------------------------------------------------
# 1. 等待 live 环境就绪
# ---------------------------------------------------------------------------
info "Waiting for systemd to settle"
systemctl is-system-running --wait 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. 选择目标盘
# ---------------------------------------------------------------------------
info "Detecting install medium and target disk"

BOOT_SRC="$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
if [[ -z "${BOOT_SRC}" ]]; then
    fatal "/run/archiso/bootmnt is not mounted; cannot locate the install medium"
fi

# 从光盘 /dev/sr0 启动时，bootmnt 的源本身就是整块设备，pkname 为空。
# 此时装机介质就是该设备；否则取其所属磁盘。
BOOT_DISK_NAME="$(lsblk -no pkname "${BOOT_SRC}" 2>/dev/null | head -1 || true)"
if [[ -n "${BOOT_DISK_NAME}" ]]; then
    BOOT_DISK="/dev/${BOOT_DISK_NAME}"
else
    BOOT_DISK="${BOOT_SRC}"
fi
info "Install medium device: ${BOOT_DISK} (source ${BOOT_SRC})"

# 候选 = 所有 disk 类型设备 - 装机介质
declare -a CANDIDATES=()
while read -r name type; do
    [[ "${type}" == "disk" ]] || continue
    dev="/dev/${name}"
    [[ "${dev}" == "${BOOT_DISK}" ]] && continue
    CANDIDATES+=("${dev}")
done < <(lsblk -dn -o NAME,TYPE 2>/dev/null)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "Visible block devices:"
    lsblk -dn -o NAME,TYPE,SIZE,MODEL 2>/dev/null || true
    fatal "No target disk found. Attach a disk besides the install medium."
elif [[ ${#CANDIDATES[@]} -gt 1 ]]; then
    echo "Multiple candidate disks found; refusing to guess:"
    for c in "${CANDIDATES[@]}"; do
        printf '    %-14s %-8s %s\n' \
            "${c}" \
            "$(lsblk -dno SIZE "${c}" 2>/dev/null)" \
            "$(lsblk -dno MODEL "${c}" 2>/dev/null | tr -s ' ')"
    done
    fatal "More than one candidate disk. Remove the extra disk and retry."
fi

TARGET_DISK="${CANDIDATES[0]}"
TARGET_BYTES="$(lsblk -dbno SIZE "${TARGET_DISK}" 2>/dev/null || echo 0)"
if [[ -z "${TARGET_BYTES}" || "${TARGET_BYTES}" -lt $((4*1024*1024*1024)) ]]; then
    fatal "Target disk ${TARGET_DISK} is smaller than 4 GiB or unreadable"
fi

ok "Target disk: ${TARGET_DISK} ($(numfmt --to=iec "${TARGET_BYTES}" 2>/dev/null || echo "${TARGET_BYTES}B"))"

# ---------------------------------------------------------------------------
# 3. 切换到本地静态仓库（ADR-0004）
# ---------------------------------------------------------------------------
info "Switching pacman to the bundled local repository"

REPO=/opt/localrepo
if [[ ! -f "${REPO}/custom.db.tar.gz" ]]; then
    fatal "Bundled repository missing at ${REPO}/custom.db.tar.gz"
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

mkdir -p /var/lib/pacman
pacman-key --init >/dev/null 2>&1 || warn "pacman-key --init failed (continuing)"
pacman-key --populate archlinux >/dev/null 2>&1 || warn "pacman-key --populate failed (continuing)"

if ! pacman -Sy --noconfirm >/dev/null 2>&1; then
    fatal "Cannot sync the bundled local repository"
fi
ok "Local repository ready"

# ---------------------------------------------------------------------------
# 4. 生成 archinstall 配置
# ---------------------------------------------------------------------------
info "Generating archinstall configuration"

ROOT_HASH="$(openssl passwd -6 "${ROOT_PASSWORD:-root}" 2>/dev/null || true)"
if [[ -z "${ROOT_HASH}" ]]; then
    fatal "Cannot hash the root password (openssl missing?)"
fi

python3 - "${TARGET_DISK}" > /tmp/config.json <<'PYGEN'
import json, subprocess, sys

disk = sys.argv[1]
out = subprocess.run(['lsblk', '-dbno', 'SIZE', disk], capture_output=True, text=True)
disk_bytes = int(out.stdout.strip())

boot_mib = 1024
boot_bytes = boot_mib * 1024 * 1024
reserve = 1024 * 1024 * 1024
root_bytes = disk_bytes - boot_bytes - reserve
if root_bytes <= 0:
    sys.exit(f'{disk} too small')

def size(v, u):
    return {"value": v, "unit": u, "sector_size": {"value": 512, "unit": "B"}}

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
                {"status": "create", "type": "primary",
                 "start": size(1, "MiB"), "length": size(boot_mib, "MiB"),
                 "fs_type": "fat32", "mountpoint": "/boot", "mount_options": [],
                 "flags": ["boot", "esp"], "btrfs": [], "dev_path": None,
                 "obj_id": "00000000-0000-4000-8000-000000000001"},
                {"status": "create", "type": "primary",
                 "start": size(1 + boot_mib, "MiB"), "length": size(root_bytes, "B"),
                 "fs_type": "ext4", "mountpoint": "/", "mount_options": [],
                 "flags": [], "btrfs": [], "dev_path": None,
                 "obj_id": "00000000-0000-4000-8000-000000000002"},
            ],
        }],
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
        "vim", "zsh", "parted", "gptfdisk", "openssl", "ca-certificates"
    ],
    "pacman_config": {"color": False, "parallel_downloads": 5},
    "profile_config": None,
    "script": "minimal",
    "silent": True,
    "swap": {"enabled": False},
    "timezone": "Asia/Shanghai",
    "version": "4.5",
}
json.dump(cfg, sys.stdout, indent=2)
PYGEN

[[ -s /tmp/config.json ]] || fatal "Failed to generate archinstall configuration"

cat > /tmp/creds.json <<CREDS_EOF
{
    "users": [],
    "root_enc_password": "${ROOT_HASH}"
}
CREDS_EOF

python3 -c "import json; json.load(open('/tmp/config.json')); json.load(open('/tmp/creds.json'))" \
    || fatal "Generated archinstall configuration is not valid JSON"
ok "Configuration generated"

# ---------------------------------------------------------------------------
# 5. 执行安装
# ---------------------------------------------------------------------------
info "Installing to ${TARGET_DISK} (this takes several minutes)"

if ! archinstall --config /tmp/config.json --creds /tmp/creds.json --silent --offline; then
    fatal "archinstall failed"
fi
ok "Base system installed"

# ---------------------------------------------------------------------------
# 6. 恢复正式镜像源（ADR-0004）
# ---------------------------------------------------------------------------
info "Restoring standard pacman configuration in the target system"

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
ok "pacman.conf restored"

# ---------------------------------------------------------------------------
# 7. 部署 Landscape（ADR-0002）
# ---------------------------------------------------------------------------
info "Deploying Landscape into the target system"

install -d -m 0755 /mnt/opt/landscape
[[ -f /opt/landscape/landscape-webserver ]] \
    || fatal "Missing /opt/landscape/landscape-webserver"
install -m 0755 /opt/landscape/landscape-webserver /mnt/usr/local/bin/landscape-webserver

[[ -d /opt/landscape/static ]] || fatal "Missing /opt/landscape/static"
cp -a /opt/landscape/static /mnt/opt/landscape/static

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

install -d -m 0750 /mnt/root/.landscape-router
ln -sf /etc/systemd/system/landscape.service \
       /mnt/etc/systemd/system/multi-user.target.wants/landscape.service
ok "Landscape deployed"

# ---------------------------------------------------------------------------
# 8. 屏蔽与 Landscape 冲突的服务（ADR-0002）
# ---------------------------------------------------------------------------
info "Masking conflicting services"

# 目标系统里由 Landscape 独占网卡与 53 端口
for unit in systemd-networkd.service systemd-networkd.socket systemd-resolved.service; do
    ln -sf /dev/null "/mnt/etc/systemd/system/${unit}"
done

for link in \
    /mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service \
    /mnt/etc/systemd/system/multi-user.target.wants/systemd-resolved.service \
    /mnt/etc/systemd/system/sockets.target.wants/systemd-networkd.socket \
    /mnt/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service \
    /mnt/etc/systemd/system/dbus-org.freedesktop.network1.service \
    /mnt/etc/systemd/system/dbus-org.freedesktop.resolve1.service
do
    rm -f "${link}"
done

# Landscape 启动时会改写此文件，必须存在且可写
rm -f /mnt/etc/resolv.conf
printf 'nameserver 127.0.0.1\n' > /mnt/etc/resolv.conf
ok "Conflicting services masked"

# ---------------------------------------------------------------------------
# 9. 收尾
# ---------------------------------------------------------------------------
info "Syncing and unmounting"
sync
umount -R /mnt 2>/dev/null || true

ok "Installation finished"
echo ""
echo "  Remove the install medium and reboot."
echo ""
echo "  First access once the router boots:"
echo "    URL : https://192.168.5.1:6443"
echo "    User: root / root"
echo "    Plug your computer into a LAN port of the router."
echo ""

exit 0
