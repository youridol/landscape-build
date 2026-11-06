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

# 注意：lsblk 的 SIZE 默认带单位（60G / 1.4T），不能直接做数值比较。
# 必须用 -b（bytes）取值，否则 [[ ... -lt ... ]] 会报
# "value too great for base" 并让判断失效。
while read -r name type; do
    [[ "${type}" == "disk" ]] || continue
    case "${name}" in
        fd*|loop*|ram*|zram*|sr*) continue ;;
    esac
    dev="/dev/${name}"
    [[ "${dev}" == "${BOOT_DISK}" ]] && continue
    size="$(lsblk -dbno SIZE "${dev}" 2>/dev/null || echo 0)"
    if [[ -z "${size}" || ! "${size}" =~ ^[0-9]+$ || "${size}" -lt "${MIN_BYTES}" ]]; then
        continue
    fi
    CANDIDATES+=("${dev}")
    CAND_BYTES+=("${size}")
    CAND_DESC+=("$(lsblk -dno SIZE "${dev}" 2>/dev/null) $(lsblk -dno MODEL "${dev}" 2>/dev/null | tr -s ' ' | sed 's/^ *//')")
done < <(lsblk -dno NAME,TYPE 2>/dev/null)

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

# 段落名必须与数据库文件名一致：pacman 会去找 <段名>.db。
# 这里的数据库是 custom.db.tar.gz，所以段落必须叫 [custom]。
[custom]
SigLevel = Optional TrustAll
Server = file:///opt/localrepo
PACMAN_EOF

mkdir -p /var/lib/pacman
pacman-key --init >/dev/null 2>&1 || warn "pacman-key --init failed (continuing)"
pacman-key --populate archlinux >/dev/null 2>&1 || warn "pacman-key --populate failed (continuing)"

if ! pacman -Sy --noconfirm > /tmp/pacman-sync.log 2>&1; then
    echo "--- pacman -Sy output ---"
    cat /tmp/pacman-sync.log
    echo "--- /etc/pacman.conf ---"
    cat /etc/pacman.conf
    echo "--- ${REPO} contents (first 20) ---"
    ls -la "${REPO}" | head -20
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
mib = 1024 * 1024
boot_bytes = boot_mib * mib
root_start_mib = 1 + boot_mib          # 1 MiB 对齐 + boot 分区
root_start_bytes = root_start_mib * mib
# 根分区从 root_start 开始，长度必须扣掉起始偏移，否则 end 会超出磁盘。
# 长度还必须按 1 MiB 对齐（archinstall 的 Size.align() 用 1 MiB），
# 否则 parse_arg 会 raise ValueError('Partition is misaligned')。
tail_reserve = 64 * mib
avail = disk_bytes - root_start_bytes - tail_reserve
if avail <= 0:
    sys.exit(f'{disk} too small')
root_mib = avail // mib              # 向下取整到 MiB
if root_mib <= 0:
    sys.exit(f'{disk} too small after alignment')

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
                 "start": size(1, "MiB"), "size": size(boot_mib, "MiB"),
                 "fs_type": "fat32", "mountpoint": "/boot", "mount_options": [],
                 "flags": ["boot", "esp"], "btrfs": [], "dev_path": None,
                 "obj_id": "00000000-0000-4000-8000-000000000001"},
                {"status": "create", "type": "primary",
                 "start": size(root_start_mib, "MiB"), "size": size(root_mib, "MiB"),
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
        # 阶段目标：先保证刷机成功。linux-firmware 由 archinstall
        # 强制安装（installer.py:75），这里只列额外需要的。
        "openssh",
        "iproute2", "procps-ng", "ppp", "grub", "efibootmgr", "dosfstools",
        "e2fsprogs", "bpf", "tcpdump", "ethtool", "iputils", "curl", "jq",
        "vim", "zsh", "parted", "gptfdisk", "openssl", "ca-certificates"
    ],
    "pacman_config": {"color": False, "parallel_downloads": 5},
    "profile_config": None,
    # 必须是 guided。minimal 是开发示例脚本，会强制使用
    # Systemd-boot 并忽略配置里的 bootloader/hostname/users，
    # 在 BIOS/MBR 上会装出一个无法引导的系统。
    "script": "guided",
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

# archinstall 返回 0 不代表目标系统还挂在 /mnt 上。
# 后续所有步骤都依赖 /mnt，必须在这里先验证，否则会静默写空。
if ! mountpoint -q /mnt; then
    warn "/mnt is not a mountpoint after install; trying to remount from the disk"
    ROOT_PART="$(lsblk -lnpo NAME,FSTYPE "${TARGET_DISK}" 2>/dev/null | awk '$2=="ext4"{print $1; exit}')"
    [[ -n "${ROOT_PART}" ]] || fatal "Cannot find the root partition on ${TARGET_DISK}"
    if ! mount "${ROOT_PART}" /mnt; then
        fatal "Cannot mount ${ROOT_PART} on /mnt after install"
    fi
fi

if [[ ! -d /mnt/etc ]] || [[ ! -f /mnt/etc/pacman.conf ]]; then
    echo "--- /mnt contents ---"
    ls -la /mnt 2>&1 | head -20
    fatal "/mnt does not contain an installed system"
