#!/usr/bin/env bash
# =============================================================================
# install-steam-toolkit.sh
#
# 用途:
#   将 Steam_v3.2.0_linux_x64.tgz（Steam++ / Watt Toolkit）手动安装到 /opt，
#   自动设置权限、创建符号链接、查找启动脚本、创建桌面启动器，并支持一键卸载。
#
# 背景:
#   Watt Toolkit 的 Steam++.sh 会在安装目录内创建 Steam++ -> dotnet/dotnet 的
#   符号链接。由于 /opt 通常为 root:root 755，普通用户无法写入，运行时会报:
#       ln: failed to create symbolic link './Steam++': Permission denied
#   本脚本在安装阶段以 root 预先创建该链接，普通用户运行时即可走"已存在"分支。
#
# 适用:
#   Debian / Ubuntu / Linux Mint 等使用 sudo 的发行版。
#
# 依赖:
#   bash, tar, find, grep, head, install, realpath, readlink, mktemp
#   运行时可能还需要: jq, zenity（脚本只提示，不自动安装）
#
# 使用案例:
#   1) 默认安装（自动在 ./ 和 ~/Downloads 下查找 tgz）
#      ./install-steam-toolkit.sh
#
#   2) 指定 tgz 文件安装
#      ./install-steam-toolkit.sh -f ~/Downloads/Steam_v3.2.0_linux_x64.tgz
#
#   3) 安装到自定义目录
#      ./install-steam-toolkit.sh -f ./Steam.tgz -d /opt/my-steam
#
#   4) 手动指定启动脚本（自动查找失败时）
#      ./install-steam-toolkit.sh -f ./Steam.tgz --exec Steam++.sh
#
#   5) 不创建桌面启动器
#      ./install-steam-toolkit.sh -f ./Steam.tgz --no-desktop
#
#   6) 仅修复已有安装的符号链接和权限（不重装）
#      ./install-steam-toolkit.sh --fix
#
#   7) 卸载（会二次确认）
#      ./install-steam-toolkit.sh --uninstall
#
#   8) 卸载并跳过确认
#      ./install-steam-toolkit.sh --uninstall -y
#
#   9) 查看版本 / 帮助
#      ./install-steam-toolkit.sh --version
#      ./install-steam-toolkit.sh -h
#
# 说明:
#   - 安装目录默认 /opt/steam++，所有权 root:root，普通用户可读可执行。
#   - 若安装目录已存在，会先备份为 /opt/steam++.bak.时间戳。
#   - 卸载只删除安装目录和桌面启动器，不会自动删除 .bak 备份。
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.2.0"
APP_NAME="Steam++"
DEFAULT_TGZ_NAME="Steam_v3.2.0_linux_x64.tgz"
DEFAULT_INSTALL_DIR="/opt/steam++"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
TGZ=""
CREATE_DESKTOP=1
ASSUME_YES=0
DO_UNINSTALL=0
DO_FIX=0
EXEC_REL=""

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "脚本在第 $LINENO 行执行失败（退出码 $?）"' ERR

usage() {
  cat <<'EOF'
用法:
  ./install-steam-toolkit.sh [选项]

选项:
  -f, --file <tgz>       指定 Steam_v3.2.0_linux_x64.tgz 路径
  -d, --dir <目录>       指定安装目录，默认 /opt/steam++
      --exec <相对路径>  指定启动脚本相对安装目录的路径，例如 Steam++.sh
      --no-desktop       不创建桌面启动器
      --fix              仅修复已有安装的符号链接和权限（不重装）
  -u, --uninstall        卸载安装目录和桌面启动器
  -y, --yes              卸载时不再询问确认
  -V, --version          显示脚本版本
  -h, --help             显示本帮助

使用案例:
  1. 默认安装（自动查找 ./ 和 ~/Downloads 下的 tgz）
     ./install-steam-toolkit.sh

  2. 指定 tgz 文件安装
     ./install-steam-toolkit.sh -f ~/Downloads/Steam_v3.2.0_linux_x64.tgz

  3. 安装到自定义目录
     ./install-steam-toolkit.sh -f ./Steam.tgz -d /opt/my-steam

  4. 手动指定启动脚本（自动查找失败时）
     ./install-steam-toolkit.sh -f ./Steam.tgz --exec Steam++.sh

  5. 不创建桌面启动器
     ./install-steam-toolkit.sh -f ./Steam.tgz --no-desktop

  6. 仅修复已有安装的符号链接和权限
     ./install-steam-toolkit.sh --fix

  7. 卸载（会二次确认）
     ./install-steam-toolkit.sh --uninstall

  8. 卸载并跳过确认
     ./install-steam-toolkit.sh --uninstall -y

  9. 查看版本 / 帮助
     ./install-steam-toolkit.sh --version
     ./install-steam-toolkit.sh -h

注意:
  - 安装目录默认 /opt/steam++，所有权 root:root。
  - 若安装目录已存在，会先备份为 /opt/steam++.bak.时间戳。
  - 卸载不会自动删除 .bak 备份目录，需要时请手动清理。
  - Watt Toolkit 的符号链接问题由本脚本自动处理，无需手动 sudo ln。
EOF
}

