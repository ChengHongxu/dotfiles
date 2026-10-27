#!/usr/bin/env bash
# 新机器一键初始化：
#   curl -fsSL https://raw.githubusercontent.com/ChengHongxu/dotfiles/main/bootstrap.sh | bash
# 可选环境变量：
#   DOTFILES_REPO   dotfiles 仓库地址（默认见下）
#   ADOPT_GROUPS    本机分组，逗号分隔，如 work 或 homelab；不设则交互询问
#   PIXI_REPOURL    pixi 下载源（无法直连 GitHub 时用镜像）
#   DOTFILES_GIT_NAME / DOTFILES_GIT_EMAIL
#                   预填 chezmoi 首次运行时问的两个问题（见 .chezmoi.toml.tmpl）
# 没有终端时（cloud-init）不提问，全部用环境变量或默认值。
#
# 分工：
#   adopt    软件：按仓库里的 packages.toml 安装系统包（apt / dnf / brew）、pixi global 工具、npm 全局包，
#            再执行 [script.*] 安装脚本
#   chezmoi  配置文件：home 下是指向仓库的软链接（symlink 模式）
set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/ChengHongxu/dotfiles.git}"
ADOPT_CHANNEL="https://chenghongxu.github.io/packages/conda"
export PATH="$HOME/.pixi/bin:$PATH"

# curl | bash 时 stdin 是管道，交互步骤改从终端读；打不开终端就是无人值守
if (exec </dev/tty) 2>/dev/null; then
  tty=/dev/tty
else
  tty=""
fi

# ---- 0. git 必须先于 adopt 可用 ----
# chezmoi 能用内置 git clone，但 adopt 的仓库检查和同步依赖外部 git。
# 继续使用系统 git，避免用 pixi git 替换系统 CA / 凭据助手。
system_install() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    if [ -n "$tty" ]; then
      sudo -- "$@" <"$tty"
    else
      sudo -n -- "$@"
    fi
  else
    echo "错误：安装系统 git 需要 root 或 sudo；请让管理员安装 git 后重跑。" >&2
    return 1
  fi
}

if ! git --version >/dev/null 2>&1; then
  echo "==> 安装系统 git（chezmoi / adopt 的前置依赖）"
  if [ "$(uname -s)" = Darwin ]; then
    echo "请先运行 xcode-select --install，完成 Command Line Tools 安装后重跑。" >&2
    exit 1
  elif command -v apt-get >/dev/null 2>&1; then
    system_install apt-get update
    system_install apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then
    system_install dnf install -y git
  elif command -v yum >/dev/null 2>&1; then
    system_install yum install -y git
  else
    echo "错误：未找到可用的 git；请用本机包管理器安装 git 后重跑。" >&2
    exit 1
  fi
  if ! git --version >/dev/null 2>&1; then
    echo "错误：安装后仍无法运行 git --version；请检查 PATH 和系统 git 安装。" >&2
    exit 1
  fi
fi

# ---- 1. pixi + adopt + chezmoi ----
# channel 与 packages.toml 里的条目保持一致，否则 adopt 会把它们当成"本机改过的 pixi 环境"
if ! command -v pixi >/dev/null 2>&1; then
  echo "==> 安装 pixi"
  curl -fsSL https://pixi.sh/install.sh | PIXI_NO_PATH_UPDATE=1 bash
fi
if ! command -v adopt >/dev/null 2>&1; then
  echo "==> 安装 adopt"
  pixi global install -c "$ADOPT_CHANNEL" -c conda-forge adopt
fi
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "==> 安装 chezmoi"
  pixi global install -c conda-forge chezmoi
fi

# ---- 2. 拉取 dotfiles，chezmoi 写入配置 ----
# 要在 adopt 之前：~/.npmrc 决定 npm 全局包装到哪里（~/.local），不能装进 pixi 的 nodejs 环境
# chezmoi 默认 clone 到 ~/.local/share/chezmoi；后面读取实际路径，兼容自定义 sourceDir。
# run_onchange 脚本（如改登录 shell）要用 zsh，外部仓库也延后到第 3 步装好软件后再应用。
echo "==> 拉取 dotfiles 并写入配置"
if [ -n "$tty" ]; then
  chezmoi init --apply --exclude externals,scripts "$DOTFILES_REPO" <"$tty"
else
  chezmoi init --apply --exclude externals,scripts --no-tty --promptDefaults "$DOTFILES_REPO"
fi

# ---- 3. adopt：记录基线，按清单装软件 ----
echo "==> adopt"
source_dir="$(chezmoi source-path)"
if [ -z "$source_dir" ] || [ "$(git -C "$source_dir" rev-parse --is-inside-work-tree)" != true ]; then
  echo "错误：chezmoi 源目录不是可用的 Git 工作区：$source_dir" >&2
  echo "请检查上面的 git 错误；脚本不会删除目录或重新 clone，以免丢失配置。" >&2
  exit 1
fi
repo_dir="$(git -C "$source_dir" rev-parse --show-toplevel)"
init_args=(--repo "$repo_dir")
[ -n "${ADOPT_GROUPS:-}" ] && init_args+=(--groups "$ADOPT_GROUPS")
# ${a[@]+"${a[@]}"}：macOS 自带的 bash 3.2 在 set -u 下展开空数组会报错
if [ -n "$tty" ]; then
  adopt init ${init_args[@]+"${init_args[@]}"} <"$tty"
  adopt sync <"$tty"   # 展示完整命令（含 sudo）确认一次
else
  adopt init --yes ${init_args[@]+"${init_args[@]}"}
  adopt sync --yes     # 只会用免密的 sudo -n；拿不到就跳过系统包
fi

# ---- 4. 补上第 2 步跳过的部分 ----
echo "==> chezmoi apply"
if [ -n "$tty" ]; then
  chezmoi apply <"$tty"
else
  chezmoi apply --no-tty
fi

echo "==> 完成，重新登录或执行 exec zsh 生效"