fi
ok "Target system is mounted at /mnt"

# ---------------------------------------------------------------------------
# 5b. 裁剪目标系统的固件
# ---------------------------------------------------------------------------
# archinstall 把基础包写死为 base/sudo/linux-firmware/mkinitcpio
# （installer.py:75），linux-firmware 无法通过配置移除，其 12 个依赖
# 子包必须全部在本地仓库里，否则 pacstrap 报 target not found。
# 这里保留包本身（依赖关系与 pacman -Q 一致），只删掉用不到的固件文件。
# 注意：固件裁剪暂时停用，先保证刷机成功。
# 恢复体积优化时再打开下面这段。
# 固件裁剪开关：TRIM_FIRMWARE=1 才执行。
# 当前默认关闭，先保证刷机成功，体积优化留到后期。
TRIM_FIRMWARE="${TRIM_FIRMWARE:-0}"
FW=/mnt/usr/lib/firmware

if [[ "${TRIM_FIRMWARE}" != "1" ]]; then
    info "Firmware trimming disabled (TRIM_FIRMWARE=0); keeping full firmware"
elif [[ -d "${FW}" ]]; then
    info "Trimming unnecessary firmware files in the target system"
    BEFORE="$(du -sm "${FW}" 2>/dev/null | awk '{print $1}')"

    for d in \
        nvidia amdgpu radeon \
        ath10k ath11k ath12k ath6k ath9k \
        mediatek rtw88 rtw89 \
        mrvl mellanox qed qlogic liquidio nfp \
        brcm cirrus ti-connectivity
    do
        if [[ -e "${FW}/${d}" ]]; then
            rm -rf "${FW:?}/${d}"
        fi
    done

    AFTER="$(du -sm "${FW}" 2>/dev/null | awk '{print $1}')"
    ok "Firmware: ${BEFORE:-?} MiB -> ${AFTER:-?} MiB"
else
    warn "${FW} not found; skip firmware trimming"
fi

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

install -d -m 0755 /mnt/opt/landscape || fatal "Cannot create /mnt/opt/landscape"
[[ -f /opt/landscape/landscape-webserver ]] \
    || fatal "Missing /opt/landscape/landscape-webserver"
install -m 0755 /opt/landscape/landscape-webserver /mnt/usr/local/bin/landscape-webserver \
    || fatal "Cannot install landscape-webserver into target"

[[ -d /opt/landscape/static ]] || fatal "Missing /opt/landscape/static"
cp -a /opt/landscape/static /mnt/opt/landscape/static \
    || fatal "Cannot copy static assets into target"

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

install -d -m 0750 /mnt/root/.landscape-router || fatal "Cannot create Landscape config dir"

# ---------------------------------------------------------------------------
# 7b. 预置 landscape_init.toml：把 LAN 网段定成 192.168.3.245/24
# ---------------------------------------------------------------------------
# 默认 --auto 会建 br_lan 并把所有物理网卡挂进去，DHCP 服务端地址硬编码
# 为 192.168.5.1/24（landscape-common/src/lib.rs:148-150）。
# 用户内网已有 192.168.5.0/24，冲突。
#
# 注意：一旦存在 landscape_init.toml，--auto 会被跳过
# （landscape-webserver/src/main.rs:742 三重存在性判断），
# 而 toml 走 truncate_and_fit_from 整体替换数据库。
# 所以必须由 toml 自己给出网桥、成员网卡、DHCP、Route LAN 全套定义。
#
# 成员网卡名只能在安装现场探测，构建期无法预知。
LAN_IP="192.168.3.245"
LAN_MASK=24
LAN_START="192.168.3.100"
INIT_TOML=/mnt/root/.landscape-router/landscape_init.toml

install -d -m 0750 /mnt/root/.landscape-router

