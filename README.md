# dotfiles

软件由 [adopt](https://github.com/ChengHongxu/adopt) 管理，配置文件由 **chezmoi**（symlink 模式）管理，
shell 是 **oh-my-zsh + starship**，Python 环境由 [venv](https://github.com/ChengHongxu/venv) 在每台机器上按需创建。

核心思路：**照常用各工具自己的命令装软件、改配置，之后运行一次 `adopt` 决定哪些要同步。**

## 新机器

```sh
curl -fsSL https://raw.githubusercontent.com/ChengHongxu/dotfiles/main/bootstrap.sh | bash
```

首次运行会问 Git 用户名、邮箱和本机分组（`work` / `homelab` 等）。
脚本依次：

1. 检查可运行的系统 git；Linux 缺少时用 apt / dnf / yum 安装（需要 root 或 sudo），macOS 缺少时提示先装 Command Line Tools。然后装 pixi，再用 pixi 装 adopt 和 chezmoi
2. `chezmoi init --apply`：clone 本仓库到 `~/.local/share/chezmoi`，链接配置文件
3. 验证 chezmoi 实际源目录对应的 Git 工作区，传给 `adopt init --repo`，再 `adopt sync`：按 `packages.toml` 装系统包（apt / dnf / brew，会提示 sudo）、pixi global 工具、npm 全局包，再执行安装脚本（magpie）
4. `chezmoi apply`：下载 oh-my-zsh 和插件，把登录 shell 改成 zsh

无人值守（cloud-init、没有终端）时不提问，用环境变量或默认值：

```sh
curl -fsSL .../bootstrap.sh | ADOPT_GROUPS=homelab DOTFILES_GIT_EMAIL=me@example.com bash
```

可用变量：`DOTFILES_REPO`、`ADOPT_GROUPS`、`PIXI_REPOURL`、`DOTFILES_GIT_NAME`、`DOTFILES_GIT_EMAIL`。
此时 adopt 只会用免密的 `sudo -n`，拿不到就跳过系统包，之后登录手动运行 `adopt sync` 补上。
但 **git 是启动前置依赖，不能跳过**：缺少 git 且无法取得安装权限时，bootstrap 会停止；请预先安装系统 git。

### 旧版 bootstrap 提示「不是 git 仓库」

旧脚本把系统 git 留到 `adopt sync` 才安装，但 `adopt init` 已经需要外部 `git`。
chezmoi 在没有外部 git 时可以用内置实现完成 clone，所以看到此报错不代表仓库真的损坏。
adopt 0.3.0 会把 git 调用失败也报成「不是 git 仓库」。

在 Ubuntu / Debian 上，可以先安装 git，再从中断处继续（不需要删除任何目录）：

```sh
sudo apt-get update && sudo apt-get install -y git
export PATH="$HOME/.pixi/bin:$PATH"
# 必须输出 true；如果仍报错，先处理 Git 的具体错误，不要删除源目录。
git -C "$(chezmoi source-path)" rev-parse --is-inside-work-tree &&
  adopt init --repo "$(git -C "$(chezmoi source-path)" rev-parse --show-toplevel)" &&
  adopt sync && chezmoi apply
```

Rocky / Fedora 对应的安装命令是 `sudo dnf install -y git`。
修复版 bootstrap 发布到 GitHub 后，也可以直接重跑页面顶部的一键命令；已有 pixi、adopt、chezmoi 和源目录会复用。

## 日常

| 场景 | 做法 |
|---|---|
| 装软件 | 照官方文档：`sudo apt install htop`、`pixi global install ripgrep`、`pixi global install -c <channel> setproxy`、`npm install -g pyright` |
| 决定同步哪些 | 提示符出现 `📦 N` 时运行 `adopt`：逐个选「所有机器 / 指定分组 / 仅本机 / 忽略 / 稍后」，然后自动提交推送 |
| 改配置 | 直接编辑 `~/.zshrc` 等（它们是指向仓库的软链接），提示符出现 `dotfiles✎`，运行 `adopt` 时一起提交 |
| 其他机器拉取 | `adopt sync`（拉仓库 + 装缺的软件 + `chezmoi apply`） |
| 看清单 | `adopt list` |
| 卸载共享软件 | 照常卸载，运行 `adopt` 时选 `r` 从共享清单删除（`k` 只本机不装），其他机器 sync 时跟着卸（只卸 adopt 装的） |
| Python 环境 | `venv new ml --python 3.12`、`venv switch ml`、`venv add numpy`、`venv rm ml`，只在本机，不进仓库（见下文） |
| 临时用一次 | `pixi exec <pkg>`，不留痕迹 |
| 升级全局工具 | `pixi global update`、`npm update -g`（claude 会自我更新） |
| 撤销本机误改的配置 | `chezmoi git -- checkout -- <文件>` |

安装脚本往 `~/.zshrc` 追加的内容（nvm、conda init 之类）也会出现在仓库 diff 里：想保留就在 `adopt` 时提交，不想要就 checkout 掉。

### 定时同步（可选）

```sh
# crontab -e。PATH 要带上 ~/.pixi/bin，否则 adopt 找不到 chezmoi，会跳过 chezmoi apply
17 * * * * PATH="$HOME/.pixi/bin:/usr/bin:/bin" adopt sync --yes >/dev/null 2>&1
```

## 清单

`packages.toml` 由 adopt 维护，也可以手动编辑：

- `[system.<名字>]`：系统包。默认各平台同名，不同名写 `dnf = "openssh-clients"`，某平台不装写 `brew = false`。
- `[pixi.<环境>]`：pixi global 环境，格式与 `~/.pixi/manifests/pixi-global.toml` 一致。adopt 直接写这个 manifest，所以它**不是**软链接。
- `[npm."<包名>"]`：npm 全局包，可选 `version = "^1.2"`。adopt 不主动升级，只在 `version` 改了时重装。
- `[script.<名字>]`：只有官方安装脚本的软件。`creates` 路径存在就算已装，否则执行 `install`；只在 `install` 改了时重跑。adopt 发现不了这类软件，要手写进清单。`adopt sync --yes`（包括 cron）会直接执行这些命令，只写信得过的。
- 只属于本机的选择（只本机 / 忽略 / 基线）在 `~/.config/adopt/local.toml`，不进仓库。

系统包和 pixi 的分工：git、zsh、curl、ssh、证书、编译工具链走系统包管理器。pixi 装的 git 不读 `/etc/gitconfig`、
只信 conda 自带的 CA、没有 libsecret / 钥匙串凭据助手，而且 IDE、cron 用的是系统 PATH。
其余 CLI 工具（starship、node、uv、rg / fd / fzf / jq）走 pixi：新版本、跨平台一致、不需要 sudo。

只在 npm 上发布的工具（Claude Code、codex 等）走 npm。node 由 pixi 提供（`[pixi.nodejs]`，锁在 LTS 大版本），
不用 fnm / nvm。npm 的全局 prefix 在 `~/.npmrc` 里设成 `~/.local`：包在 `~/.local/lib/node_modules`，命令在 `~/.local/bin`。
默认 prefix 在 pixi 的 nodejs 环境里，pixi 升级或重建环境时包会丢，adopt 也会拒绝往那里装。

## 目录

| 源文件 | 目标 | 作用 |
|---|---|---|
| `packages.toml` | — | 软件清单（adopt） |
| `bootstrap.sh` | — | 新机器初始化 |
| `dot_zshenv` | `~/.zshenv` | PATH（非交互 zsh 也生效） |
| `dot_zshrc` | `~/.zshrc` | zsh 交互配置 |
| `dot_pixi/config.toml` | `~/.pixi/config.toml` | pixi 全局配置（default-channels 等） |
| `dot_config/starship.toml` | `~/.config/starship.toml` | 提示符，含 `📦`（adopt 待处理）和 `dotfiles✎`（配置未提交） |
| `dot_gitconfig.tmpl` | `~/.gitconfig` | git 用户信息、别名；本机设置放 `~/.gitconfig.local` |
| `.chezmoiexternal.toml` | `~/.oh-my-zsh` | oh-my-zsh 与插件（git clone），每周 pull |
| `create_dot_npmrc` | `~/.npmrc` | npm 全局 prefix；只在不存在时创建，之后是本机文件 |
| `run_onchange_after_90-login-shell.sh` | — | 把登录 shell 改成 zsh |

不进仓库的本机文件：`~/.zshrc.local`（密钥、本机专属配置）、`~/.gitconfig.local`、`~/.npmrc`（创建后，含 registry token）、
`~/.config/pixi/config.toml`（如公司镜像，pixi 会与 `~/.pixi/config.toml` 合并读取）、`~/.config/adopt/local.toml`、
`~/.config/venv/config.toml` 和 `~/.venvs/`。

注意：
- 不要移动或删除 `~/.local/share/chezmoi`，home 下的软链接都指向它。
- `.gitattributes` 强制 LF 换行，避免某台机器的 `core.autocrlf=true` 把脚本检出成 CRLF。

## Python 环境

用 [venv](https://github.com/ChengHongxu/venv) 管理 `~/.venvs/<名字>/`，后端默认 pixi，也可以 `--backend uv` 或 `--backend venv`。
仓库只负责装好 venv 和 shell 集成，环境本身每台机器按需 `venv new`，不同步。

想让新 shell 自动激活某个环境，在本机写 `~/.config/venv/config.toml`（不进仓库）：

```toml
auto_activate = "default"
```

uv 只作为普通工具保留：别人用 uv 管理的项目（`uv.lock`）、`uvx` 运行只在 PyPI 上的工具、PEP 723 单文件脚本、构建 / 发布 wheel，以及 venv 的 uv 后端。

## 公司网络：私有 CA

pixi 装的工具（Python requests / certifi、node）默认不信任系统证书库。在 `~/.zshrc.local` 中指向系统证书包：

```sh
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=$SSL_CERT_FILE
export NODE_EXTRA_CA_CERTS=$SSL_CERT_FILE
```