run_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

# 确定目标用户和桌面目录
if [[ $EUID -eq 0 ]]; then
  TARGET_USER="${SUDO_USER:-root}"
else
  TARGET_USER="${USER:-$(id -un)}"
fi
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[[ -n "${TARGET_HOME:-}" ]] || TARGET_HOME="${HOME:-/root}"

if [[ $EUID -eq 0 ]]; then
  DESKTOP_DIR="$TARGET_HOME/.local/share/applications"
else
  DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
fi
DESKTOP_FILE="$DESKTOP_DIR/steam++.desktop"

while (($#)); do
  case "$1" in
    -f|--file)      TGZ="${2:?--file 需要参数}"; shift 2 ;;
    -d|--dir)       INSTALL_DIR="${2:?--dir 需要参数}"; shift 2 ;;
    --exec)         EXEC_REL="${2:?--exec 需要参数}"; shift 2 ;;
    --no-desktop)   CREATE_DESKTOP=0; shift ;;
    --fix)          DO_FIX=1; shift ;;
    -u|--uninstall) DO_UNINSTALL=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -V|--version)   printf '%s installer %s\n' "$APP_NAME" "$VERSION"; exit 0 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "未知参数: $1（用 -h 查看帮助）" ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  need_cmd sudo
fi
need_cmd tar
need_cmd find
need_cmd grep
need_cmd head
need_cmd install
need_cmd realpath
need_cmd readlink
need_cmd mktemp

# 规范化安装目录并做安全校验
INSTALL_DIR="$(realpath -m -- "$INSTALL_DIR")"
case "$INSTALL_DIR" in
  /|/opt|/usr|/usr/local|/home|/root|/bin|/sbin|/etc|/var|/tmp)
    die "拒绝使用危险安装目录: $INSTALL_DIR"
    ;;
esac

# -----------------------------------------------------------------------------
# 符号链接与可执行位修复
#   针对 Watt Toolkit 的 Steam++.sh：它会在安装目录内创建
#   Steam++ -> dotnet/dotnet 的链接，但 /opt 对普通用户不可写。
#   这里以 root 预先创建，普通用户运行时脚本会走"已存在"分支跳过。
# -----------------------------------------------------------------------------
setup_launcher_link() {
  local dotnet_bin link_target current
  dotnet_bin="$INSTALL_DIR/dotnet/dotnet"
  link_target="$INSTALL_DIR/Steam++"

  # 若不是 Watt Toolkit 的结构，安静跳过
  if [[ ! -f "$dotnet_bin" ]]; then
    return 0
  fi

  # 确保 dotnet 二进制可执行
  run_root chmod +x -- "$dotnet_bin" 2>/dev/null || true

  if [[ -L "$link_target" ]]; then
    current="$(readlink -f -- "$link_target" 2>/dev/null || true)"
    if [[ "$current" == "$(readlink -f -- "$dotnet_bin")" ]]; then
      log "符号链接已正确: $link_target -> $dotnet_bin"
    else
      warn "符号链接指向异常: $link_target -> ${current:-<无效>}"
      run_root ln -sfn -- "$dotnet_bin" "$link_target"
      log "已更新符号链接: $link_target -> $dotnet_bin"
    fi
  elif [[ -e "$link_target" ]]; then
    warn "$link_target 已存在但不是符号链接，保持不动"
  else
    run_root ln -s -- "$dotnet_bin" "$link_target"
    log "已创建符号链接: $link_target -> $dotnet_bin"
  fi
}