# 探测物理网卡：排除 lo、虚拟设备、无线
PHYS_IFACES="$(
    for n in /sys/class/net/*; do
        name="$(basename "$n")"
        [[ "$name" == "lo" ]] && continue
        [[ -d "$n/wireless" ]] && continue
        [[ -d "$n/bridge" ]] && continue
        [[ -e "$n/device" ]] || continue
        echo "$name"
    done
)"

if [[ -z "${PHYS_IFACES}" ]]; then
    # 不能静默跳过：跳过就等于回落到 --auto 的 192.168.5.1，
    # 会与用户内网冲突且没有任何提示。
    echo "--- /sys/class/net contents ---"
    ls -la /sys/class/net/ 2>&1
    echo "--- 每个条目的判定依据 ---"
    for n in /sys/class/net/*; do
        name="$(basename "$n")"
        printf '  %-12s wireless=%s bridge=%s device=%s\n' \
            "$name" \
            "$([[ -d "$n/wireless" ]] && echo yes || echo no)" \
            "$([[ -d "$n/bridge" ]] && echo yes || echo no)" \
            "$([[ -e "$n/device" ]] && echo yes || echo no)"
    done
    fatal "No physical interfaces detected; cannot generate landscape_init.toml"
else
    info "Physical interfaces: $(echo ${PHYS_IFACES} | tr '\n' ' ')"

    # version 必须与二进制自身版本完全一致，否则 boot_check 的
    # validate_init_config_version 会报 VersionMismatch 并拒绝启动
    # （landscape/src/boot/mod.rs:90-99）。
    # 从二进制里提取版本，避免与 CI 的 LANDSCAPE_VERSION 脱节。
    LAND_VER="$(/mnt/usr/local/bin/landscape-webserver --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "${LAND_VER}" ]]; then
        # 兜底：从 strings 里找 semver
        LAND_VER="$(strings /mnt/usr/local/bin/landscape-webserver 2>/dev/null \
            | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
    fi
    [[ -n "${LAND_VER}" ]] || fatal "Cannot determine Landscape version from the binary"
    info "Landscape version: ${LAND_VER}"

    {
        printf 'version = "%s"\n' "${LAND_VER}"
        echo
        # 网桥 br_lan
        echo '[[ifaces]]'
        echo 'name = "br_lan"'
        echo 'create_dev_type = "bridge"'
        echo 'zone_type = "lan"'
        echo 'enable_in_boot = true'
        echo 'wifi_mode = "undefined"'
        echo 'update_at = 0.0'
        echo

        # 每块物理网卡挂到 br_lan 下
        for i in ${PHYS_IFACES}; do
            echo '[[ifaces]]'
            printf 'name = "%s"\n' "$i"
            echo 'create_dev_type = "no_need_to_create"'
            echo 'controller_name = "br_lan"'
            echo 'zone_type = "undefined"'
            echo 'enable_in_boot = true'
            echo 'wifi_mode = "undefined"'
            echo 'update_at = 0.0'
            echo
        done

        # DHCP 服务端：地址改到 192.168.3.245/24
        echo '[[dhcpv4_services]]'
        echo 'iface_name = "br_lan"'
        echo 'enable = true'
        echo 'update_at = 0.0'
        echo
        echo '[dhcpv4_services.config]'
        printf 'ip_range_start = "%s"\n' "${LAN_START}"
        printf 'server_ip_addr = "%s"\n' "${LAN_IP}"
        printf 'network_mask = %s\n' "${LAN_MASK}"
        echo 'address_lease_time = 86400'
        echo

        # LAN 路由转发
        echo '[[route_lans]]'
        echo 'iface_name = "br_lan"'
        echo 'enable = true'
        echo 'update_at = 0.0'
    } > "${INIT_TOML}" || fatal "Cannot write ${INIT_TOML}"

    # 写后自检：必须能解析、version 非空、包含目标地址
    python3 - "${INIT_TOML}" "${LAN_IP}" <<'PYVERIFY' || fatal "landscape_init.toml self-check failed"
import sys
toml_path, want_ip = sys.argv[1], sys.argv[2]

try:
    import tomllib
except ImportError:
    sys.exit('tomllib unavailable')

with open(toml_path, 'rb') as f:
    data = tomllib.load(f)

errs = []
if not data.get('version'):
    errs.append('version is empty')
ifaces = data.get('ifaces', [])
if not any(i.get('name') == 'br_lan' for i in ifaces):
    errs.append('no br_lan iface')
svcs = data.get('dhcpv4_services', [])
if not svcs:
    errs.append('no dhcpv4_services')
else:
    got = svcs[0].get('config', {}).get('server_ip_addr')
    if got != want_ip:
        errs.append(f'server_ip_addr is {got!r}, want {want_ip!r}')
if not data.get('route_lans'):
    errs.append('no route_lans')

if errs:
    sys.exit('; '.join(errs))
print(f'  OK  version={data["version"]}  ifaces={len(ifaces)}  lan={want_ip}')
PYVERIFY

    ok "landscape_init.toml written (LAN ${LAN_IP}/${LAN_MASK})"
fi
install -d -m 0755 /mnt/etc/systemd/system/multi-user.target.wants \
    || fatal "Cannot create multi-user.target.wants"
ln -sf /etc/systemd/system/landscape.service \
       /mnt/etc/systemd/system/multi-user.target.wants/landscape.service \
    || fatal "Cannot enable landscape.service"
ok "Landscape deployed"

# ---------------------------------------------------------------------------
# 8. 屏蔽与 Landscape 冲突的服务（ADR-0002）
# ---------------------------------------------------------------------------
info "Masking conflicting services"

# 目标系统里由 Landscape 独占网卡与 53 端口
install -d -m 0755 /mnt/etc/systemd/system \
    || fatal "Cannot create /mnt/etc/systemd/system"

for unit in systemd-networkd.service systemd-networkd.socket systemd-resolved.service; do
    ln -sf /dev/null "/mnt/etc/systemd/system/${unit}" \
        || fatal "Cannot mask ${unit}"
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
printf 'nameserver 127.0.0.1\n' > /mnt/etc/resolv.conf \
    || fatal "Cannot write /mnt/etc/resolv.conf"
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
printf '    URL : https://%s:6443\n' "${LAN_IP}"
echo "    User: root / root"
echo "    Plug your computer into a LAN port of the router."
echo ""

exit 0
