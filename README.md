# proxy-switcher

一个在 [niri](https://github.com/niri-wm/niri) 会话里统一开关 HTTP/HTTPS 代理配置的命令行工具。

**中文** | [English](README_EN.md)

<!-- Badge Row 1: Core Info -->
[![GitHub](https://img.shields.io/badge/GitHub-slowbyte--run-181717?logo=github)](https://github.com/slowbyte-run/proxy-switcher)
[![Version](https://img.shields.io/badge/version-0.1.0-orange)](https://github.com/slowbyte-run/proxy-switcher)

<!-- Badge Row 3: Tech Stack -->
[![Python](https://img.shields.io/badge/Python-3.11%2B-3776AB?logo=python)](https://python.org)

<!-- Badge Row 4: Platforms -->
[![Linux](https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black)](https://github.com/slowbyte-run/proxy-switcher)

<!-- Badge Row 5: License -->
[![License](https://img.shields.io/badge/License-MIT-BD2D2D)](LICENSE)

## 目录

- [为什么需要它](#为什么需要它)
- [功能特点](#功能特点)
- [工作原理](#工作原理)
- [安装](#安装)
- [快速开始](#快速开始)
- [命令参考](#命令参考)
- [配置](#配置)
- [载体详解](#载体详解)
- [退出码](#退出码)
- [测试](#测试)
- [已知限制](#已知限制)
- [开发](#开发)
- [License](#license)

## 为什么需要它

FlClash 之类的代理客户端，其「系统代理」开关在 Linux 上通常只修改 GNOME 的 gsettings 或 KDE 的 `kioslaverc`。niri 不属于这两者，它和大多数命令行程序一样，只认 `http_proxy`、`https_proxy` 这类环境变量和各自的配置文件。

结果就是代理设置散落在五六个互不相干的位置：niri 的 `environment {}` 块、shell 启动文件、`~/.npmrc`、pnpm 配置、`~/.ssh/config`、docker 的 `daemon.json`。想关代理得逐个文件手改，漏一个就会留下指向死端口的过期配置；想开回来又得凭记忆恢复原值。

`proxy-switcher` 把这些位置当作受管的「载体」，用一条命令统一开关，并在改动前自动快照。

## 功能特点

- **一条命令开关**：`on` / `off` / `toggle` 作用于全部受管载体，也可只切其中一个。
- **五个载体，一处真相**：niri 环境块、shell rc、npm、pnpm、ssh；docker 只读展示。
- **可逆**：`restore` 按快照逐字节恢复开关前的文件内容。
- **可验证**：`off` 会把变量真正移除，`env | grep -i proxy` 能证明它干净。
- **Node fetch 也能用**：`on` 时额外写入 `NODE_USE_ENV_PROXY=1`，因为 Node 24+ 的 `fetch` 默认不读环境变量。
- **冲突检测**：文件在开关后被外部修改时拒绝覆盖，`--force` 才放行。
- **原子写入**：临时文件 + rename，保留原有权限位。
- **无第三方运行时依赖**：Python 3.11+ 标准库即可运行。

## 工作原理

每个「载体」是一处存放代理设置的文件位置。共享引擎负责快照、冲突检测、原子写入与清单记录；载体只描述自己的路径，以及 `on` / `off` 时该渲染成什么。

| 载体 | 位置 | 写入内容 | 影响的工具 |
| --- | --- | --- | --- |
| `niri` | `~/.config/niri/config.kdl` 的 `environment {}` | 六个代理键 + `NODE_USE_ENV_PROXY` | niri spawn 的进程、非交互 git/curl、GUI 应用 |
| `shell` | `~/.zshrc` 或 `~/.bashrc` | 六个 `export` / `unset` + `NODE_USE_ENV_PROXY` | 交互式 shell 及其中的 git/curl |
| `npm` | `~/.npmrc` | `proxy`、`https-proxy`、`noproxy` | npm、yarn v1 |
| `pnpm` | `~/.config/pnpm/config.yaml` | `httpProxy`、`httpsProxy`、`noProxy` | pnpm |
| `ssh` | `~/.ssh/config` 的 `github.com` 主机块 | `ProxyCommand` | GitHub SSH |
| `docker` | `/etc/docker/daemon.json` | 只读展示 | docker daemon |

**覆盖关系**：交互式 shell 以 `shell` 载体为准，其余由 niri spawn 的进程以 `niri` 载体为准。因此两个载体关闭时都会写显式 `unset` / `null`，而不是依赖「键不存在」——否则另一方的值会漏下来。

具体到 git 和 curl：你在终端里敲的命令属于交互式 shell，归 `shell` 载体；`shell` 关闭时它们拿不到代理，即使 `niri` 是开启的。只有由 niri 或某个 GUI 程序直接 spawn、不经过 shell rc 的进程，才归 `niri` 载体。

写完 niri 配置后，工具会调用 `niri msg action load-config-file`，对之后新启动的进程生效。

## 安装

需要 Linux + niri、Python 3.11+，以及可选的 `niri` 二进制（存在时工具会在写完配置后请它重新加载，不存在时只是给出提示，不影响开关本身）。

```bash
git clone https://github.com/slowbyte-run/proxy-switcher
cd proxy-switcher
export PATH="$PWD/bin:$PATH"
```

命令名是 `proxysw` 而不是 `proxy`：发行版的 `libproxy` 包已经占用了 `/usr/bin/proxy`，叫 `proxy` 会让谁生效取决于 `PATH` 顺序，且误调用时不会报错。原因见 [ADR 0005](docs/adr/0005-command-name-is-proxysw.md)。

想装到 `~/.local/bin` 时，符号链接即可，启动器会自己解析到仓库真实路径：

```bash
ln -s "$PWD/bin/proxysw" ~/.local/bin/proxysw
```

无需构建、无需包管理器。运行测试需要 [bats](https://github.com/bats-core/bats-core) 与 PyYAML。

## 快速开始

查看当前状态（只读，安全）：

```bash
proxysw status
```

先预览将要改动的文件：

```bash
proxysw --dry-run on
```

开启全部载体，然后把状态注入当前 shell：

```bash
proxysw on
eval "$(proxysw env)"
```

关闭代理：

```bash
proxysw off
```

只切换 pnpm 或检查本地代理端口是否在监听：

```bash
proxysw toggle pnpm
proxysw status --check
```

把文件恢复到第一次开关之前的原状：

```bash
proxysw restore
```

## 命令参考

| 命令 | 说明 |
| --- | --- |
| `proxysw on [载体...]` | 开启；不带载体则作用于全部受管载体 |
| `proxysw off [载体...]` | 渲染规范的无代理状态 |
| `proxysw toggle [载体...]` | 任一所选载体不是 `on` 时整体转 `on`，全为 `on` 时转 `off` |
| `proxysw restore [载体...]` | 按快照逐字节恢复；原文件本不存在则删除 |
| `proxysw status [--check] [--json] [--short] [--require-up]` | 查看状态；`--check` 探测端点端口，`--json` 输出机器可读结构，`--short` 只列载体与状态，`--require-up` 在端点不通时以退出码 1 结束 |
| `proxysw env [--shell <name>] [--json]` | 输出 `export` / `unset` 语句供 `eval` 使用；`--shell` 选 bash、zsh 或 fish，`--json` 输出同一份决策的结构化形式 |

| 选项 | 适用于 | 说明 |
| --- | --- | --- |
| `--proxy <url>` | 所有命令 | 覆盖配置中的端点 |
| `--force` | 开关与恢复 | 越过冲突检测 |
| `--dry-run` | 开关与恢复 | 只打印将改动的载体与文件，不写盘 |
| `-v`, `--verbose` | 开关与恢复 | 逐载体说明做了什么 |
| `--check` | `status` | 有界的本地 TCP 端口探测，不发起 HTTP 请求 |
| `--short` | `status` | 只输出载体与状态两列，窄终端可用 |
| `--require-up` | `status` | 端点不通时退出 1；隐含 `--check` |
| `--shell <name>` | `env` | `bash`、`zsh` 或 `fish`；不指定时按 `$SHELL` 推断 |
| `--json` | 所有命令 | 机器可读输出，stdout 上只有一份文档，顶层带 `schema` 字段 |
| `-V`, `--version` | 所有命令 | 打印版本并退出 |
| `-h`, `--help` | 所有命令 | 帮助 |

机器可读输出适用于状态栏与包装脚本：`proxysw status --json` 给出各载体状态，`proxysw --dry-run on --json` 给出变更计划，`proxysw on --json` 会在真正写盘之后给出同一份文档（`dry_run` 为 `false`，每个载体带 `written` 与 `pending_reload`），三者顶层都有 `schema`，字段变更时会递增。人话进度一律走 stderr，所以 stdout 可以整份交给 `jq`。`--verbose` 与 `--json` 互斥。本仓库暂不提供 TUI。

`off` 与 `restore` 的区别是刻意的：`off` 把配置渲染成「没有代理」，而 `restore` 才回滚到开关前的字节。原始文件本就可能含代理值，若 `off` 走回滚，「关闭」就会变成「把代理装回去」。设计取舍见 [ADR 0003](docs/adr/0003-off-renders-no-proxy-restore-recovers.md)。

## 配置

配置文件位于 `$XDG_CONFIG_HOME/proxy-switcher/config.toml`（通常是 `~/.config/proxy-switcher/config.toml`）：

```toml
endpoint = "http://127.0.0.1:7890"
no_proxy = "localhost,127.0.0.1,::1"
exclude = ["ssh"]
```

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `endpoint` | `http://127.0.0.1:7890` | 代理端点，只接受 http URL |
| `no_proxy` | `localhost,127.0.0.1,::1` | 只支持域名与 IP 字面量，不承诺 CIDR 语义 |
| `exclude` | `[]` | 永不改动的载体名 |

状态与快照存放在 `$XDG_STATE_HOME/proxy-switcher/manifest.json`。

## 载体详解

**niri**：只改 `environment {}` 内的六个代理键与 `NODE_USE_ENV_PROXY`，保留 `LANG`、`QT_QPA_PLATFORM` 等其余变量与注释。`off` 写 `null` 以显式移除；若 `on` 新建了该块，`off` 会把它移除。它影响 niri 直接 spawn 的进程（GUI 应用、终端窗口），git/curl 只有在不经过 shell rc 时才算在内。

**shell**：维护一段带起止标记的片段。`on` 写六个 `export` 加 `export NODE_USE_ENV_PROXY=1`；`off` 写六个显式 `unset`，以便覆盖 niri 块。**`off` 不会 `unset` 这个 Node 开关**——它只是「允许 Node 读环境变量」，你可能在片段之外自己设置过，移除会静默覆盖你的写法。按 `$SHELL` 选择 `~/.zshrc` 或 `~/.bashrc`，其他 shell 回退到 zsh 配置。终端里的 git/curl 归它管。

fish 不是受管载体（见 [ADR 0006](docs/adr/0006-fish-is-not-a-managed-carrier.md)）：fish 的 `config.fish` 没有「最后执行」的保证，写进去的片段很容易被用户自己的 `set` 覆盖。fish 用户改用 `eval (proxysw env --shell fish | string collect)` 把值加载进当前会话。

**npm / pnpm**：分别写各自配置文件中的三个键。npm 保留 600 权限、替换已有键而不追加重复项；pnpm 采用行级编辑，保留注释、缩进与缩进风格。

**ssh**：只改 `github.com` 主机块中的 `ProxyCommand`，`off` 写 `none`，其他 Host 块逐字节不变。关闭后 GitHub SSH 将直连——若网络环境直连不可达，`git push` 会失败，`status` 会提示这一点。

## 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功 |
| `1` | 冲突或执行失败 |
| `2` | 用法错误 |

## 测试

```bash
./scripts/check          # 风格、shell 风格与全量测试，提交前跑这个
./scripts/check lint     # 只跑风格检查，约 0.2 秒
PROXYSW_CHECK_JOBS=8 ./scripts/check   # 本机并行跑全量测试
```

`scripts/check` 里的工具版本与 `.pre-commit-config.yaml` 一致，CI 也跑同样三个工具。

每个用例都在 `$BATS_TEST_TMPDIR` 下构造临时的 `HOME` 与 XDG 目录，并把一个只记录参数的桩 `niri` 放到 `PATH` 最前面。测试离线、不使用 sudo、不触碰真实的用户配置或真实的合成器。

```bash
bats tests/niri.bats
bats --filter 'restore' tests/
```

## 已知限制

- 只适用于 Linux + niri；其他桌面环境未测试。
- docker 只读：修改 `daemon.json` 需要 root，并且必须重启 daemon，会终止运行中的容器。
- systemd `--user` 服务不受管理：`set-environment` 影响不到 niri 已运行的进程。
- 已在运行的进程不会热更新，只影响之后新启动的进程。
- 从 DMS 启动器拉起的应用继承的是 DMS 启动时的环境，可能需要重启 DMS 才能看到新值。
- 不写 `all_proxy` / `ALL_PROXY`，也不解析 FlClash 的私有配置。
- fish 不是受管载体：`proxysw env --shell fish` 输出正确语法，但不会写入 `config.fish`。
- 并发开关会排队（默认最多等 5 秒，超时退出 1），不会交错执行。
- TUI 与状态栏插件尚未提供。

## 开发

```
bin/proxysw               启动器，仅 exec Python 入口
libexec/proxy_cli.py      唯一的参数解析与 usage
libexec/proxy_engine.py   快照、冲突检测、原子写入、清单
libexec/proxy_helper.py   配置、状态输出、env 与端口探测
libexec/proxy_common.py   六个变量、状态枚举、共享文本工具
libexec/kdl.py            保留注释与偏移的 KDL 编辑
libexec/carriers/         每个载体一个模块 + 注册表
tests/                    bats 黑盒测试
```

新增载体只需两步：在 `libexec/carriers/` 下新建模块并导出 `CARRIER`，然后把模块名加入 `carriers/__init__.py` 的 `MODULES`。共享引擎不需要改动。

## License

[MIT](LICENSE)
