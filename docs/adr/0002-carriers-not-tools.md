# 开关以载体为单位，而不是以工具为单位

用户最初要求「逐工具开关」。但载体是共享的：niri 的 `environment {}` 块被所有 niri 子进程共用，shell rc 被所有交互式 shell 共用，`~/.npmrc` 被 npm 与 yarn v1 共用。

我们决定：v1 的开关单位是**载体**，共五行（niri 环境块、shell rc、npmrc、pnpm 配置、ssh 主机块），界面如实标注每行影响的工具，而不是伪造十几个互不相关的工具开关。shell rc 对 niri 环境块构成覆盖关系：交互式 shell 以 rc 为准，其余进程以 environment 块为准。

## Considered Options

- **按工具列，背后共享载体**：点「git」会连带改变 curl，界面在撒谎。否决。
- **每个工具写自己的配置文件**（git → `~/.gitconfig`、cargo → `config.toml`、pip → `pip.conf`、curl → `~/.curlrc`）：能逼近真正的逐工具独立，但 Go 没有代理配置文件、只能吃环境变量，这条路永远差一块；文件数从 4 涨到 10+，快照与冲突检测的复杂度翻倍。留作升级路径。

## Consequences

- 切换 niri 环境块会同时影响 git 与 curl 等命令行工具和 GUI 应用，这是设计属性而非缺陷，文档与界面都要说清。
- `docker` 不在受管载体内，v1 只读展示：需要 root，且改 `daemon.json` 后必须重启 daemon，会终止运行中的容器。若将来支持，必须是显式的 `proxy docker on|off` 并二次确认。
- `ssh` 是受管载体：只动 `~/.ssh/config` 中 github.com 主机块的 `ProxyCommand`，不碰其他 Host。`off` 后 GitHub SSH 将直连，而直连实测不可达，界面必须标出这一后果。
