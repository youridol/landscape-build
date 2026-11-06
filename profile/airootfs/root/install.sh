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

# 候选盘筛选规则：
#   - 类型必须是 disk
#   - 排除装机介质自身
#   - 排除 /dev/fd*（软驱）、loop、ram、zram、sr（光驱）
#   - 容量必须 >= 4 GiB（软驱 4K、光驱、各种虚拟设备都会被这条挡掉）
MIN_BYTES=$((4 * 1024 * 1024 * 1024))

declare -a CANDIDATES=()
declare -a CAND_BYTES=()
declare -a CAND_DESC=()

while read -r name type size; do
    [[ "${type}" == "disk" ]] || continue
    case "${name}" in
        fd*|loop*|ram*|zram*|sr*) continue ;;
    esac
    dev="/dev/${name}"
    [[ "${dev}" == "${BOOT_DISK}" ]] && continue
    # size 是 lsblk 的字节数
    if [[ -z "${size}" || "${size}" -lt "${MIN_BYTES}" ]]; then
        continue
    fi
    CANDIDATES+=("${dev}")
    CAND_BYTES+=("${size}")
    CAND_DESC+=("$(lsblk -dno SIZE "${dev}" 2>/dev/null) $(lsblk -dno MODEL "${dev}" 2>/dev/null | tr -s ' ' | sed 's/^ *//')")
done < <(lsblk -dno NAME,TYPE,SIZE 2>/dev/null)

# 允许用内核参数显式指定目标盘，跳过所有推断
CMDLINE_TARGET=""
for p in $(</proc/cmdline); do
    case "${p}" in
        target=*) CMDLINE_TARGET="${p#target=}" ;;
    esac
done

if [[ -n "${CMDLINE_TARGET}" ]]; then
    if [[ -b "${CMDLINE_TARGET}" ]]; then
        TARGET_DISK="${CMDLINE_TARGET}"
        ok "Target disk from kernel cmdline: ${TARGET_DISK}"
    else
        fatal "Kernel cmdline target=${CMDLINE_TARGET} is not a block device"
    fi
elif [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo ""
    echo "No usable target disk. All block devices:"
    lsblk -dno NAME,TYPE,SIZE,MODEL 2>/dev/null || true
    echo ""
    fatal "No disk >= 4 GiB besides the install medium."
elif [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    TARGET_DISK="${CANDIDATES[0]}"
    ok "Single candidate: ${TARGET_DISK}"
else
    # 多于一个候选：有终端就让人选，没有就中止
    echo ""
    echo "Multiple disks could be the target:"
    echo ""
    i=0
    for c in "${CANDIDATES[@]}"; do
        i=$((i + 1))
        printf '  [%d] %-14s %s\n' "${i}" "${c}" "${CAND_DESC[$((i - 1))]}"
    done
    echo ""

    # 只有真的能从一个终端读输入时才提示；否则直接失败并给出 cmdline 办法。
    # 注意：不能用 "-e /dev/tty" 当条件，那个文件几乎总是存在，等于没判断。
    if [[ -c /dev/tty ]] && { [[ -t 0 ]] || [[ -t 1 ]] || [[ -t 2 ]]; }; then
        TARGET_DISK=""
        for _attempt in 1 2 3; do
            printf 'Select target disk [1-%d] (this disk will be ERASED): ' "${#CANDIDATES[@]}"
            read -r _choice < /dev/tty || _choice=""
            if [[ "${_choice}" =~ ^[0-9]+$ ]] \
               && [[ "${_choice}" -ge 1 ]] \
               && [[ "${_choice}" -le ${#CANDIDATES[@]} ]]; then
                TARGET_DISK="${CANDIDATES[$((_choice - 1))]}"
                break
            fi
            printf 'Invalid input: %s\n' "${_choice:-<empty>}"
        done
        [[ -n "${TARGET_DISK}" ]] || fatal "No valid selection after 3 attempts."
        ok "Target disk selected: ${TARGET_DISK}"
    else
        fatal "Multiple candidate disks and no terminal to choose from. Set target=/dev/xxx on the kernel cmdline."
    fi
fi

TARGET_BYTES="$(lsblk -dbno SIZE "${TARGET_DISK}" 2>/dev/null || echo 0)"
if [[ -z "${TARGET_BYTES}" || "${TARGET_BYTES}" -lt "${MIN_BYTES}" ]]; then
    fatal "Target disk ${TARGET_DISK} is smaller than 4 GiB or unreadable"
fi
# 二次确认：绝不能是装机介质
if [[ "${TARGET_DISK}" == "${BOOT_DISK}" ]]; then
    fatal "Target disk equals the install medium; aborting to avoid erasing it"
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
