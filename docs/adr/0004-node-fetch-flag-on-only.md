# Node 的 fetch 开关只在 on 时写入

Node 24+ 的内置 `fetch` 默认不读 `http_proxy` / `https_proxy`，需要 `NODE_USE_ENV_PROXY=1`（或命令行 `--use-env-proxy`）才会读取。工具在 `on` 时把它写进两个环境载体：niri 的 `environment {}` 块与 shell 片段。

但 `off` 的行为是不对称的：niri 块里写 `null` 把它移除，shell 片段里**不写** `unset`。

原因：它不是一个代理值，而是「允许 Node 读环境变量」的开关。用户可能已经在 rc 里手写过它（本机就是如此）；如果 `off` 写 `unset`，会静默覆盖那行手写设置，并改变其他依赖该开关的进程行为。六个代理变量被移除后，这个开关留着也不会产生任何代理效果。

## Consequences

- `proxysw env` 在 shell 载体为 `on` 时输出七行（六个变量加该开关），`off` 时仍只输出六行 `unset`。
- 载体状态判定只看四个 URL 变量；这个开关不会让某个载体显示为 `on`。
- 从 niri 直接 spawn 的 Node/Electron 应用现在也能读环境变量，这是之前唯一的覆盖空洞。