do_fix() {
  log "修复模式: $INSTALL_DIR"
  [[ -d "$INSTALL_DIR" ]] || die "安装目录不存在: $INSTALL_DIR"

  local launcher
  launcher="$(find_launcher || true)"
  if [[ -n "$launcher" ]]; then
    run_root chmod +x -- "$launcher"
    log "启动脚本: $launcher"
  else
    warn "未找到启动脚本"
  fi

  setup_launcher_link
  log "修复完成"
}

do_uninstall() {
  log "准备卸载 $APP_NAME"
  log "安装目录: $INSTALL_DIR"
  log "桌面文件: $DESKTOP_FILE"

  local backups
  backups="$(find "$(dirname -- "$INSTALL_DIR")" -maxdepth 1 -type d \
      -name "$(basename -- "$INSTALL_DIR").bak.*" 2>/dev/null || true)"
  if [[ -n "$backups" ]]; then
    warn "发现以下备份目录（卸载不会删除，需要时请手动清理）:"
    printf '  %s\n' $backups >&2
  fi

  if (( ! ASSUME_YES )); then
    read -r -p "确认删除以上内容? [y/N] " ans || true
    [[ "${ans:-}" =~ ^[yY]$ ]] || { log "已取消"; exit 0; }
  fi

  run_root rm -rf -- "$INSTALL_DIR" 2>/dev/null || true
  rm -f -- "$DESKTOP_FILE" 2>/dev/null || true

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
  fi

  log "卸载完成"
}

