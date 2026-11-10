# TUI 真实 fzf 人工冒烟清单

`tests/tui.bats` 用 stub fzf 覆盖退出码、选择过滤、确认与落盘；真实 fzf 的渲染、键位和窄终端表现不在自动化门禁里。发布前在真实终端按本清单逐项执行并勾选；失败项先修复，或在发布说明里明确记为已知问题。

## 前置

- 已安装 fzf 且 `fzf --version` 可运行；或设置 `PROXYSW_FZF` 指向它。
- 在真实终端（不是管道、不是 CI）里运行 `proxysw`。
- 建议先备份真实配置，或把 `XDG_CONFIG_HOME` / `XDG_STATE_HOME` 指向临时目录。
- 准备混合状态：例如先 `proxysw on niri`、再 `proxysw off shell`，用 `proxysw status` 确认 niri 为 `on`、shell 为 `off`。

## 清单

- [ ] **列表**：`proxysw tui` 打开全屏列表，顺序为 niri、shell、npm、pnpm、ssh；输入 `pn` 能过滤到 pnpm；Tab 多选、Ctrl-A 全选、Enter 应用、Esc 取消都可用。
- [ ] **头部**：显示 `endpoint ... up|down`、`docker: unmanaged (read-only)` 和 `excluded: ...`；被 `exclude` 的载体不出现在可选行；端点 `down` 只是警告，不阻塞操作。
- [ ] **预览**：右侧预览显示 path、tools、note、flags、state；先在 `~/.npmrc` 放一个假 token，确认预览里不出现文件内容或凭据。
- [ ] **颜色**：`on` 为绿色，`off` 为黄色；混合状态能一眼扫读。
- [ ] **窄终端**：把终端缩到约 80×24，列表、两行头部、预览和键位提示仍可读，没有被截断到不可用。
- [ ] **Esc**：在列表里按 Esc，退出码 0，输出 `cancelled`，载体文件不变。
- [ ] **空选择**：不选任何行直接 Enter，输出 `nothing selected`，退出码 0，不写盘。
- [ ] **缺 fzf**：`PROXYSW_FZF=/nonexistent proxysw tui`，退出码 2，提示安装 fzf 或设置 `PROXYSW_FZF`，不写盘。
- [ ] **混合状态**：niri 开、shell 关时运行 `proxysw tui` 并选中两者；确认行只点名 shell（`Will turn on: shell`），确认后两者都为 `on`，结果逐载体打印。
- [ ] **拒绝确认**：选中一个载体后在确认行输入 `n`，退出码 0，文件不变。
- [ ] **动作与透传**：`proxysw tui off`、`proxysw tui on`、`proxysw tui --proxy http://127.0.0.1:9999` 各走一遍；头部端点随 `--proxy` 变化，应用后载体写入该端点。
- [ ] **Ctrl-C**：在列表里按 Ctrl-C，退出码 0，输出 `cancelled`，文件不变。
- [ ] **配置非法**：临时写入 `endpoint = "socks5://127.0.0.1:7890"` 后运行 `proxysw tui`，退出码 1，错误信息与 `proxysw status` 一致，且 fzf 没有打开。

## 记录

跑完后记录日期、fzf 版本、终端尺寸和结果；失败项附上输出与复现步骤。
