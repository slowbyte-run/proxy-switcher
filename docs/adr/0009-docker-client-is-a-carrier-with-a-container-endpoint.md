# docker 客户端配置是受管载体，但端点要从容器一侧看

docker 有两层代理配置，名字相近、作用完全不同：

- `/etc/docker/daemon.json` 的 `proxies` 由 dockerd 读取，决定 `pull`/`push` 怎么出站。改它要 root，改完要重启 daemon，会终止运行中的容器。
- `~/.docker/config.json` 的 `proxies.default` 由 docker CLI 读取，在新建容器和构建时把 `HTTP_PROXY`、`NO_PROXY` 等变量注入进去。它是用户文件，保存即生效，不需要重启。

v1 只把第一层只读展示（ADR 0002），第二层一直没人管。可第二层恰恰会过期：代理关掉之后，下一次 `docker compose up` 新建的容器仍然带着 `http://172.17.0.1:7890`，报错是 `connection refused`，而不是「代理没开」。它和 niri 环境块、shell rc 是同一类东西——写下一次创建要用的值——只是读者换成了容器。

## Decision

`docker` 成为第六个受管载体，只拥有 `~/.docker/config.json` 里 `proxies.default` 的两个 URL 键：

- `on` 写 `httpProxy`/`httpsProxy`；`off` 只删这两个键，`proxies` 删空就连 `proxies` 一起删，但**永不删文件**——`docker login` 可能后来往里写了 `auths`。
- `noProxy`、per-daemon 条目（`proxies."tcp://…"`）、`auths`/`credsStore`/`currentContext` 一律不动。容器里的 `localhost`/`127.0.0.1` 豁免没有意义，项目级的 `postgres`、内网域名也不该由全局开关猜。`allProxy`/`ftpProxy` 存在时只警告「未受管，容器可能仍走代理」。
- 路径尊重 `$DOCKER_CONFIG`，默认 `~/.docker/config.json`；已有文件保留原 mode，新建用 `0600`。

容器端点与宿主端点分开：

- 宿主端点是 loopback 时，容器不能复用它（容器里的 `127.0.0.1` 是容器自己），此时从 `docker network inspect bridge` 的网关推导。
- 宿主端点不是 loopback（例如局域网里的代理）时直接复用。
- `container_endpoint` 可以显式覆盖，推导因此不是唯一出路；推导失败（docker 未运行、没有 bridge 网络）时该载体不写，只警告，开关本身成功。
- 不是每个容器都能看到这个地址：compose 自建网络的网关可能是别的网段，rootless 又是另一套。所以覆盖项是设计的一部分，不是补丁。

冲突检测按受管键的指纹，而不是整文件哈希。`~/.docker/config.json` 会被 docker 自己整文件重写（`login`/`logout`、`context use`、access-token 刷新）；整文件哈希会让每次 docker 动过之后的下一次开关都变成 conflict，`--force` 从护栏变成日常。引擎因此多一个可选的 `managed_fingerprint` 钩子，只有 docker 实现；`restore` 仍回放整文件快照。

原来的只读行改名 `docker-daemon`，继续只读：`pull` 的代理是 root 的事，ADR 0002 的理由没变。

## Considered Options

- **维持只读**：客户端这一层是唯一非 root 能修的一半，继续展示而不修，等于承认「会过期但不管」。否决。
- **复用全局端点原样写**：容器里 `127.0.0.1` 指向容器自己，`docker build` 直接坏。否决。
- **五个键全归我们（含 `noProxy`）**：会丢掉项目级豁免（`postgres`、`host.docker.internal`、内网 API），关代理时更糟。否决。
- **整文件哈希**：见上，conflict 噪音。否决。
- **只读展示客户端值（不写）**：便宜，但开关仍然关不掉它，问题原地不动。否决。

## Consequences

- `proxysw on docker` 从「只读，报错」变成写文件；`docker` 这个名字的含义变了，`status --json` 的载体名也要跟着变。按 `feat!:` 记录。
- 覆盖率有边界：只影响「新建容器/构建里没有显式 proxy env」的进程；运行中的容器保留旧值（和 niri 环境块一样）；compose 里显式写 `HTTP_PROXY: ${HTTP_PROXY:-}` 的服务吃 `.env`/shell，不吃这个文件。界面和文档必须写明，否则就是 ADR 0002 骂过的「界面在撒谎」。
- `pull`/`push` 仍然走 daemon，仍然要 root + 重启；`docker` 行的 note 要指向 `docker-daemon`。
- `--json` 没有新字段，schema 仍为 2；变化的是载体名与状态。
- 关闭后 `noProxy` 留在文件里，惰性存在，无害；`restore` 回放快照时会连同它一起恢复。
- 引擎多一个可选钩子；ssh/npm 不受影响。
