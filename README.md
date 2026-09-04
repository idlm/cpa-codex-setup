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
| 系统 | Debian / Ubuntu 等 systemd 发行版 |
| 架构 | x86_64 或 aarch64 |
| 权限 | root（`sudo`） |
| 依赖 | `curl` `tar` `sha256sum` `openssl`（缺失会自动装） |
| Codex CLI | 需要 Node.js ≥ 18 的 `npm`；没有则自动跳过这步 |

## 快速开始

```bash
git clone https://github.com/idlm/cpa-codex-setup.git
cd cpa-codex-setup
sudo ./install.sh
```

脚本依次完成：下载校验二进制 → 生成随机密钥 → 写最小化配置 → 注册 systemd → 健康检查 → 安装 Codex CLI 与 `config.toml` → 安装 bubblewrap。

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

**配额耗尽时的兜底**

```yaml
quota-exceeded:
  switch-project: true         # 自动切到另一个可用凭据
  switch-preview-model: true   # 自动降级到 preview 模型
```

**重试与冷却**

```yaml
request-retry: 3                      # 首轮之外额外重试轮数，对 403/408/429/5xx 生效
max-retry-credentials: 0              # 每轮最多试几个凭据，0 = 不限
max-retry-interval: 30                # 冷却等待上限（秒）
transient-error-cooldown-seconds: 0   # 0 = 沿用 60s 传统值，-1 = 关闭瞬时错误冷却
disable-cooling: false                # true = 出错的凭据不进冷却池
```

429 频繁的话先加账号，其次调 `request-retry`；把 `disable-cooling` 打开通常只会让失败更快重现。

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



## 配置项

全部通过环境变量传给 `install.sh`：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CPA_VERSION` | `latest` | CPA 版本，如 `v7.2.149` |
| `CPA_DIR` | `/opt/cliproxyapi` | 二进制与辅助脚本目录 |
| `CPA_HOST` | `127.0.0.1` | 监听地址；改成 `0.0.0.0` 会暴露到网络 |
| `CPA_PORT` | `8317` | 监听端口 |
| `TARGET_HOME` | `/root` | 服务运行用户的家目录 |
| `AUTH_DIR` | `$TARGET_HOME/.cli-proxy-api` | 配置与凭据目录 |
| `SERVICE_NAME` | `cliproxyapi` | systemd 单元名 |
| `CODEX_VERSION` | `0.153.2` | Codex CLI 版本，可设 `latest` |
| `CODEX_MODEL` | `gpt-5.6-sol` | 写进 config.toml 的默认模型 |
| `SKIP_CODEX` | `0` | 设 `1` 跳过 Codex CLI 安装与配置 |
| `SKIP_BWRAP` | `0` | 设 `1` 跳过 bubblewrap 安装 |

## 文件布局

```
/opt/cliproxyapi/
├── cli-proxy-api          CPA 主程序
├── login.sh               凭据登录助手
└── config.example.yaml    上游完整配置样例（几百个可调字段都在这）

/root/.cli-proxy-api/
├── config.yaml            实际生效的配置（0600）
├── .apikey.txt            下游客户端用的 API key 明文备份（0600）
├── .mgmtkey.txt           管理 API key 明文备份（0600）
└── codex-*.json           OAuth 登录后生成的凭据，每账号一个

/etc/systemd/system/cliproxyapi.service
/root/.codex/config.toml   Codex CLI 配置（安装前的版本已备份为 .bak.<时间戳>）
```

## 运维

```bash
journalctl -u cliproxyapi -f            # 实时日志：429 限流、超时、凭据切换都在这
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

## 故障排查

**登录时终端什么都不打印，或退出码 144**
CPA 在非 TTY 环境下不会输出授权 URL 和设备码。后台重定向（`> log 2>&1 &`）、管道（`| head`）、`screen -dm`、`nohup setsid` 全都拿不到输出 —— 这不是 bug，必须在真实交互终端里跑 `login.sh`。

**`/v1/models` 返回空数组 `{"data":[],"object":"list"}`**
服务正常，但还没有任何凭据。跑 `login.sh` 登录。

**`unknown provider for model xxx` (HTTP 400)**
请求到了 CPA 但没有能提供该模型的凭据。要么没登录，要么该账号等级不支持这个模型 —— 用 `/v1/models` 确认实际可用列表。

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

不会碰 `~/.codex/config.toml`，也不会卸载 Codex CLI 或 bubblewrap —— 需要的话自己动手，安装前的备份在 `~/.codex/config.toml.bak.*`。

## 上游项目

本仓库只是部署封装，核心功能全部来自上游：

- [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — MIT
- [CLIProxyAPI 官方文档](https://help.router-for.me/)
- [OpenAI Codex CLI](https://developers.openai.com/codex)
- 想要图形界面的话看 [EasyCLIProxyAPI](https://github.com/router-for-me/EasyCLIProxyAPI)

使用前请确认你的用法符合相应服务商的条款。




