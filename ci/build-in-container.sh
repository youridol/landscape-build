#!/usr/bin/env bash
# 在 archlinux 容器内执行：准备本地仓库、构建 ISO、静态验证产物
# 由 .github/workflows/build-iso.yml 调用
# 不启动 ISO（约束：CI 只编译与静态验证）

set -euo pipefail

WORK=/work
PROFILE="${WORK}/profile"
OUT="${WORK}/out"
STAGE="${WORK}/.pkgstage"
DL="${WORK}/.landscape"
VERSION="${LANDSCAPE_VERSION:-0.28.0}"

# 目标系统要装的包，同时是本地仓库的内容
TARGET_PKGS=(
    base linux linux-firmware mkinitcpio sudo openssh
    iproute2 procps-ng ppp grub efibootmgr dosfstools e2fsprogs
    bpf tcpdump ethtool iputils curl jq vim zsh parted gptfdisk
)

mkdir -p "${OUT}" "${STAGE}" "${DL}"
rm -rf "${PROFILE}/airootfs/opt/localrepo" "${PROFILE}/airootfs/opt/landscape"

echo "::group::环境"
uname -m
cat /etc/os-release | head -2
echo "Landscape ${VERSION}"
echo "::endgroup::"

echo "::group::安装构建依赖"
pacman -Syu --noconfirm --needed --disable-download-timeout \
    archiso arch-install-scripts squashfs-tools libisoburn mtools \
    python jq openssl curl
echo "::endgroup::"

echo "::group::下载 Landscape ${VERSION}"
BASE="https://github.com/ThisSeanZhang/landscape/releases/download/v${VERSION}"
for f in landscape-webserver-x86_64 static.zip; do
    echo "下载 ${f}"
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        -o "${DL}/${f}" "${BASE}/${f}"
done
ls -la "${DL}"

# 校验值：SHASUM256sum.txt 可能不存在，缺失则告警不阻断
if curl -fsSL --retry 3 -o "${DL}/SHASUM256sum.txt" "${BASE}/SHASUM256sum.txt"; then
    cd "${DL}"
    for f in landscape-webserver-x86_64 static.zip; do
        expected="$(grep -E "[[:space:]]\*?${f}\$" SHASUM256sum.txt | awk '{print $1}' | head -1 || true)"
        if [[ -z "${expected}" ]]; then
            echo "警告：校验文件中无 ${f} 条目，跳过"
            continue
        fi
        actual="$(sha256sum "${f}" | awk '{print $1}')"
        [[ "${expected}" == "${actual}" ]] || { echo "校验失败：${f}" >&2; exit 1; }
        echo "校验通过：${f}"
    done
else
    echo "警告：SHASUM256sum.txt 不可用，跳过校验"
fi
echo "::endgroup::"

echo "::group::布置 Landscape 到 airootfs"
LAND="${PROFILE}/airootfs/opt/landscape"
install -d -m 0755 "${LAND}"
install -m 0755 "${DL}/landscape-webserver-x86_64" "${LAND}/landscape-webserver"

python3 - "${DL}/static.zip" "${LAND}/static" <<'PYUNZIP'
import sys, zipfile, os, pathlib
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
with zipfile.ZipFile(src) as z:
    names = z.namelist()
    # 若所有成员共用一个顶层目录，去掉这一层
    tops = {n.split('/')[0] for n in names if n and not n.startswith('/')}
    strip = len(tops) == 1 and tops.copy().pop() is not None
    if strip:
        top = next(iter(tops))
        strip = all(n.startswith(top + '/') or n == top for n in names if n)
    for info in z.infolist():
        name = info.filename
        if strip:
            name = name.split('/', 1)[1] if '/' in name else ''
        if not name:
            continue
        target = pathlib.Path(dst) / name
        if info.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as s, open(target, 'wb') as d:
                d.write(s.read())
print(f'解压 {len(names)} 个条目 -> {dst} (strip_top={strip})')
PYUNZIP

