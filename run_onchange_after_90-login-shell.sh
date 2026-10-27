#!/usr/bin/env bash
# 把登录 shell 改成系统 zsh（Linux；macOS 默认就是 zsh）。可重复运行。
set -euo pipefail

[ "$(uname -s)" = Linux ] || exit 0

zsh_path="$(command -v zsh || true)"
[ -n "$zsh_path" ] || { echo "==> 未找到 zsh，跳过登录 shell 设置"; exit 0; }

user="$(id -un)"
current="$(getent passwd "$user" | cut -d: -f7)"
[ "$(basename "$current")" = zsh ] && exit 0

# zsh 不在 /usr 下（例如用 pixi 装的）或拿不到 sudo：在 ~/.bashrc 里 exec zsh，不改登录 shell
case "$zsh_path" in /usr/* | /bin/*) system_zsh=1 ;; *) system_zsh=0 ;; esac
# root 时直接执行，不经过 sudo：容器、最小化安装的系统里常常没有 sudo
sudo=()
if [ "$(id -u)" -eq 0 ]; then
  can_root=1
elif command -v sudo >/dev/null 2>&1 && sudo -v 2>/dev/null; then
  can_root=1
  sudo=(sudo)
else
  can_root=0
fi
if [ "$system_zsh" = 1 ] && [ "$can_root" = 1 ]; then
  echo "==> 登录 shell 改为 $zsh_path"
  # ${a[@]+"${a[@]}"}：bash 4.4 以前在 set -u 下展开空数组会报错
  grep -qx "$zsh_path" /etc/shells || echo "$zsh_path" | ${sudo[@]+"${sudo[@]}"} tee -a /etc/shells >/dev/null
  ${sudo[@]+"${sudo[@]}"} chsh -s "$zsh_path" "$user"
elif ! grep -q '# dotfiles: exec zsh' "$HOME/.bashrc" 2>/dev/null; then
  echo "==> 无法 chsh，改为在 ~/.bashrc 中启动 zsh"
  printf '\n[[ $- == *i* ]] && exec "%s"  # dotfiles: exec zsh\n' "$zsh_path" >>"$HOME/.bashrc"
fi
