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




