#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="landscape-router"
iso_label="LANDSCAPE_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="landscape-build"
iso_application="Landscape Router Appliance Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
arch="x86_64"

# 只做安装介质，不含交互式 live 环境
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')

# U 盘启动即执行无人值守安装（ADR-0001）
kernel_params_x86_64="script=/root/install.sh"

pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')

file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/root/install.sh"]="0:0:755"
  ["/opt/localrepo"]="0:0:755"
  ["/opt/landscape"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
)
