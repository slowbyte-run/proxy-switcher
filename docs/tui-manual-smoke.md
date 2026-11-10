# TUI 真实 fzf 人工冒烟清单

`tests/tui.bats` 用 stub fzf 覆盖退出码、选择过滤、确认与落盘；真实 fzf 的渲染、键位和窄终端表现不在自动化门禁里。发布前在真实终端按本清单逐项执行并勾选；失败项先修复，或在发布说明里明确记为已知问题。

## 前置：先隔离真实 HOME 和合成器

`tui` 最终会通过 CLI 写载体文件，而 shell 片段在 `$HOME/.bashrc`、npm 在 `$HOME/.npmrc`、ssh 在 `$HOME/.ssh/config`，它们都跟着 `HOME` 走；只重定向 XDG 目录保护不了这些文件。`niri` 载体还会在写盘后调用真实合成器 reload。

所以在任何 `proxysw` 调用之前，先在一个新终端里执行下面的片段：`HOME`、XDG 目录和运行时目录全部指向临时树，`SHELL` 固定为 bash（让 shell 载体的路径确定；fish 不是受管载体），`niri` 用只记录参数的 stub 顶掉。清单里的写盘命令只在这个环境里执行；真实 dotfiles、真实锁目录和真实合成器都不会被碰到。

```bash
smoke="$(mktemp -d)"
export HOME="$smoke/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$smoke/run"
export SHELL="$(command -v bash)"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/niri" "$XDG_CONFIG_HOME/pnpm" \
  "$XDG_CONFIG_HOME/proxy-switcher" "$HOME/.ssh" "$XDG_RUNTIME_DIR" "$smoke/bin"
cat > "$smoke/bin/niri" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/niri-reload.log"
exit 0
STUB
chmod +x "$smoke/bin/niri"
export PATH="$smoke/bin:$PATH"
```

开始前确认四件事：

- 全程在同一真实终端里操作（不是管道、不是 CI），`tui` 需要交互式终端和真实 fzf。
- `echo "$HOME"` 输出 `$smoke/home`，`echo "$XDG_RUNTIME_DIR"` 在 `$smoke` 下。
- `command -v niri` 输出 `$smoke/bin/niri`（不是系统里的真实 niri）。
- `command -v proxysw` 指向本次要验证的安装或 checkout；fzf 已安装且 `fzf --version` 可运行，或设置了 `PROXYSW_FZF`。

有临时 `HOME` 就不必再备份真实配置。冒烟结束后 `rm -rf "$smoke"`；要回到真实环境，打开一个新终端即可。

## 准备状态

在沙箱里先制造混合状态，并用 `status` 确认：

```bash
proxysw on niri
proxysw off shell
proxysw status
```

预期 niri 为 `on`、shell 为 `off`。docker 只是只读信息，不需要准备。

## 清单

- [ ] **列表**：`proxysw tui` 打开全屏列表，顺序为 niri、shell、npm、pnpm、ssh；输入 `pn` 能过滤到 pnpm；Tab 多选、Ctrl-A 全选、Enter 应用、Esc 取消都可用。
- [ ] **头部**：显示 `endpoint ... up|down`、`docker: unmanaged (read-only)` 和 `excluded: ...`；端点 `down` 只是警告，不阻塞操作。再往 `$XDG_CONFIG_HOME/proxy-switcher/config.toml` 写入 `exclude = ["ssh"]` 并重开：头部显示 `excluded: ssh`，ssh 不出现在可选行；验证后删除该文件。
- [ ] **预览**：右侧预览显示 path、tools、note、flags、state；先 `printf '//registry.npmjs.org/:_authToken=smoke-token\n' > "$HOME/.npmrc"`，确认预览里不出现文件内容或这个假 token。
- [ ] **颜色**：`on` 为绿色，`off` 为黄色；混合状态能一眼扫读。
- [ ] **窄终端**：把终端缩到约 80×24，列表、两行头部、预览和键位提示仍可读，没有被截断到不可用。
- [ ] **Esc**：在列表里按 Esc，退出码 0，输出 `cancelled`，载体文件不变。
- [ ] **空选择**：输入一个匹配不到任何行的过滤词（例如 `zzz`）再按 Enter；fzf 以 1 退出，输出 `nothing selected`，退出码 0，不写盘。注意真实 fzf 的 Enter 会选中当前聚焦行（`--multi` 下也一样），所以「不选任何行直接 Enter」不是空选择，而是会应用该行。
- [ ] **缺 fzf**：`PROXYSW_FZF=/nonexistent proxysw tui`，退出码 2，提示安装 fzf 或设置 `PROXYSW_FZF`，不写盘。
- [ ] **混合状态**：niri 开、shell 关时运行 `proxysw tui` 并选中两者；确认行只点名 shell（`Will turn on: shell`），确认后两者都为 `on`，结果逐载体打印。
- [ ] **拒绝确认**：选中一个载体后在确认行输入 `n`，退出码 0，文件不变。
- [ ] **动作与透传**：`proxysw tui off`、`proxysw tui on`、`proxysw tui on --proxy http://127.0.0.1:9` 各走一遍；头部端点随 `--proxy` 变化，应用后载体写入该端点。
- [ ] **Ctrl-C**：在列表里按 Ctrl-C，退出码 0，输出 `cancelled`，文件不变。
- [ ] **配置非法**：在 `$XDG_CONFIG_HOME/proxy-switcher/config.toml` 写入 `endpoint = "socks5://127.0.0.1:7890"` 后运行 `proxysw tui`，退出码 1，错误信息与 `proxysw status` 一致，且 fzf 没有打开；之后删除该文件恢复默认配置。

## 记录

跑完后记录日期、fzf 版本、终端尺寸和结果；失败项附上输出与复现步骤。