find "${LAND}/static" -type f | head -5
echo "static 文件数：$(find "${LAND}/static" -type f | wc -l)"
echo "--- ${LAND} 全部条目 ---"
ls -la "${LAND}"
echo "--- 二进制详情 ---"
ls -la "${LAND}/landscape-webserver" || echo "二进制不存在！"
echo "::endgroup::"

echo "::group::构建本地 pacman 仓库"
# 下载目标系统所需包（含依赖闭包）到暂存目录
pacman -Syw --noconfirm --disable-download-timeout \
    --cachedir "${STAGE}" "${TARGET_PKGS[@]}"

COUNT=$(find "${STAGE}" -type f \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' \) ! -name '*.sig' | wc -l)
echo "下载的包：${COUNT}"
[[ "${COUNT}" -gt 0 ]] || { echo "错误：未下载到任何包" >&2; exit 1; }

REPO="${PROFILE}/airootfs/opt/localrepo"
install -d -m 0755 "${REPO}"
find "${STAGE}" -type f \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' \) ! -name '*.sig' \
    -exec cp -a {} "${REPO}/" \;

cd "${REPO}"
shopt -s nullglob
PKGFILES=(./*.pkg.tar.zst ./*.pkg.tar.xz)
shopt -u nullglob
[[ ${#PKGFILES[@]} -gt 0 ]] || { echo "错误：仓库目录中没有包文件" >&2; exit 1; }
repo-add -n -R -q custom.db.tar.gz "${PKGFILES[@]}"
echo "仓库内包数：$(find . -type f \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' \) ! -name '*.sig' | wc -l)"
ls -la custom.db.tar.gz custom.files.tar.gz 2>/dev/null || ls -la custom.*
echo "::endgroup::"

echo "::group::构建 ISO"
mkdir -p "${WORK}/work"
mkarchiso -v -w "${WORK}/work" -o "${OUT}" "${PROFILE}"
ls -lh "${OUT}"
echo "::endgroup::"

echo "::group::生成校验文件"
cd "${OUT}"
shopt -s nullglob
for f in *.iso; do
    sha256sum "${f}" | tee "${f}.sha256"
done
shopt -u nullglob
echo "::endgroup::"

echo "::group::静态验证产物"
ISO="$(ls -1 "${OUT}"/*.iso | head -1)"
echo "ISO: ${ISO}"

V=/tmp/verify
rm -rf "${V}"; mkdir -p "${V}/mnt" "${V}/rootfs"

# 解出 ISO 内容（bsdtar 可直接读 iso9660）
bsdtar -xf "${ISO}" -C "${V}/mnt"

SFS="$(find "${V}/mnt" -name 'airootfs.sfs' | head -1)"
[[ -n "${SFS}" ]] || { echo "FAIL: ISO 中无 airootfs.sfs" >&2; exit 1; }
echo "airootfs.sfs: ${SFS}"

unsquashfs -d "${V}/rootfs" "${SFS}" > /tmp/unsquash.log 2>&1 || {
    echo "unsquashfs 失败，最后 30 行：" >&2
    tail -30 /tmp/unsquash.log >&2
    exit 1
}
R="${V}/rootfs"
echo "rootfs 顶层条目："
ls "${R}" | head -20
echo "opt 内容："
ls -la "${R}/opt" 2>&1 | head -10

check() { printf '  %-40s' "$1"; }
ok()    { echo "OK"; }
bad()   { echo "FAIL: $1"; exit 1; }

check "Landscape 二进制"
if [[ ! -x "${R}/opt/landscape/landscape-webserver" ]]; then
    echo ""
    echo "--- 上传前的 profile 内容 ---"
    ls -la "${PROFILE}/airootfs/opt/landscape" 2>&1
    echo "--- squashfs 内的内容 ---"
    ls -la "${R}/opt/landscape" 2>&1
    bad "缺少或不可执行"
fi
ok

check "Landscape static"
N=$(find "${R}/opt/landscape/static" -type f 2>/dev/null | wc -l)
[[ "${N}" -gt 0 ]] || bad "static 为空"
ok; echo "      (${N} files)"

check "本地仓库 db"
[[ -f "${R}/opt/localrepo/custom.db.tar.gz" ]] || bad "custom.db.tar.gz 缺失"
ok

check "本地仓库包数"
N=$(find "${R}/opt/localrepo" -type f \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' \) ! -name '*.sig' | wc -l)
[[ "${N}" -gt 0 ]] || bad "仓库为空"
ok; echo "      (${N} packages)"

check "安装脚本存在"
[[ -f "${R}/root/install.sh" ]] || bad "install.sh 缺失"
ok

check "安装脚本语法"
bash -n "${R}/root/install.sh" || bad "语法错误"
ok

check "装机脚本可执行位"
[[ -x "${R}/root/install.sh" ]] || bad "缺少执行位（file_permissions 未生效）"
ok

check "networkmanager 包未安装"
# 以 pacman 本地数据库为准：安装过就有同名目录
if compgen -G "${R}/var/lib/pacman/local/networkmanager-*" > /dev/null; then
    bad "networkmanager 已安装"
fi
# NetworkManager 本体：守护进程与 CLI。dispatcher.d 目录可能由 open-vm-tools 等第三方创建，不算
if [[ -e "${R}/usr/bin/NetworkManager" || -e "${R}/usr/bin/nmcli" ]]; then
    bad "发现 NetworkManager 可执行文件"
fi
ok

check "systemd-resolvconf 不在"
if [[ -e "${R}/usr/bin/resolvconf" ]] && grep -q 'systemd' "${R}/usr/bin/resolvconf" 2>/dev/null; then
    bad "发现 systemd-resolvconf"
fi
ok

echo "--- 内核配置断言 ---"
# mkarchiso 的 _cleanup_pacstrap_dir 会清空 airootfs 的 /boot，
# 内核实际位于 ISO 的 <install_dir>/boot/<arch>/ 下
VML="$(find "${V}/mnt" -name 'vmlinuz-linux' | head -1)"
[[ -n "${VML}" ]] || VML="$(find "${R}" -name 'vmlinuz-linux' | head -1)"
[[ -n "${VML}" ]] || bad "找不到 vmlinuz-linux"
echo "vmlinuz: ${VML}"

# 内嵌上游 scripts/extract-ikconfig 的逻辑：vmlinuz 是压缩内核，
# IKCFG_ST 在解压后才可见，必须逐个尝试解压算法。
cat > /tmp/extract-ikconfig <<'EIC_EOF'
#!/bin/sh
cf1='IKCFG_ST\037\213\010'
cf2='0123456789'
dump_config()
{
    if pos=`tr "$cf1\n$cf2" "\n$cf2=" < "$1" | grep -abo "^$cf2"`
    then
        pos=${pos%%:*}
        tail -c+$(($pos+8)) "$1" | zcat > $tmp1 2> /dev/null
        if [ $? != 1 ]
        then
            cat $tmp1
            exit 0
        fi
    fi
}
try_decompress()
{
    for pos in `tr "$1\n$2" "\n$2=" < "$img" | grep -abo "^$2"`
    do
        pos=${pos%%:*}
        tail -c+$pos "$img" | $3 > $tmp2 2> /dev/null
        dump_config $tmp2
    done
}
img=$1
tmp1=/tmp/ikconfig$$.1
tmp2=/tmp/ikconfig$$.2
trap "rm -f $tmp1 $tmp2" 0
dump_config "$img"
try_decompress '\037\213\010' xy    gunzip
try_decompress '\3757zXZ\000' abcde unxz
try_decompress 'BZh'          xy    bunzip2
try_decompress '\135\0\0\0'   xxx   unlzma
try_decompress '\211\114\132' xy    'lzop -d'
try_decompress '\002\041\114\030' xyy 'lz4 -d -l'
try_decompress '\050\265\057\375' xxx unzstd
exit 1
EIC_EOF
chmod +x /tmp/extract-ikconfig

sh /tmp/extract-ikconfig "${VML}" > /tmp/kconfig 2>/dev/null || true

[[ -s /tmp/kconfig ]] || bad "无法从 vmlinuz 提取内核配置"
echo "配置行数：$(wc -l < /tmp/kconfig)"

REQ_Y=(
    CONFIG_BPF
    CONFIG_HAVE_EBPF_JIT
    CONFIG_ARCH_WANT_DEFAULT_BPF_JIT
    CONFIG_BPF_SYSCALL
    CONFIG_BPF_JIT
    CONFIG_BPF_JIT_DEFAULT_ON
    CONFIG_BPF_UNPRIV_DEFAULT_OFF
    CONFIG_BPF_LSM
    CONFIG_CGROUP_BPF
    CONFIG_IPV6_SEG6_BPF
    CONFIG_NETFILTER_BPF_LINK
    CONFIG_BPF_STREAM_PARSER
    CONFIG_LWTUNNEL_BPF
    CONFIG_BPF_EVENTS
    CONFIG_DEBUG_INFO_BTF
)
REQ_ANYM=(
    CONFIG_NETFILTER_XT_MATCH_BPF
    CONFIG_NET_CLS_BPF
    CONFIG_NET_ACT_BPF
    CONFIG_NF_TABLES
)

fail=0
for s in "${REQ_Y[@]}"; do
    line="$(grep -E "^${s}=" /tmp/kconfig | head -1 || true)"
    if [[ "${line}" == "${s}=y" ]]; then
        printf '  OK   %s\n' "${line}"
    else
        printf '  FAIL %s (=y 要求) 实际: %s\n' "${s}" "${line:-未设置}"
        fail=1
    fi
done

for s in "${REQ_ANYM[@]}"; do
    line="$(grep -E "^${s}=" /tmp/kconfig | head -1 || true)"
    if [[ "${line}" == "${s}=y" || "${line}" == "${s}=m" ]]; then
        printf '  OK   %s\n' "${line}"
    else
        printf '  FAIL %s (需 =y 或 =m) 实际: %s\n' "${s}" "${line:-未设置}"
        fail=1
    fi
done

[[ ${fail} -eq 0 ]] || bad "内核配置断言未全部通过"

echo "--- BTF 可用性 ---"
# vmlinuz 是压缩镜像，.BTF 在解压后的 ELF 内。
# 解压 vmlinuz 后检查 .BTF section 是否存在。
python3 - "${VML}" > /tmp/vmlinux.raw <<'PYDEC'
import sys, subprocess, shutil
img = sys.argv[1]
# 按 Magic 判断压缩格式并解压
magics = [
    (b'\x1f\x8b\x08', ['gzip', '-dc']),
    (b'\xfd7zXZ\x00', ['xz', '-dc']),
    (b'BZh',            ['bzip2', '-dc']),
    (b'\x5d\x00\x00\x00', ['xz', '--format=lzma', '-dc']),
    (b'\x02\x21\x4c\x18', ['lz4', '-dc']),
    (b'\x28\xb5\x2f\xfd', ['zstd', '-dc']),
]
data = open(img, 'rb').read()
for magic, cmd in magics:
    idx = data.find(magic)
    if idx < 0:
        continue
    if not shutil.which(cmd[0]):
        continue
    p = subprocess.run(cmd, input=data[idx:], capture_output=True)
    if p.returncode == 0 and p.stdout:
        sys.stdout.buffer.write(p.stdout)
        sys.exit(0)
sys.exit('decompress failed')
PYDEC

if [[ -s /tmp/vmlinux.raw ]]; then
    echo "解压后大小：$(stat -c %s /tmp/vmlinux.raw) 字节"
    if readelf -S /tmp/vmlinux.raw 2>/dev/null | grep -qE '\.BTF\b'; then
        echo "  OK   .BTF section 存在"
        readelf -S /tmp/vmlinux.raw 2>/dev/null | grep -E '\.BTF\b' | head -1
    else
        echo "  可用 section（前 20）："
        readelf -S /tmp/vmlinux.raw 2>/dev/null | grep -oE '\.[A-Za-z_.]+' | sort -u | head -20
        bad ".BTF section 未找到"
    fi
else
    bad "无法解压 vmlinuz，无法验证 BTF"
fi

echo "::endgroup::"
echo "所有静态检查通过"
