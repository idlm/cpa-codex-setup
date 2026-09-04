# CPA + Codex 一键部署

把 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)（社区里常简称 **CPA**）部署到本机，并让 [OpenAI Codex CLI](https://developers.openai.com/codex) 通过它工作 —— 一条命令搞定，含 sha256 校验、systemd 托管、鉴权健康检查。

## 这解决什么问题

CPA 是一个协议转换代理：它把你手里的 **CLI 订阅**（ChatGPT Plus/Pro、Claude Pro/Max、Gemini、Kimi、xAI 等的 OAuth 登录态）包装成标准的 OpenAI / Claude / Gemini 兼容 HTTP 端点。

部署完成后你会得到：

- 一个本机端点 `http://127.0.0.1:8317`，任何 OpenAI 兼容客户端都能接
- Codex CLI 走本地代理，可自由切换 `gpt-5.6-sol` / `gpt-5.5` / `gpt-5.4-mini` 等模型
- 多账号轮询：登录几个账号就往 `auth-dir` 里多几个 json，配额用尽自动切换
- 同一个端点同时给 Claude Code、Cline、OpenCode 等工具复用

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | 任意 systemd 发行版（Debian / Ubuntu / RHEL 系 / Arch / openSUSE 都行） |
| 架构 | x86_64 或 aarch64 |
| 权限 | root（`sudo`） |
| 其他 | 没有了 —— 缺什么脚本自己装 |

脚本会检测包管理器（`apt` / `dnf` / `yum` / `pacman` / `zypper`）并自动补齐：

- **硬依赖** `curl` `tar` `sha256sum` `openssl` —— 装不上就中止，因为没法继续
- **软依赖** `python3`（`status.sh` / `autoresume.sh` 用）、`screen`（`watch` 模式用）—— 装不上只警告，主流程照跑
- **Node.js ≥ 18** —— Codex CLI 需要。apt 系走 NodeSource 装 22.x，其他发行版用自带仓库；装完仍不达标就跳过 Codex 而不是让整个部署失败（CPA 本身不需要 Node）

想自己管 Node 就加 `--skip-node`。

## 一键开始使用

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/cpa-codex-setup/main/install.sh | sudo bash
```

带参数时加 `-s --`，后面直接跟选项：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/cpa-codex-setup/main/install.sh \
  | sudo bash -s -- --port 9000 --model gpt-5.5

# 只装 CPA，不碰 Codex
curl -fsSL .../install.sh | sudo bash -s -- --skip-codex
```

管道模式下脚本读不到本地 `helpers/`，会自动从同一仓库的 raw 地址补齐三个辅助脚本模板，不需要 clone。

看全部选项：`sudo ./install.sh --help`，或见下面的[配置项](#配置项)。

**想先审再跑**（管道执行等于把 root 交给一个远端脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/idlm/cpa-codex-setup/main/install.sh -o install.sh
less install.sh
sudo bash install.sh --port 9000
```

**或者 clone 下来**（`helpers/` 在本地，改脚本更方便）：

```bash
git clone https://github.com/idlm/cpa-codex-setup.git && cd cpa-codex-setup
sudo ./install.sh
```

装完做什么：下载校验二进制 → 生成随机密钥 → 写配置 → 注册 systemd → 鉴权健康检查 → 装 Codex CLI 与 `config.toml` → 装 bubblewrap。全程幂等，重跑不会覆盖已有密钥和凭据。

常用变体：

```bash
sudo CPA_PORT=9000 ./install.sh          # 换端口
sudo SKIP_CODEX=1 ./install.sh           # 只装 CPA，不动 Codex
sudo CPA_VERSION=v7.2.149 ./install.sh   # 锁定 CPA 版本
sudo CODEX_MODEL=gpt-5.5 ./install.sh    # 换默认模型
```

## 第二步：登录上游账号

安装脚本不会替你登录 —— OAuth 需要人在浏览器里点授权。**必须在带 TTY 的真实终端执行**：

```bash
sudo /opt/cliproxyapi/login.sh
```

默认走**设备码流程**：终端打印一个 URL（`https://auth.openai.com/codex/device`）和一个形如 `XXXX-XXXXX` 的码，你在任意设备的浏览器里输码授权即可，**不需要 SSH 端口转发**。

其他 provider：

```bash
sudo /opt/cliproxyapi/login.sh claude    # Claude
sudo /opt/cliproxyapi/login.sh gemini    # Antigravity (Gemini)
sudo /opt/cliproxyapi/login.sh kimi
sudo /opt/cliproxyapi/login.sh xai
sudo /opt/cliproxyapi/login.sh codex     # OAuth 回调式，需先建 SSH 隧道
```

回调式登录要在**你的本地机器**上先开隧道，否则浏览器回调打不到服务器：

```bash
ssh -L 1455:127.0.0.1:1455 root@<服务器IP> -p 22
```

登录成功后凭据落在 `~/.cli-proxy-api/*.json`，服务通过 file watcher 自动热加载，**不需要重启**。验证：

```bash
curl -s -H "Authorization: Bearer $(sudo cat /root/.cli-proxy-api/.apikey.txt)" \
  http://127.0.0.1:8317/v1/models | python3 -m json.tool
```

## 使用

### Codex CLI

配置已默认指向本机 CPA，直接用：

```bash
codex                                  # 交互式 TUI
codex exec "重构 utils.py 里的重复逻辑"   # 非交互，适合脚本 / CI
codex exec review                      # 对当前仓库做代码审查
codex login status                     # 查看客户端侧状态
```

临时覆盖配置，不改文件：

```bash
codex -c model=gpt-5.4-mini exec "..."       # 换模型（更快更省）
codex -c model_reasoning_effort=medium       # 降推理档位
codex -c model_provider=<其他provider>        # 切到别的上游
```

要永久改默认，编辑 `~/.codex/config.toml` 顶部的 `model` 一行。

### 可用模型

取决于你登录的账号等级，以 `/v1/models` 实际返回为准。ChatGPT Plus 账号实测可见：

| 模型 | 说明 |
|---|---|
| `gpt-5.6-sol` | 最强推理，脚本默认 |
| `gpt-5.6-terra` / `gpt-5.6-luna` | 5.6 系列其他档位 |
| `gpt-5.5` / `gpt-5.4` / `gpt-5.4-mini` | 更快、更省 token |
| `gpt-5.3-codex-spark` | 轻量代码任务 |
| `codex-auto-review` | 自动代码审查专用 |
| `gpt-image-2` / `gpt-image-1.5` | 图像生成 |

### 其他客户端复用同一端点

CPA 同时暴露 OpenAI / Claude / Gemini 三套协议：

```bash
# OpenAI 兼容客户端
export OPENAI_BASE_URL=http://127.0.0.1:8317/v1
export OPENAI_API_KEY=$(sudo cat /root/.cli-proxy-api/.apikey.txt)

# Claude Code
export ANTHROPIC_BASE_URL=http://127.0.0.1:8317
export ANTHROPIC_AUTH_TOKEN=$(sudo cat /root/.cli-proxy-api/.apikey.txt)
```

## 高阶技巧

### 审批与沙箱：从最严到最松

Codex 默认会在执行命令前征求同意，并把写操作限制在工作区内。两个维度各自独立可调：

| 维度 | 取值 | 含义 |
|---|---|---|
| `-s, --sandbox` | `read-only` | 只读，模型不能改任何文件 |
| | `workspace-write` | 默认。可写工作目录、`/tmp`、`$TMPDIR` |
| | `danger-full-access` | 无文件系统限制 |
| `-a, --ask-for-approval` | `on-request` | 默认。模型自己判断何时该问你 |
| | `never` | 从不询问，执行失败直接回传给模型 |

组合使用，逐级放开：

```bash
codex -s read-only                          # 只让它看，最安全，适合代码审查
codex -s workspace-write -a on-request      # 默认组合
codex -s workspace-write -a never           # 不打断你，但仍受沙箱约束 ← 日常自动化推荐
codex --approve-for-me                      # 审批请求走自动审查（workspace-write 内）
```

### 完全放开：`--dangerously-bypass-approvals-and-sandbox`

```bash
codex --dangerously-bypass-approvals-and-sandbox "把整个项目迁移到 TypeScript"
codex exec --dangerously-bypass-approvals-and-sandbox "跑通所有测试并修掉失败项"
```

官方对这个 flag 的原话是 **EXTREMELY DANGEROUS**，用途明确写着「仅用于本身已被外部沙箱隔离的环境」。它同时关掉两道防线：所有确认提示消失，且命令不再受任何沙箱限制 —— 模型可以 `rm -rf`、改系统配置、写 `~/.ssh`、发起任意网络请求，没有一步会问你。

合理的用法是：**先隔离环境，再放开权限**，而不是反过来。

```bash
# 一次性容器，宿主机文件系统不受影响
# Linux 下 host.docker.internal 需要显式加 --add-host 才能解析
docker run --rm -it --add-host=host.docker.internal:host-gateway \
  -v "$PWD:/work" -w /work \
  -e OPENAI_BASE_URL=http://host.docker.internal:8317/v1 \
  -e OPENAI_API_KEY=$(sudo cat /root/.cli-proxy-api/.apikey.txt) \
  node:22 bash -lc 'npm i -g @openai/codex && codex exec --dangerously-bypass-approvals-and-sandbox "..."'
```

在自己的开发机上跑，只要 `-s workspace-write -a never` 就已经不打断你了，没必要连沙箱一起关。真要在宿主机上放开，至少确认工作目录在 git 里且已提交 —— 出事能 `git reset --hard` 回来。

还有一个相关的危险 flag：`--dangerously-bypass-hook-trust`，跳过 hook 来源的信任校验，只在你已经审过 hook 代码的自动化里用。

### 无人值守与结构化输出

`codex exec` 是脚本化入口，配合这几个选项能接进 CI：

```bash
codex exec --json "..."                          # 事件流以 JSONL 输出到 stdout
codex exec -o result.txt "..."                   # 只把最终回答写进文件
codex exec --output-schema schema.json "..."     # 用 JSON Schema 约束最终输出结构
codex exec --skip-git-repo-check "..."           # 允许在非 git 目录运行
codex exec --ephemeral "..."                     # 不落盘 session 文件
codex exec --ignore-user-config "..."            # 忽略 config.toml，只用命令行参数
```

拼起来就是一个能被程序消费的 agent：

```bash
codex exec --json -s read-only \
  --output-schema review-schema.json \
  -o review.json "审查 src/ 下的安全问题" | tee events.jsonl
```

### 会话复用

上下文是钱，别每次从零开始：

```bash
codex resume --last              # 接着上一个会话继续
codex resume                     # 交互式挑一个历史会话
codex fork --last                # 从上个会话分叉，试探性改动不污染主线
codex queue "顺便把 README 也更新一下"   # 给正在跑的会话追加一条消息
codex apply                      # 把 agent 产出的 diff 以 git apply 落到工作树
codex archive <id> / delete <id> # 归档 / 永久删除会话
```

### 配置 profile：一套环境多种人格

`-p <name>` 会把 `$CODEX_HOME/<name>.config.toml` 叠加到主配置之上。例如建 `~/.codex/fast.config.toml`：

```toml
model = "gpt-5.4-mini"
model_reasoning_effort = "low"
```

之后 `codex -p fast "改个错别字"` 就走廉价配置，主配置一行都不用动。适合按任务类型分档：`fast` / `review` / `deep`。

### 零散但好用

```bash
codex --search "查一下这个库最新的 breaking change"   # 开启联网搜索
codex -i screenshot.png "照这个设计稿实现组件"        # 附图
codex -C /path/to/repo "..."                        # 指定工作根目录
codex --add-dir ../shared-lib "..."                 # 额外授予可写目录
codex --no-alt-screen                               # 保留终端 scrollback，方便复制
codex doctor                                        # 诊断安装、配置、认证、运行时
codex sandbox <cmd>                                 # 手动在 Codex 沙箱里跑一条命令
codex mcp                                           # 管理 MCP 服务器
codex completion bash > /etc/bash_completion.d/codex # shell 补全
```

### CPA 侧：多账号池怎么调

以下都写在 `~/.cli-proxy-api/config.yaml`。服务对配置目录开了 file watcher，多数字段改完即生效，可用 `journalctl -u cliproxyapi -n 20` 确认加载。

> **先看这条，否则自动切换是关着的。** `config.example.yaml` 注释里写的「默认 3」「默认 30」是**示例文件里的推荐值，不是程序内置 fallback**。字段一旦在你的 `config.yaml` 里省略，生效值就是 Go 零值 —— `request-retry: 0`、`quota-exceeded.switch-project: false`、`routing: {}`。也就是说：一份极简配置跑起来，遇到 429 既不会重试也不会换号。本仓库的 `install.sh` 已经把这些字段显式写全，手写配置的话务必自己补上。用 `status.sh` 可以一眼看出当前到底是开还是关。

**自动切换：核心开关**

```yaml
request-retry: 3              # 首轮之外的额外重试轮数，每轮换用池中其他凭据
max-retry-credentials: 0      # 每轮最多试几个凭据，0 = 不限（可把整池试一遍）
max-retry-interval: 30        # 命中冷却时的最长等待秒数
save-cooldown-status: true    # 冷却状态持久化，重启不会把限流中的号立刻放回池子

quota-exceeded:
  switch-project: true        # 上游报配额耗尽时自动切到另一个可用凭据
  switch-preview-model: true  # 自动降级到 preview 模型
```

`request-retry` 是主开关，对 403 / 408 / 429 / 500 / 502 / 503 / 504 生效。切换是**被动**的：先撞到错误，再换下一个凭据重试，而不是提前预测哪个号快满了。

一个容易忽略的前提：**池里得有第二个号**。只登了一个账号时，限流了也无处可切，`request-retry` 调到 10 也没用 —— 先多跑几次 `login.sh`。

**选择策略**

```yaml
routing:
  strategy: "round-robin"   # 默认，轮流用
  # weighted-round-robin    # 按权重分配，主力号多跑
  # fill-first              # 填满一个再换下一个，最大化 prompt cache 命中
```

用 `weighted-round-robin` 时，权重写在凭据 JSON 的顶层（整数，默认 1，上限 1,000,000；非正数等于把该凭据摘出池子）：

```bash
# 给主力账号更高权重
python3 - <<'PY'
import json, pathlib
p = pathlib.Path('/root/.cli-proxy-api/codex-xxx.json')
d = json.loads(p.read_text()); d['weight'] = 5
p.write_text(json.dumps(d, indent=2))
PY
```

**会话粘性 —— 省 token 的关键**

```yaml
routing:
  session-affinity: true            # 同一会话始终绑同一个上游凭据
  session-affinity-ttl: "1h"
  session-affinity-subagents: true  # 子会话继承父会话的凭据
```

默认关闭。开启后同一对话的后续请求都落在同一个账号上，upstream 的 prompt/KV cache 才能复用，首 token 延迟和计费都会明显下降。代价是并发分散度变差 —— 追求并行吞吐就关掉它。

**冷却微调**

上面那组开关之外，还有两个控制冷却行为的字段：

```yaml
transient-error-cooldown-seconds: 0   # 0 = 沿用 60s 传统值，-1 = 关闭瞬时错误冷却
disable-cooling: false                # true = 出错的凭据不进冷却池
```

429 频繁的话先加账号，其次调 `request-retry`；把 `disable-cooling` 打开通常只会让失败更快重现。

**凭据池状态：`status.sh`**

自动切换是被动的，所以你需要一个能主动看清池子的入口：

```bash
sudo /opt/cliproxyapi/status.sh
```

它做两件事 —— 先把自动切换的几个开关的**实际生效值**打出来（不是你以为写了什么，而是服务真正读到什么），再列出池里每个凭据的配额与健康状况：

```
=== 自动切换配置 ===
  request-retry          3              额外重试轮数, 0 = 不会换凭据重试
  routing strategy       round-robin    多凭据选择策略
  ...

=== 凭据池 ===
  ACCOUNT                   PROV    PLAN   5H    RESET   7D    OK   FAIL  STATE
  ----------------------------------------------------------------------------
  you@example.com           codex   plus   100%  3h24m   16%   0    1     unavailable
      └─ {"error":{"type":"usage_limit_reached", ...}}
```

`5H` / `7D` 是主（5 小时窗口）和次（7 天窗口）配额的已用百分比，`RESET` 是主窗口的重置倒计时 —— 这些数字来自上游响应头（`X-Codex-Primary-Used-Percent` 等），CPA 会随请求学习并缓存。刚重启时显示 `-`，发一次请求就有了。

有了它，「为什么突然不动了」这类问题基本一眼就能定位：是号满了、是被冷却了、还是自动切换压根没开。

**模型改名**

```yaml
oauth-model-alias:
  codex:
    - name: "gpt-5.6-sol"       # 上游真实 id
      alias: "sol"              # 客户端看到的 id
      display-name: "Codex Sol"
```

按 channel 配置（`codex` / `claude` / `antigravity` / `aistudio` / `vertex` / `kimi` / `xai`）。注意别名**不作用于** `codex-api-key`、`claude-api-key`、`openai-compatibility` 这类显式 API key 块。

**走代理出网**

```yaml
proxy-url: "socks5://user:pass@127.0.0.1:1080"
```

支持 socks5 / http / https；单条凭据里也能写 `proxy-url`，填 `"direct"` 或 `"none"` 可以显式绕开全局代理和环境变量代理。

**管理 API**

`.mgmtkey.txt` 里的 key 可以直接调管理接口，不必手改 YAML：

```bash
MG=$(sudo cat /root/.cli-proxy-api/.mgmtkey.txt)
curl -s -H "Authorization: Bearer $MG" http://127.0.0.1:8317/v0/management/config | python3 -m json.tool
```

浏览器打开 `http://127.0.0.1:8317` 是自带的管理面板。远程访问需要 `remote-management.allow-remote: true` —— 开之前先想清楚暴露面。

**排查请求**

```yaml
debug: true            # 打印详细请求日志
logging-to-file: true  # 日志落盘而非只进 journald
```

调完记得关掉 `debug`，它会把请求内容写进日志。

### 限流自动续跑：`autoresume.sh`

自动切换的前提是池里还有别的号。**只有一个账号、或者所有账号的窗口都用满时，CPA 无处可切**，长任务就卡在那里 —— 交互式 TUI 显示 `■ You've hit your usage limit. Try again later.`，`codex exec` 则以 exit 1 退出并打印 `ERROR: exceeded retry limit, last status: 429 Too Many Requests`。

`autoresume.sh` 就是补这一段：算出最早的窗口重置时刻，睡到那个点，然后自动续跑，循环到任务做完。

```bash
# 模式一：让脚本自己跑 codex exec（推荐，最可靠）
screen -dmS cpa-run /opt/cliproxyapi/autoresume.sh run -C /path/to/repo "把测试全部跑通并修掉失败项"
tail -f /root/.cli-proxy-api/autoresume.log

# 模式二：监控你已经手动开着的交互式 TUI
screen -S cpa-codex                                  # 里面手动跑 codex
/opt/cliproxyapi/autoresume.sh watch -s cpa-codex    # 另一个终端
```

`run` 模式首轮新建会话，之后每轮用 `codex exec resume --last` 续接同一会话，上下文不丢。`watch` 模式靠 `screen -X hardcopy` 抓屏检测，恢复后用 `screen -X stuff` 把继续指令打进去。

**解封那一刻具体发生什么**

会自己接着跑，不需要你在场。以 `run` 模式为例，一次完整的限流—恢复循环是这样：

1. `codex exec` 撞到 429，以 exit 1 退出，脚本识别为限流
2. 查管理 API 拿到 `X-Codex-Primary-Reset-At`，算出还有多久，写进日志：`全部凭据限流中 → 等待 3h09m 至 09-04 08:29:16`
3. 分 120 秒一段睡过去，每段醒来重查一次池子
4. 到点（或中途你登了新号）→ 立即执行 `codex exec resume --last "继续未完成的工作"`，**接着上一个会话往下做**，不是从头重来
5. 如果新窗口又用满了，回到第 1 步；如果任务做完（exit 0），打印「任务完成」并退出循环

`watch` 模式同理，只是第 4 步换成往 screen 里 `stuff` 一条继续指令，由你原本那个交互式 codex 接着做。

整个过程无人值守。把脚本本身放进 screen（见上面第一条命令），SSH 断开也不影响 —— 醒来时看 `tail -f /root/.cli-proxy-api/autoresume.log` 就知道中间发生了什么。

选项：`-m N` 最大轮数（默认 24，每轮通常对应一个 5 小时窗口）、`-C DIR` 工作目录、`-s SESSION` 会话名、`-p SEC` 抓屏间隔、`-l SEC` 信号延迟冷静期（默认 90，见下）。

日志长这样：

```
[09-04 05:19:50] === run 模式启动 | 工作目录 /tmp | 上限 1 轮 ===
[09-04 05:19:50] 全部凭据限流中 → 等待 3h09m 至 09-04 08:29:16
```

几个值得知道的实现细节：

- **等待时长是查出来的，不是猜的。** 脚本从管理 API 读 `X-Codex-Primary-Reset-At` / `X-Codex-Secondary-Reset-At`，取真实 Unix 时间戳，再加 45 秒缓冲。不解析人类可读文本，也不用固定的「等 5 小时」。
- **7 天窗口也算进去了。** 如果次窗口（7d）同样满了，等主窗口重置是没用的 —— 脚本会取两者中更晚的那个。
- **睡觉期间仍在观察。** 分 120 秒一段睡，每段结束重新查一次池子。你中途登录了新账号，它会提前醒来继续干活，不用等到原定时刻。
- **多账号时它基本不会触发。** 只要还有一个号没满，`next_reset` 返回 0，脚本直接往下跑 —— 真正干活的是 CPA 的自动切换，`autoresume.sh` 只在整池耗尽时才介入。
- **信号延迟有保护。** CPA 的配额信号是从上游响应头学来的，可能滞后于实际的 429。若刚撞限流而 CPA 仍报可用，脚本会强制冷静 `-l` 秒（默认 90）再查，而不是立刻重试 —— 否则会在几秒内空转烧完所有轮数。
- **非限流失败会立刻停。** 只有识别到 429 / `exceeded retry limit` / `usage limit` 这类特征才等待重试；编译错误、路径不存在之类的失败会直接退出并把最后 15 行打出来，不会陷入无意义的循环。

这套控制流在真实环境跑通过 —— 一个 ChatGPT Plus 账号撞满 5 小时窗口后，无人值守等了 1 小时 33 分，解封后自动续跑并完成任务：

```
[09-04 06:55:42] === run 模式启动 | 工作目录 /tmp | 上限 3 轮 ===
[09-04 06:55:42] 全部凭据限流中 → 等待 1h33m 至 09-04 08:29:16
[09-04 08:29:20] 第 1 轮: 新建会话
                 ... codex 正常执行, 返回结果, 1485 tokens ...
[09-04 08:29:23] 第 1 轮正常结束 (exit 0) —— 任务完成
```

上游给的重置时刻是 `08:28:31`，脚本在 `08:29:20` 醒来 —— 比 `reset_at + 45s 缓冲` 晚 4 秒，那是分段睡眠的粒度（每段结束才重查一次）。整个过程没有人在场，screen 会话在任务完成后自行退出。事后 `status.sh` 显示配额已重置：`5H` 从 `100%` 回到 `0%`，状态 `unavailable → active`。

多轮循环、`watch` 模式和信号滞后保护另外用模拟环境验证（mock 管理 API 给受控的重置时间戳 + 假 codex 前两次返回 429、第三次成功）：

```
[06:23:14] 全部凭据限流中 → 等待 0m45s 至 06:23:59
[06:23:59] 第 1 轮: 新建会话
[06:23:59] 第 1 轮撞到限流 (exit 1), 转入等待
[06:23:59] 上游已限流但 CPA 配额信号尚未更新, 先冷静 8s 再查
[06:24:07] 第 2 轮: resume 续接上一会话
[06:24:07] 第 2 轮撞到限流 (exit 1), 转入等待
[06:24:15] 第 3 轮: resume 续接上一会话
[06:24:15] 第 3 轮正常结束 (exit 0) —— 任务完成
```

`watch` 模式的验证做了一步硬确认：screen 里跑 `cat > file`，测完那个文件里躺着「继续未完成的工作」—— 说明 `screen -X stuff` 真的把指令送进了会话 stdin，不只是日志里说送了。

最后一点值得说清楚：这是**遵守**限流 —— 撞到 429 就停手，等服务端告诉你的重置时刻到了再继续，本质上和 HTTP `Retry-After` 是一回事。它不绕过任何限制，也不会让你在窗口内多用一个 token。


## 配置项

命令行参数和环境变量都行，参数优先。管道模式记得加 `-s --`。

| 参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--port N` | `CPA_PORT` | `8317` | 监听端口 |
| `--host ADDR` | `CPA_HOST` | `127.0.0.1` | 监听地址 |
| `--listen-all` | `CPA_HOST=""` | — | 绑所有网卡，**会暴露到网络** |
| `--dir PATH` | `CPA_DIR` | `/opt/cliproxyapi` | 二进制与辅助脚本目录 |
| `--home PATH` | `TARGET_HOME` | `/root` | 服务用户家目录（同时决定 auth-dir 与 codex home） |
| `--auth-dir PATH` | `AUTH_DIR` | `$TARGET_HOME/.cli-proxy-api` | 配置与凭据目录 |
| `--service NAME` | `SERVICE_NAME` | `cliproxyapi` | systemd 单元名 |
| `--cpa-version VER` | `CPA_VERSION` | `latest` | CPA 版本，如 `v7.2.149` |
| `--codex-version VER` | `CODEX_VERSION` | `0.153.2` | Codex CLI 版本，可设 `latest` |
| `--model NAME` | `CODEX_MODEL` | `gpt-5.6-sol` | 写进 `config.toml` 的默认模型 |
| `--skip-codex` | `SKIP_CODEX=1` | — | 不装 Codex CLI |
| `--skip-bwrap` | `SKIP_BWRAP=1` | — | 不装 bubblewrap |
| `--skip-node` | `SKIP_NODE=1` | — | 缺 Node.js 时也不自动装 |
| `-h, --help` | — | — | 显示帮助 |

改了端口或目录后重跑：`config.yaml` 已存在时会被跳过（不覆盖你的手工调整），要让新值生效得先删掉它。

同一台机器装多份实例就靠 `--dir` + `--home` + `--service` + `--port` 四件套错开，互不干扰：

```bash
sudo ./install.sh --dir /opt/cpa-b --home /srv/cpa-b --service cliproxyapi-b --port 8318
```

## 文件布局

```
cpa-codex-setup/            本仓库
├── install.sh              一键部署
├── uninstall.sh            卸载
└── helpers/                辅助脚本模板（install.sh 替换占位符后落盘）
    ├── login.sh
    ├── status.sh
    └── autoresume.sh

/opt/cliproxyapi/
├── cli-proxy-api          CPA 主程序
├── login.sh               凭据登录助手
├── status.sh              凭据池与自动切换状态查看器
├── autoresume.sh          限流后等窗口重置自动续跑
└── config.example.yaml    上游完整配置样例（几百个可调字段都在这）

/root/.cli-proxy-api/
├── config.yaml            实际生效的配置（0600）
├── .apikey.txt            下游客户端用的 API key 明文备份（0600）
├── .mgmtkey.txt           管理 API key 明文备份（0600）
├── autoresume.log         autoresume.sh 的运行日志
└── codex-*.json           OAuth 登录后生成的凭据，每账号一个

/etc/systemd/system/cliproxyapi.service
/root/.codex/config.toml   Codex CLI 配置（安装前的版本已备份为 .bak.<时间戳>）
```

## 运维

```bash
sudo /opt/cliproxyapi/status.sh          # 凭据池状态 + 自动切换开关的实际生效值
journalctl -u cliproxyapi -f            # 实时日志：429 限流、超时、凭据切换都在这
tail -f /root/.cli-proxy-api/autoresume.log   # 自动续跑的等待/恢复记录
systemctl restart cliproxyapi           # 重启
systemctl status cliproxyapi            # 状态
```

管理面板在 `http://127.0.0.1:8317`，请求需携带 `.mgmtkey.txt` 里的管理 key。

## 安全说明

请在部署前读一遍这几条：

- **默认只绑回环地址。** 脚本写入 `host: "127.0.0.1"`，服务不对外网可见。上游 `config.example.yaml` 的默认值是空字符串（= 监听所有网卡），本脚本刻意收紧了这一点。
- **改成 `0.0.0.0` 前想清楚。** 端点背后是你的付费账号额度，`api-keys` 鉴权虽然默认开启（未携带 key 返回 401，脚本会验证这一点），但仍应配合防火墙只放行可信来源。
- **密钥是明文存盘的。** `.apikey.txt` / `.mgmtkey.txt` 权限 0600，仅 root 可读，方便你随时取用。`config.yaml` 里的 `secret-key` 会在首次启动时被 bcrypt 就地回写。
- **凭据等于账号。** `~/.cli-proxy-api/*.json` 是 OAuth token，泄露等同账号泄露。别把这个目录提交进任何仓库。
- **不要把生成的 config 文件推上 GitHub。** 本仓库只包含脚本和文档，不含任何密钥。

## 多账号：能用，但要知道边界

「一台服务器上登录多个账号会不会被限制」是个绕不开的问题。分三层说清楚。

**官方条款怎么写的**

[Terms of Use](https://www.openai.com/terms/) 里明确的一句是：

> You may not share your account credentials or make your account available to anyone else and are responsible for all activities that occur under your account.

而 [Account Sharing Policy](https://help.openai.com/en/articles/10471989-openai-account-sharing-policy) 则说：

> You are welcome to use your OpenAI account on multiple devices. However, please note that usage limits may apply depending on your account activity and subscription level.

拆开看：**你自己的账号在多台设备/多个客户端上用是被允许的**；**把凭据交给别人用是被禁止的**。至于「一个人持有多个账号」，条款没有明文禁止，但同一句话也写了 usage limits 会随「账号活动」浮动 —— 也就是说限流阈值本身是动态的、由服务端判定的。

**技术上会被看到什么**

CPA 是拿你的 OAuth 登录态去调上游，请求从同一台机器、同一个出口 IP 发出。所以服务端能观察到的至少包括：同 IP 下多个账号的活动、每个账号的调用量与时间分布、客户端特征。CPA 默认会强制带上官方 Codex 的 User-Agent 和 Originator 头（`codex.disable-codex-cloaking: false`），所以它在协议层看起来就是官方客户端。

配置里有个 `codex.identity-confuse` 开关，作用是按凭据重映射 `prompt_cache_key` 和 installation 身份。值得一提的是上游作者自己在注释里对它的评价：

> Some superstitious users believe request tracking identifiers can be used as evidence for TOS enforcement bans; this option only satisfies those odd concerns.

翻译过来：作者认为这个选项主要是安慰迷信的人。别把它当护身符。

**所以实际怎么办**

我没法向你保证「不会被限制」—— 判定逻辑在 OpenAI 手里，不公开，也随时可能变。能给的是几条务实的边界：

- 只用**你自己**的账号。借号、买号、共享凭据是条款明文禁止的那一类，风险性质完全不同。
- 把它当「个人的多设备统一入口」用，而不是「额度池对外供货」。后者已经是在做转售，那是另一回事。
- 商业用途、团队共用、或者调用量确实大 —— 用官方 API key（`codex-api-key` 配置块）或 ChatGPT Business/Enterprise。按量付费的额度不会因为「行为异常」被收走，这个确定性值钱。
- 真被限流了先看 `status.sh`：如果 `5H` 是 100% 而 `7D` 只有百分之十几，那是短窗口限流，等重置就好，不是封号。

## 故障排查

**登录时终端什么都不打印，或退出码 144**
CPA 在非 TTY 环境下不会输出授权 URL 和设备码。后台重定向（`> log 2>&1 &`）、管道（`| head`）、`screen -dm`、`nohup setsid` 全都拿不到输出 —— 这不是 bug，必须在真实交互终端里跑 `login.sh`。

**`/v1/models` 返回空数组 `{"data":[],"object":"list"}`**
服务正常，但还没有任何凭据。跑 `login.sh` 登录。

**`unknown provider for model xxx` (HTTP 400)**
请求到了 CPA 但没有能提供该模型的凭据。要么没登录，要么该账号等级不支持这个模型 —— 用 `/v1/models` 确认实际可用列表。

**429 了但没有自动换号**
先跑 `status.sh` 看 `request-retry` 的实际值。如果是 0，说明 `config.yaml` 里省略了这些字段（省略 = 零值 = 关闭），照上面「自动切换：核心开关」补齐再重启。如果已经是 3，那就看凭据池里是不是只有一个号 —— 没有第二个可切时，重试多少轮都是撞同一面墙，这种情况用 `autoresume.sh` 等窗口重置。

**autoresume.sh 一启动就报「凭据池为空」**
`login.sh` 还没登录成功，或者登录的凭据 json 不在脚本读的 `AUTH_DIR` 下。用 `status.sh` 确认池子里到底有没有号。

**HTTP 401**
key 不对。用 `sudo cat /root/.cli-proxy-api/.apikey.txt` 取当前 key；注意 `config.yaml` 被手工改过后需要 `systemctl restart cliproxyapi`。

**Codex 报 `could not find bubblewrap on PATH`**
`apt install bubblewrap` 即可，或忽略 —— Codex 会回退到内置副本，功能不受影响。

**替换二进制时报 "text file busy"**
`install.sh` 会先停服再覆盖；若手工替换需自己先 `systemctl stop cliproxyapi`。

## 卸载

```bash
sudo ./uninstall.sh            # 移除服务与安装目录，保留凭据（重装免重新授权）
sudo ./uninstall.sh --purge    # 连凭据目录一起删，不可恢复
```

装的时候用了 `--dir` / `--home` / `--service`，卸载时传一样的值：

```bash
sudo ./uninstall.sh --purge -y --dir /opt/cpa-b --home /srv/cpa-b --service cliproxyapi-b
```

不会碰 `~/.codex/config.toml`，也不会卸载 Codex CLI 或 bubblewrap —— 需要的话自己动手，安装前的备份在 `~/.codex/config.toml.bak.*`。

## 上游项目

本仓库只是部署封装，核心功能全部来自上游：

- [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — MIT
- [CLIProxyAPI 官方文档](https://help.router-for.me/)
- [OpenAI Codex CLI](https://developers.openai.com/codex)
- 想要图形界面的话看 [EasyCLIProxyAPI](https://github.com/router-for-me/EasyCLIProxyAPI)

使用前请确认你的用法符合相应服务商的条款。




