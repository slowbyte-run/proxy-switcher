# proxy-switcher

一个在 niri 会话里统一开关各工具 HTTP/HTTPS 代理配置的命令行工具。它要解决的问题是：FlClash 的「系统代理」开关只改 GNOME/KDE 的桌面设置，而 niri 与命令行程序只认环境变量和各自的配置文件。

## Language

**载体 (Carrier)**:
一个由本工具整体写入或还原的配置位置，也是快照与冲突检测的最小单位。v1 有五个：niri 的 `environment {}` 块、shell rc 片段、`~/.npmrc`、pnpm 的 `config.yaml`、`~/.ssh/config` 中 github.com 的主机块。
_Avoid_: 代理面、通道、配置源、注入点

**覆盖 (Override)**:
载体之间的取值优先关系。交互式 shell 以 shell rc 载体为准，其余由 niri spawn 的进程以 `environment {}` 块为准；任一方为 `off` 时都要显式 `unset`，而不是靠"没设置"来假装关闭。
_Avoid_: 优先级、继承规则

**开关状态 (Switch State)**:
某个载体当前的取值：`on`、`off`，或 `unmanaged`（只读展示，不受工具管理）。
_Avoid_: 启用/禁用、激活

**快照 (Snapshot)**:
执行开关前某个载体原始内容的完整副本，用于冲突检测与显式的 `proxysw restore`；`off` 不依赖快照，也不会把快照写回。
_Avoid_: 备份、存档、rollback 文件

**清单 (Manifest)**:
把每个快照与其载体、时间戳、原始哈希对应起来的索引；冲突检测以它为准。
_Avoid_: 索引文件、元数据、数据库

**重载 (Reload)**:
写完 niri 的 `environment {}` 之后，请合成器重新读取配置的动作。它只影响之后新启动的进程；重载没落地时开关本身仍然成功，但清单会记下这一点，`status` 在对应载体上显示 `written but not reloaded`。
_Avoid_: 刷新、热更新、生效

**开关事务 (Switch Transaction)**:
一次开关命令覆盖的完整读-改-写范围，从读清单到写回清单。并发开关互相等待而不是交错执行，因此不会有哪一次改动被另一次静默丢弃。
_Avoid_: 批量操作、批处理、原子操作

**端点 (Endpoint)**:
代理服务器的地址，默认 `http://127.0.0.1:7890`。
_Avoid_: 代理地址、proxy URL、server
