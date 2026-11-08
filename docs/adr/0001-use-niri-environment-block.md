# 用 niri 的 environment 块作为 GUI 注入通道

niri 不是 GNOME 或 KDE，FlClash 的「系统代理」开关只改 gsettings 和 `kioslaverc`，niri 及其子进程读不到。我们决定：GUI 代理通过改写 `~/.config/niri/config.kdl` 的 `environment {}` 块、再调用 `niri msg action load-config-file` 生效，而不是常驻一个本地转发器、重启 niri，或去改 DMS 的环境。

依据：niri 启动时把该块解析成 `CHILD_ENV` 快照，每次 spawn 子进程时读取；`load-config-file` 会整体替换这份快照，对之后新 spawn 的进程立即生效。这是源码与官方文档双重确认的行为（niri 26.04）。

## Considered Options

- **本地转发器**：环境变量恒定指向转发器，`off` 时转发器直连。好处是不依赖 reload、GUI 天然跟随；被否决是因为它让「关闭代理」时流量仍经过一个本地进程，破坏了「配置真的不存在」这一可验证性，而可验证性正是这个工具的核心价值。
- **重启 niri**：reload 已能覆盖，重启代价无必要。
- **改 DMS 的环境**：DMS 只是 niri 的一个子进程，改它覆盖不了其他应用。

## Consequences

- 已运行的进程不会更新，这是环境变量的硬约束，不是缺陷。
- 从 DMS 启动器拉起、继承 DMS 启动时环境的应用能否拿到新值，取决于 DMS 的启动实现，尚未确认。
- `off` 时写 `http_proxy null` 而不是删掉整行：`null` 会显式 `env_remove`，防将来 niri 自身环境混入代理值。
