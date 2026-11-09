# 命令名是 proxysw，不是 proxy

可执行文件叫 `bin/proxysw`，不是 `bin/proxy`。

## Why

`proxy` 这个名字在发行版里已经有主人。Arch 的 `libproxy` 包安装 `/usr/bin/proxy`，一个读取 stdin 并打印代理 URL 的 ELF；Ubuntu/Debian 上的 `proxy` 则被若干网络工具占用。用户把本仓库的 `bin/` 加进 `PATH` 之后，谁生效完全取决于 `PATH` 顺序——`proxy status` 可能被解析成 libproxy 的二进制，报出 `direct://` 之类的无关输出，而不是本工具的用法错误。

改名时还考虑过两个替代方案：

- 保留 `proxy`，只在 README 里警告 `PATH` 顺序。这要求用户记住一条隐性前提，而工具在误调用时不会给出任何提示——恰好是最难排查的一种失败。
- 同时提供 `proxysw` 和一层 `proxy` 转发壳。兼容层是给已有用户付的成本，而 v1 还没有外部用户；更糟的是 `tests/launcher.bats` 里那批符号链接用例会全部指向转发壳而不是真入口，测试从此不再证明真实安装路径可用。

## Consequences

- 所有文档、帮助文本与错误前缀（`proxysw: ...`）统一用新名字。项目名仍是 `proxy-switcher`，模块名仍是 `proxy_*.py`；命令名与项目名不是一回事。
- 用户若已把 `proxy on` 写进 dotfiles 或快捷键，需要改成 `proxysw on`。这是一次性成本，且改名发生在 v1 首次进入 `main` 时，外部影响面最小。
- 名字更短的两个候选 `px`、`prx` 被否决：它们与 `ps`、`pgrep` 的前缀重叠，手误成本高于省下的字符。
- 若将来要做兼容，正确的形态是新增一个明确的 `proxysw` 子命令或包装脚本，而不是把 `proxy` 塞回 `PATH` 抢名字。