find_launcher() {
  if [[ -n "$EXEC_REL" ]]; then
    local p
    if [[ "$EXEC_REL" = /* ]]; then
      p="$EXEC_REL"
    else
      p="$INSTALL_DIR/$EXEC_REL"
    fi
    [[ -f "$p" ]] && printf '%s\n' "$p"
    return 0
  fi

  local c
  for c in Steam++.sh steam++.sh Watt-Toolkit.sh watt-toolkit.sh start.sh run.sh; do
    if [[ -f "$INSTALL_DIR/$c" ]]; then
      printf '%s\n' "$INSTALL_DIR/$c"
      return 0
    fi
  done

  local found
  found="$(find "$INSTALL_DIR" -maxdepth 3 -type f -name '*.sh' \
      \( -iname '*steam*' -o -iname '*watt*' \) | head -n1 || true)"
  [[ -n "$found" ]] || found="$(find "$INSTALL_DIR" -maxdepth 3 -type f -name '*.sh' | head -n1 || true)"
  printf '%s\n' "$found"
}

find_icon() {
  local found
  found="$(find "$INSTALL_DIR" -maxdepth 4 -type f \
      \( -iname '*.png' -o -iname '*.svg' \) \
      | grep -Ei 'watt|steam|icon|logo' | head -n1 || true)"
  [[ -n "$found" ]] || found="$(find "$INSTALL_DIR" -maxdepth 4 -type f \
      \( -iname '*.png' -o -iname '*.svg' \) | head -n1 || true)"
  printf '%s\n' "$found"
}

create_desktop() {
  (( CREATE_DESKTOP == 1 )) || return 0
  [[ -n "${LAUNCHER:-}" ]] || { warn "无启动脚本，跳过桌面启动器"; return 0; }

  local exec_value icon_line tmpd
  exec_value="\"${LAUNCHER//\"/\\\"}\""
  icon_line=""
  if [[ -n "${ICON:-}" ]]; then
    icon_line="Icon=$ICON"
  fi

  tmpd="$(mktemp)"
  cat > "$tmpd" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=$APP_NAME / Watt Toolkit
Exec=$exec_value
$icon_line
Terminal=false
Categories=Network;Utility;
StartupNotify=true
EOF

  if [[ $EUID -eq 0 ]]; then
    install -d -o "$TARGET_UID" -g "$TARGET_GID" -m 755 "$DESKTOP_DIR"
    install -o "$TARGET_UID" -g "$TARGET_GID" -m 755 "$tmpd" "$DESKTOP_FILE"
  else
    mkdir -p "$DESKTOP_DIR"
    install -m 755 "$tmpd" "$DESKTOP_FILE"
  fi

  rm -f -- "$tmpd"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
  fi

  log "已创建桌面启动器: $DESKTOP_FILE"
}

# --- 卸载 / 修复分支 ---------------------------------------------------------
if (( DO_UNINSTALL == 1 )); then
  do_uninstall
  exit 0
fi

if (( DO_FIX == 1 )); then
  do_fix
  exit 0
fi

# --- 安装流程 ---------------------------------------------------------------
# 自动查找默认 tgz
if [[ -z "$TGZ" ]]; then
  for c in "$PWD/$DEFAULT_TGZ_NAME" "$TARGET_HOME/Downloads/$DEFAULT_TGZ_NAME"; do
    if [[ -f "$c" ]]; then
      TGZ="$c"
      break
    fi
  done
fi

[[ -n "$TGZ" ]] || die "未找到 $DEFAULT_TGZ_NAME，请用 -f 指定 tgz 文件"
[[ -f "$TGZ" ]] || die "文件不存在: $TGZ"
TGZ="$(readlink -f -- "$TGZ")"
tar -tzf "$TGZ" >/dev/null 2>&1 || die "不是有效的 tar.gz/tgz 文件: $TGZ"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/steam++.XXXXXX")"
cleanup() {
  [[ -n "${TMP_DIR:-}" ]] && rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

log "解压到临时目录: $TMP_DIR"
tar --no-same-owner -xzf "$TGZ" -C "$TMP_DIR"

shopt -s nullglob dotglob
entries=("$TMP_DIR"/*)
shopt -u nullglob dotglob

(( ${#entries[@]} > 0 )) || die "压缩包为空"

# 如果 tgz 只有一个顶层目录，则安装该目录内容；否则安装整个临时目录
if (( ${#entries[@]} == 1 )) && [[ -d "${entries[0]}" ]]; then
  APP_ROOT="${entries[0]}"
else
  APP_ROOT="$TMP_DIR"
fi

# 备份旧安装目录
if [[ -e "$INSTALL_DIR" ]]; then
  BACKUP="${INSTALL_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
  warn "安装目录已存在，备份到: $BACKUP"
  run_root mv -- "$INSTALL_DIR" "$BACKUP"
fi

log "安装到: $INSTALL_DIR"
run_root mkdir -p -- "$(dirname -- "$INSTALL_DIR")"
run_root mv -- "$APP_ROOT" "$INSTALL_DIR"

# 设置权限
run_root chown -R root:root "$INSTALL_DIR"
run_root chmod -R u+rwX,go+rX "$INSTALL_DIR"
run_root find "$INSTALL_DIR" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
# 显式给 dotnet 二进制补可执行位（大写 X 只在原已有 x 位时生效）
if [[ -f "$INSTALL_DIR/dotnet/dotnet" ]]; then
  run_root chmod +x "$INSTALL_DIR/dotnet/dotnet"
fi

# 处理 Watt Toolkit 的 Steam++ 符号链接
setup_launcher_link

LAUNCHER="$(find_launcher || true)"

if [[ -n "$EXEC_REL" && -z "$LAUNCHER" ]]; then
  die "--exec 指定的启动文件不存在: $EXEC_REL"
fi

if [[ -n "$LAUNCHER" ]]; then
  run_root chmod +x -- "$LAUNCHER"
  log "启动脚本: $LAUNCHER"
else
  warn "未自动找到启动脚本；可用 --exec 相对路径 重新运行，或手动创建桌面文件。"
fi

ICON="$(find_icon || true)"

create_desktop

# 安装后自检
if [[ -n "${LAUNCHER:-}" ]]; then
  [[ -x "$LAUNCHER" ]] || warn "启动脚本不可执行，请检查: $LAUNCHER"
fi

# 常见依赖提示
missing=()
for c in jq zenity; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if ((${#missing[@]})); then
  warn "可能缺少运行依赖: ${missing[*]}"
  warn "Debian/Ubuntu 可执行: sudo apt install ${missing[*]}"
fi

for f in "$INSTALL_DIR/environment_check.sh" "$INSTALL_DIR/script/environment_check.sh"; do
  if [[ -f "$f" ]]; then
    warn "发现环境检查脚本: $f"
    warn "建议先运行它检查依赖: $f"
    break
  fi
done

log "安装完成: $INSTALL_DIR"
if [[ -n "${LAUNCHER:-}" ]]; then
  log "启动命令: $LAUNCHER"
fi
cat <<EOF

常用命令回顾:
  启动:      $LAUNCHER
  修复链接:  $0 --fix
  卸载:      $0 --uninstall
  跳过确认:  $0 --uninstall -y
  帮助:      $0 -h

说明:
  Watt Toolkit 的符号链接（$INSTALL_DIR/Steam++ -> dotnet/dotnet）
  已由本脚本以 root 预先创建，普通用户直接运行启动脚本即可，
  不会再出现 "ln: failed to create symbolic link ...: Permission denied"。
EOF