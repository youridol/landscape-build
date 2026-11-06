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
    strip = len(tops) == 1 and all(n.startswith(tops.pop() + '/') or n.endswith('/') for n in names)
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
echo "::endgroup::"

echo "::group::构建本地 pacman 仓库"
# 下载目标系统所需包（含依赖闭包）到暂存目录
pacman -Syw --noconfirm --disable-download-timeout \
    --cachedir "${STAGE}" "${TARGET_PKGS[@]}"

COUNT=$(find "${STAGE}" -name '*.pkg.tar.*' -type f | wc -l)
echo "下载的包：${COUNT}"
[[ "${COUNT}" -gt 0 ]] || { echo "错误：未下载到任何包" >&2; exit 1; }

REPO="${PROFILE}/airootfs/opt/localrepo"
install -d -m 0755 "${REPO}"
find "${STAGE}" -name '*.pkg.tar.*' -type f -exec cp -a {} "${REPO}/" \;

cd "${REPO}"
repo-add -n -R -q custom.db.tar.gz ./*.pkg.tar.*
echo "仓库内包数：$(find . -name '*.pkg.tar.*' | wc -l)"
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

unsquashfs -d "${V}/rootfs" -f "${SFS}" >/dev/null
R="${V}/rootfs"

check() { printf '  %-40s' "$1"; }
ok()    { echo "OK"; }
bad()   { echo "FAIL: $1"; exit 1; }

check "Landscape 二进制"
[[ -x "${R}/opt/landscape/landscape-webserver" ]] || bad "缺少或不可执行"
ok

check "Landscape static"
N=$(find "${R}/opt/landscape/static" -type f 2>/dev/null | wc -l)
[[ "${N}" -gt 0 ]] || bad "static 为空"
ok; echo "      (${N} files)"

check "本地仓库 db"
[[ -f "${R}/opt/localrepo/custom.db.tar.gz" ]] || bad "custom.db.tar.gz 缺失"
ok

check "本地仓库包数"
N=$(find "${R}/opt/localrepo" -name '*.pkg.tar.*' | wc -l)
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

check "networkmanager 不在"
[[ ! -d "${R}/usr/lib/NetworkManager" ]] || bad "发现 NetworkManager"
ok

check "systemd-resolvconf 不在"
if [[ -e "${R}/usr/bin/resolvconf" ]] && grep -q 'systemd' "${R}/usr/bin/resolvconf" 2>/dev/null; then
    bad "发现 systemd-resolvconf"
fi
ok

echo "--- 内核配置断言 ---"
VML="$(find "${R}" -name 'vmlinuz-linux' | head -1)"
[[ -n "${VML}" ]] || bad "找不到 vmlinuz-linux"
echo "vmlinuz: ${VML}"

IKC="$(find "${R}" -name 'extract-ikconfig' -path '*/scripts/*' | head -1)"
if [[ -n "${IKC}" ]]; then
    bash "${IKC}" "${VML}" > /tmp/kconfig 2>/dev/null || true
fi

if [[ ! -s /tmp/kconfig ]]; then
    python3 - "${VML}" > /tmp/kconfig <<'PYKCFG'
import sys, gzip, io, zlib
data = open(sys.argv[1], 'rb').read()
i = data.find(b'IKCFG_ST')
if i < 0:
    sys.exit('no IKCFG_ST magic')
raw = data[i + 8:]
for fn in (lambda: gzip.GzipFile(fileobj=io.BytesIO(raw)).read(),
           lambda: zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(raw)):
    try:
        sys.stdout.buffer.write(fn()); break
    except Exception:
        continue
else:
    sys.exit('decompress failed')
PYKCFG
fi

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

echo "--- .BTF section ---"
python3 - "${VML}" <<'PYBTF' || bad ".BTF section 缺失"
import sys
data = open(sys.argv[1], 'rb').read()
if b'.BTF\x00' not in data:
    sys.exit(1)
print('  OK   .BTF 存在')
PYBTF

echo "::endgroup::"
echo "所有静态检查通过"
