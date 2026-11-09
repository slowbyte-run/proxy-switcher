# fish 不是受管载体，只通过 env 加载

`$SHELL` 是 fish 时，shell 载体仍然只写 `~/.zshrc`（回退规则不变），不会去碰 `~/.config/fish/config.fish`。fish 用户通过 `eval (proxysw env --shell fish | string collect)` 把值加载进当前会话。

## Why

fish 的语法与 POSIX 不同（`set -gx` / `set -e` 而非 `export` / `unset`），所以渲染层必须区分方言——这部分已经做了，`proxysw env --shell fish` 输出正确的 fish 语句。

但把它做成受管载体的收益很低，代价却很具体：fish 的 `config.fish` 没有 rc 文件那种「最后执行、之后的设置以它为准」的语义。用户在 `config.fish` 里随手写的 `set -gx http_proxy ...` 出现在片段之后就会静默覆盖本工具写入的值，而工具无从知道。要保证正确，只能要求用户把片段放在文件末尾并自行维护顺序——这等于把工具的语义责任转移给了用户，比「明确不支持」更容易让人误解。

另一条路是让 `off` 时也写 `set -e`。这会在 fish 里正确覆盖，但同样依赖片段位于文件末尾，问题没有消失，只是被藏得更深。

## Consequences

- `env` 在 `$SHELL` 不是 POSIX 家族时**报错退出 2**，而不是静默按 zsh 输出错误语法。用户必须显式 `--shell fish`，这是一次明确的表态。
- `env --shell` 接受 `bash`、`zsh`、`fish` 三个值；POSIX 家族（dash、ksh、sh、ash）共用一套渲染，所以不必逐个列出。
- 受管载体集合不变，仍是五个；fish 用户不会在 `status` 里看到第六个载体。
- 如果将来要支持 fish 载体，前提是先解决「片段在 `config.fish` 中的位置保证」，而不是只加一个渲染分支。
