# Symphony 操作手册

## 目录
1. [产品概述](#1-产品概述)
2. [快速开始](#2-快速开始)
3. [配置详解](#3-配置详解)
4. [使用场景案例](#4-使用场景案例)
5. [命令行参数](#5-命令行参数)
6. [Web 界面](#6-web-界面)
7. [故障排查](#7-故障排查)
8. [最佳实践](#8-最佳实践)

---

## 1. 产品概述

### 1.1 什么是 Symphony

Symphony 是一个长时运行的自动化编排服务，它能够：

- **轮询问题追踪器**：持续从 Linear 或 GitLab 获取待处理的 issues
- **创建隔离工作区**：为每个问题创建独立的文件系统工作区
- **运行 Codex 代理**：在每个工作区内启动 OpenAI 的 Codex 编码代理
- **自动化工作流**：根据预定义的工作流自动完成代码编写、PR/MR 创建等任务

### 1.2 核心架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        Symphony                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                     Supervision Tree                      │   │
│  │  Phoenix.PubSub → Task.Supervisor → WorkflowStore        │   │
│  │  → Orchestrator → HttpServer* → StatusDashboard*         │   │
│  │  (* 条件启动)                                             │   │
│  └──────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  Orchestrator │───▶│ AgentRunner  │───▶│Codex.AppServer│    │
│  │  (轮询调度)   │    │  (任务执行)   │    │   (AI 代理)   │    │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│         │                   │                   │               │
│         ▼                   ▼                   ▼               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Tracker    │    │  Workspace   │    │ Dynamic Tool │      │
│  │ (Linear/      │    │  (工作区管理)  │    │ (GraphQL/REST)│    │
│  │  GitLab API)  │    │              │    │              │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 数据流

```
WORKFLOW.md (YAML + Liquid 模板)
        │
        ▼
WorkflowStore (每秒热加载)
        │
        ▼
Config (Ecto Schema 校验)
        │
        ▼
Linear 问题 ──▶ Orchestrator 轮询 ──▶ AgentRunner 创建工作区
                                                      │
                                                      ▼
                                            Codex.AppServer 执行
                                            (JSON-RPC 2.0 over stdio)
                                                      │
                                                      ▼
                                            Codex 调用 API (Linear/GitLab)
                                            修改工作区文件
                                                      │
                                                      ▼
                                            完成/重试/阻塞 → 清理工作区
```

---

## 2. 快速开始

### 2.1 环境要求

- **Elixir**: 1.19+ (通过 mise 管理，见 `elixir/mise.toml`)
- **Erlang**: OTP 28
- **Git**: 用于工作区代码管理
- **Codex**: OpenAI Codex CLI (用于 AI 编码)
- **mise**: 必需，用于 Elixir/Erlang 版本管理。所有 `mix`/`make` 命令需加 `mise exec --` 前缀

### 2.2 安装步骤

```bash
# 1. 克隆仓库
git clone <symphony-repo-url>
cd symphony

# 2. 安装 Elixir/Erlang (使用 mise)
mise install

# 3. 安装依赖
cd elixir
mise exec -- mix setup

# 4. 编译项目
mise exec -- mix build
```

### 2.3 首次启动

```bash
# 1. 设置 API 密钥 (根据你的追踪器类型)
export LINEAR_API_KEY="你的 Linear API 密钥"      # 使用 Linear 时
export GITLAB_API_KEY="你的 GitLab access token"   # 使用 GitLab 时

# 2. 启动服务 (基本模式)
cd elixir
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md

# 3. 启动服务 (带 Web 界面)
mise exec -- ./bin/symphony --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md

# 4. 自定义日志目录
mise exec -- ./bin/symphony --logs-root /var/log/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

> **注意**：`--i-understand-that-this-will-be-running-without-the-usual-guardrails` 是必需的安全确认参数，表示你理解 Codex 将在无保护栏的情况下运行。

### 2.4 获取 API 密钥

**Linear:**

1. 登录 Linear (linear.app)
2. 进入 Settings → Security & access
3. 点击 "Create personal API key"
4. 复制生成的密钥 (通常以 `lin_api_` 开头)

**GitLab:**

1. 登录 GitLab (gitlab.com 或自托管实例)
2. 进入 Settings → Access Tokens
3. 创建 Personal Access Token，勾选 `api` scope
4. 复制生成的 token (通常以 `glpat-` 开头)

---

## 3. 配置详解

### 3.1 WORKFLOW.md 结构

WORKFLOW.md 是 Symphony 的核心配置文件，包含两部分：

1. **YAML 头部**（`---` 分隔）：配置参数
2. **Markdown 主体**：Codex 代理的 Liquid 模板提示词

Symphony 每秒检查 WORKFLOW.md 的变更并自动热加载。如果新配置解析失败，会保留上一次有效的配置继续运行。

### 3.2 完整配置参数说明

```yaml
---
# ── 追踪器配置 ──
tracker:
  kind: linear                    # 追踪器类型: "linear", "gitlab" 或 "memory"(测试用)
  endpoint: "https://api.linear.app/graphql"  # API 端点 (linear: GraphQL, gitlab: REST v4, 可选)
  api_key: $LINEAR_API_KEY        # API 密钥，支持 $ENV_VAR 环境变量
  project_slug: "your-project"    # 项目标识 (linear: project slug, gitlab: URL-encoded full project path)
  assignee: "me"                  # 筛选分配人，"me"=当前用户 (可选)
  active_states:                  # 活跃状态列表 (gitlab 使用标签识别状态)
    - Todo
    - In Progress
  terminal_states:                # 终止状态列表 (完成后清理工作区)
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate

# ── 轮询配置 ──
polling:
  interval_ms: 5000               # 轮询间隔 (毫秒，默认 30000)

# ── 工作区配置 ──
workspace:
  root: ~/code/workspaces         # 工作区根目录 (默认: 系统临时目录)

# ── Worker 配置 (可选，远程 SSH 执行) ──
worker:
  ssh_hosts:                      # SSH 远程主机列表
    - user@host1.example.com
    - user@host2.example.com
  max_concurrent_agents_per_host: 5  # 每台主机最大并发代理数 (可选)

# ── 生命周期钩子 ──
hooks:
  after_create: |                 # 工作区创建后执行 (仅新的工作区)
    git clone https://github.com/org/repo.git .
    npm install
  before_run: |                   # 每次 Codex 运行前执行
    git pull origin main
  after_run: |                    # 每次 Codex 运行后执行
    echo "Run completed"
  before_remove: |                # 工作区删除前执行 (终端状态时)
    cd elixir && mix workspace.before_remove
  timeout_ms: 60000               # 钩子执行超时 (毫秒，默认 60000)

# ── 代理配置 ──
agent:
  max_concurrent_agents: 10       # 最大并发代理数 (默认 10)
  max_turns: 20                   # 单个问题最大回合数 (默认 20)
  max_retry_backoff_ms: 300000    # 最大重试退避时间 (毫秒，默认 300000)
  max_concurrent_agents_by_state: # 按状态限制并发 (可选)
    "In Progress": 5
    "Rework": 3

# ── Codex 配置 ──
codex:
  command: codex app-server       # Codex 启动命令 (必填)
  approval_policy: never          # 审批策略: "never" 或配置 map
  thread_sandbox: workspace-write # 线程沙箱模式 (默认 workspace-write)
  turn_sandbox_policy:            # 回合沙箱策略 (可选，默认自动生成)
    type: workspaceWrite
    # 沙箱默认配置:
    # - writableRoots: [workspace 目录]
    # - readOnlyAccess: fullAccess
    # - networkAccess: true (允许网络访问，供 Codex 调用 API 工具)
    # - excludeTmpdirEnvVar: false
  turn_timeout_ms: 3600000        # 单个回合超时 (毫秒，默认 1 小时)
  read_timeout_ms: 5000           # 读取超时 (毫秒，默认 5000)
  stall_timeout_ms: 300000        # 停滞检测超时 (毫秒，默认 300000)

# ── 可观测性配置 ──
observability:
  dashboard_enabled: true         # 终端仪表盘开关 (默认 true，测试环境禁用)
  refresh_ms: 1000                # 数据刷新间隔 (毫秒，默认 1000)
  render_interval_ms: 16          # 渲染节流间隔 (毫秒，默认 16)

# ── Web 服务配置 ──
server:
  port: 4000                      # HTTP 服务端口 (可选，不配置则不启动)
  host: "127.0.0.1"              # 绑定地址 (默认 127.0.0.1)
---
```

### 3.3 追踪器配置说明

#### Linear 追踪器 (`kind: linear`)

Linear 使用 GraphQL API。配置中 `project_slug` 是项目 URL 中的短标识符 (如 `my-team-project`)。
API endpoint 默认为 `https://api.linear.app/graphql`。

Symphony 为 Codex 注入 `linear_graphql` 动态工具，Codex 可以通过它直接查询和修改 Linear 数据。

#### GitLab 追踪器 (`kind: gitlab`)

GitLab 使用 REST API v4。配置中 `project_slug` 必须是 URL-encoded 的完整项目路径 (如 `my-group%2Fmy-project`)。
API endpoint 默认为 `https://gitlab.com`，可配置为自托管实例地址。

Symphony 为 Codex 注入 `gitlab_api` 动态工具，Codex 可以通过它操作 GitLab issues、notes (评论)、merge requests、labels 等。

GitLab 的状态管理依赖标签 (labels)：
- 未标记的 issue 自动视为 `Todo` 状态
- 通过标签匹配 `active_states` 和 `terminal_states` 中的状态
- 状态更新时会保留已有标签并添加新状态标签

优先级通过标签解析，支持格式：`priority::high`、`P0`、`P1` 等。
阻塞关系通过 issue 的 `_links` 数据检测。

```yaml
# GitLab 配置示例
tracker:
  kind: gitlab
  endpoint: "https://gitlab.com"              # 可选，默认 gitlab.com
  api_key: $GITLAB_API_KEY
  project_slug: "my-group%2Fmy-project"       # URL-encoded 项目路径
  assignee: "me"                              # 可选
  active_states:
    - Todo
    - "In Progress"
  terminal_states:
    - Done
    - Closed
```

> **注意**：自托管 GitLab 实例需要在 `endpoint` 中指定完整地址，如 `https://gitlab.my-company.com`。

### 3.4 动态工具

Symphony 根据 `tracker.kind` 自动向 Codex 注入对应的 API 交互工具：

| Tracker Kind | 注入工具 | 工具类型 | 说明 |
|---|---|---|---|
| `linear` | `linear_graphql` | GraphQL | 执行 Linear GraphQL 查询和变更 |
| `gitlab` | `gitlab_api` | REST | 调用 GitLab REST API v4 (GET/POST/PUT/DELETE) |
| `memory` | 两者都注入 | — | 测试用，提供最大兼容性 |

`gitlab_api` 工具参数：
- `method`：HTTP 方法 (GET, POST, PUT, DELETE)
- `path`：API 路径，相对于 `/api/v4/` (如 `projects/xxx/issues/1/notes`)
- `body`：可选的 JSON 请求体 (POST/PUT 时使用)

`linear_graphql` 工具参数：
- `query`：GraphQL 查询字符串
- `variables`：可选的查询变量对象

### 3.5 环境变量插值

任何字符串配置值都可以使用 `$ENV_VAR` 语法引用环境变量：

```yaml
tracker:
  api_key: $LINEAR_API_KEY        # 解析为 System.get_env("LINEAR_API_KEY")
  assignee: $LINEAR_ASSIGNEE      # 解析为 System.get_env("LINEAR_ASSIGNEE")

workspace:
  root: $WORKSPACE_ROOT           # 解析为 System.get_env("WORKSPACE_ROOT")

codex:
  command: $CODEX_PATH app-server # $CODEX_PATH 会被展开
```

### 3.6 模板变量

WORKFLOW.md 的 Markdown 主体使用 Liquid 模板引擎 (Solid)，支持以下变量：

| 变量 | 类型 | 说明 |
|------|------|------|
| `{{ issue.identifier }}` | string | 问题标识符 (如 `MT-620`) |
| `{{ issue.id }}` | string | 问题内部 UUID |
| `{{ issue.title }}` | string | 问题标题 |
| `{{ issue.description }}` | string | 问题描述 |
| `{{ issue.state }}` | string | 当前状态 |
| `{{ issue.priority }}` | integer | 优先级 (可选) |
| `{{ issue.labels }}` | list | 标签列表 |
| `{{ issue.url }}` | string | Linear 问题 URL |
| `{{ issue.branch_name }}` | string | 关联分支名 (可选) |
| `{{ issue.assignee_id }}` | string | 分配人 ID (可选) |
| `{{ issue.blocked_by }}` | list | 阻塞该问题的 issue ID 列表 |
| `{{ issue.created_at }}` | datetime | 创建时间 (ISO 8601) |
| `{{ issue.updated_at }}` | datetime | 更新时间 (ISO 8601) |
| `{{ attempt }}` | integer | 当前重试次数 (仅重试时存在) |

模板支持 Liquid 控制流：

```liquid
{% if issue.description %}
## 问题描述
{{ issue.description }}
{% endif %}

{% if attempt %}
## 重试上下文
这是第 {{ attempt }} 次重试，请从当前工作区状态继续。
{% endif %}

{% if issue.blocked_by %}
## 阻塞信息
此问题被以下 issues 阻塞: {{ issue.blocked_by }}
{% endif %}
```

---

## 4. 使用场景案例

### 4.1 场景一：简单项目 - 自动修复 Bug

**目标**：配置一个简单的 Symphony 实例，自动处理项目中的 Bug

**配置示例**：

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "my-api-project"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed

workspace:
  root: ~/symphony-workspaces

hooks:
  after_create: |
    git clone --depth 1 https://github.com/my-org/my-api-project.git .
    npm install

agent:
  max_concurrent_agents: 5
  max_turns: 10

codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a bug fix for Linear issue {{ issue.identifier }}.

Title: {{ issue.title }}
Description: {{ issue.description }}

Instructions:
1. First, understand the bug by running the existing tests
2. Identify the root cause
3. Implement a fix
4. Run tests to verify the fix works
5. Create a PR with your changes

Important:
- Work only in the provided workspace
- Do not ask for human help unless truly blocked
- Update the issue status as you progress
```

**启动**：

```bash
export LINEAR_API_KEY="your-api-key"
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

Symphony 会自动：
1. 检测到新的 `Todo` 问题
2. 创建工作区并克隆代码
3. 运行 Codex 代理分析并修复问题
4. 创建 GitHub PR
5. 问题进入终端状态后自动清理工作区

---

### 4.2 场景二：复杂项目 - 全功能开发工作流

**目标**：配置一个完整的开发流程，支持特性开发、代码审查、PR 合并

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "fullstack-app"
  active_states:
    - Todo
    - In Progress
    - In Review
    - Rework
    - Merging
  terminal_states:
    - Done
    - Closed
    - Cancelled

polling:
  interval_ms: 3000

workspace:
  root: /var/workspaces/symphony

hooks:
  after_create: |
    git clone --depth 1 https://github.com/my-org/fullstack-app.git .
    npm install
    cd client && npm install
  before_run: |
    git pull origin main
  before_remove: |
    cd elixir && mix workspace.before_remove

agent:
  max_concurrent_agents: 10
  max_turns: 30
  max_retry_backoff_ms: 600000

codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  stall_timeout_ms: 600000
---

{% if issue.description %}
## Issue Description
{{ issue.description }}
{% endif %}

{% if attempt %}
## Continuation Context
This is retry attempt #{{ attempt }}. Resume from the current workspace state.
{% endif %}

## Your Task

You are working on issue {{ issue.identifier }}: **{{ issue.title }}**

### Status Map
- `Todo` → Move to `In Progress`, start work
- `In Progress` → Implementation phase
- `In Review` → Wait for PR review
- `Rework` → Address review feedback
- `Merging` → Execute land skill to merge PR

### Workflow

1. **Start (Todo)**
   - Move issue to `In Progress`
   - Create a workpad comment for tracking progress

2. **Implementation**
   - Understand requirements from issue description
   - Write code following project conventions
   - Run tests and linting
   - Create PR with description

3. **Review (In Review)**
   - Wait for reviewer feedback
   - Address comments or push back with justification

4. **Rework**
   - Make required changes
   - Re-request review

5. **Merge (Merging)**
   - Use land skill to merge PR
   - Move issue to `Done`

### Guidelines
- Always write tests for new functionality
- Follow the project's coding standards
- Use the workpad comment for all progress tracking
```

---

### 4.3 场景三：远程 SSH Worker 执行

**目标**：在多台远程机器上分发 Codex 执行任务

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "my-project"

polling:
  interval_ms: 5000

workspace:
  root: /data/symphony-workspaces

worker:
  ssh_hosts:
    - builder@worker-1.example.com
    - builder@worker-2.example.com
  max_concurrent_agents_per_host: 4

hooks:
  after_create: |
    git clone --depth 1 https://github.com/org/repo.git .
    npm install

agent:
  max_concurrent_agents: 8
  max_turns: 20

codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on {{ issue.identifier }}: {{ issue.title }}

{% if issue.description %}
## Requirements
{{ issue.description }}
{% endif %}

## Instructions
1. Understand the requirements
2. Make necessary changes
3. Run tests to verify
4. Create PR
```

**工作原理**：
- Symphony 在本地运行编排逻辑
- Codex 进程通过 SSH 在远程主机上启动
- 工作区和文件操作都在远程主机上进行
- 每个 host 遵循 `max_concurrent_agents_per_host` 并发限制

---

### 4.4 场景四：按状态限制并发

**目标**：对不同状态的 issue 设置不同的并发限制

```yaml
---
agent:
  max_concurrent_agents: 10
  max_concurrent_agents_by_state:
    "Todo": 3         # 同时最多 3 个新问题开始
    "In Progress": 8  # 进行中的最多 8 个
    "Rework": 2       # 返工的只允许 2 个
    "Merging": 1      # 合并操作串行执行
---
```

这允许你精细化控制各阶段的资源分配，避免合并冲突或资源争抢。

---

### 4.5 场景五：使用环境变量保护敏感信息

```yaml
---
tracker:
  api_key: $LINEAR_API_KEY
  project_slug: $LINEAR_PROJECT_SLUG

workspace:
  root: $WORKSPACE_ROOT

codex:
  command: $CODEX_PATH app-server
---

Your task: {{ issue.title }}
```

启动命令：

```bash
export LINEAR_API_KEY="lin_api_xxx"
export LINEAR_PROJECT_SLUG="my-project"
export WORKSPACE_ROOT="/data/workspaces"
export CODEX_PATH="/usr/local/bin/codex"

mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

---

## 5. 命令行参数

### 5.1 完整参数列表

| 参数 | 类型 | 说明 |
|------|------|------|
| `[path-to-WORKFLOW.md]` | string | 工作流配置文件路径，默认为当前目录下 `WORKFLOW.md` |
| `--port <port>` | integer | 启动 Web Dashboard 和 JSON API 的端口 |
| `--logs-root <path>` | string | 自定义日志目录 (日志文件: `<logs-root>/symphony.log`) |
| `--i-understand-that-this-will-be-running-without-the-usual-guardrails` | boolean | **必需** 安全确认参数 |

### 5.2 使用示例

```bash
# 最简启动 (使用当前目录 WORKFLOW.md)
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails

# 指定配置文件
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails /path/to/my-workflow.md

# 完整参数
mise exec -- ./bin/symphony \
  --port 4000 \
  --logs-root /var/log/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

---

## 6. Web 界面

### 6.1 访问地址

使用 `--port` 参数启动后：

- **Dashboard**: `http://localhost:<port>/`
- **JSON API**: `http://localhost:<port>/api/v1/*`

### 6.2 实时 Dashboard

LiveView 驱动的实时仪表盘，显示：
- 运行中/重试中/阻塞中的代理数量
- Token 使用统计和速率限制
- 每个活跃 session 的详细信息 (issue ID、状态、工作区路径、耗时)
- 阻塞和重试队列

### 6.3 API 端点

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/v1/state` | 获取完整系统状态快照 |
| `GET` | `/api/v1/<issue_identifier>` | 获取特定问题的详细信息 (如 `MT-620`) |
| `POST` | `/api/v1/refresh` | 强制触发一次轮询刷新 |

**API 响应格式**：

```json
// GET /api/v1/state
{
  "running": [...],
  "retrying": [...],
  "blocked": [...],
  "completed_count": 42,
  "codex_totals": { ... },
  "codex_rate_limits": { ... }
}

// GET /api/v1/MT-620
{
  "issue_identifier": "MT-620",
  "status": "running",
  "session_id": "...",
  "workspace_path": "...",
  "worker_host": "local",
  "turn_count": 3,
  "codex_*_tokens": { ... },
  "last_codex_message": "..."
}
```

---

## 7. 故障排查

### 7.1 常见问题

#### 问题：启动时缺少安全确认

```
╭──────────────────────────────────────────────────────────╮
│ This Symphony implementation is a low key engineering... │
│ Codex will run without any guardrails.                   │
│ ...                                                      │
│ To proceed, start with `--i-understand-that-...`         │
╰──────────────────────────────────────────────────────────╯
```

**解决方案**：添加 `--i-understand-that-this-will-be-running-without-the-usual-guardrails` 参数。

#### 问题：无法连接 Linear

```
Invalid WORKFLOW.md config: missing_linear_api_token
Invalid WORKFLOW.md config: missing_linear_project_slug
```

**解决方案**：
1. 确认 `tracker.api_key` 已设置或 `LINEAR_API_KEY` 环境变量已导出
2. 确认 `tracker.project_slug` 正确 (在 Linear 项目 URL 中可以找到)
3. 验证 API 密钥格式 (通常以 `lin_api_` 开头)

#### 问题：无法连接 GitLab

```
Invalid WORKFLOW.md config: missing_gitlab_api_token
```

**解决方案**：
1. 确认 `tracker.api_key` 已设置或 `GITLAB_API_KEY` 环境变量已导出
2. 确认 `tracker.kind` 设置为 `gitlab`
3. 验证 Access Token 拥有 `api` scope
4. 确认 `tracker.project_slug` 使用 URL-encoded 完整路径 (如 `my-group%2Fmy-project`)
5. 自托管实例确认 `tracker.endpoint` 指向正确的地址

#### 问题：工作区创建失败

```
[error] Workspace creation failed issue_id=... error=...
```

**解决方案**：
1. 检查 `workspace.root` 目录是否存在且有写入权限
2. 确认 `hooks.after_create` 中的 Git URL 可访问 (可能需要认证)
3. 检查 `hooks.timeout_ms` 是否足够 (大型仓库克隆可能超时)

#### 问题：Codex 启动失败

**症状**：agent 运行日志中出现 `:error` 或进程退出

**解决方案**：
1. 确认 Codex CLI 已安装：`which codex`
2. 检查 `codex.command` 配置是否正确
3. 验证 Codex 在目标环境 (本地或 SSH 远程主机) 上可执行

#### 问题：工作区安全校验失败

```
[error] Workspace path validation failed: workspace_outside_root
```

**解决方案**：
1. 确认工作区路径在 `workspace.root` 下
2. 检查是否存在符号链接逃逸
3. 不要将 `workspace.root` 设置在源代码仓库内

### 7.2 查看日志

```bash
# 默认日志位置
tail -f elixir/log/symphony.log

# 自定义日志目录
tail -f <logs-root>/symphony.log

# 过滤特定问题日志
grep "issue_identifier=MT-620" elixir/log/symphony.log

# 查看错误日志
grep "\[error\]" elixir/log/symphony.log

# 日志轮转配置
# 默认: 单文件 10MB, 保留 5 个历史文件
```

### 7.3 调试技巧

```bash
# 检查配置是否正确解析
cd elixir && mise exec -- mix run -e 'IO.inspect(SymphonyElixir.Config.settings!())'

# 运行测试确认环境正常
mise exec -- mix test

# 使用 memory tracker 进行本地测试 (不需要 Linear API)
# 在测试中: tracker.kind = "memory"
```

---

## 8. 最佳实践

### 8.1 安全建议

1. **使用环境变量管理密钥**：始终用 `$LINEAR_API_KEY` 而非硬编码密钥
2. **限制工作区位置**：`workspace.root` 设置在独立目录，远离源代码仓库
3. **理解沙箱模式**：`thread_sandbox: workspace-write` 限制 Codex 只能在工作区写文件。回合沙箱默认允许网络访问 (`networkAccess: true`)，以便 Codex 调用 Linear/GitLab API 工具。如需限制网络访问，可自定义 `turn_sandbox_policy`
4. **配置钩子超时**：`hooks.timeout_ms` 防止脚本挂起
5. **使用 `before_remove` 清理**：集成 `mix workspace.before_remove` 自动关闭相关 PR

### 8.2 性能优化

1. **合理设置并发数**：根据机器资源和 API 限制调整 `max_concurrent_agents`
2. **使用按状态并发限制**：`max_concurrent_agents_by_state` 防止某些阶段瓶颈
3. **调整轮询间隔**：根据团队节奏设置 `polling.interval_ms`
4. **优化钩子脚本**：使用 `--depth 1` 浅克隆，避免不必要的依赖安装
5. **利用 SSH Worker 扩展**：在远程主机上分发执行负载

### 8.3 工作流设计建议

1. **终端状态要完整**：确保 `terminal_states` 包含所有可能的完成状态，否则已完成问题不会被清理
2. **提示词要明确**：在 WORKFLOW.md 主体中给出清晰的分步指令和状态流转映射
3. **使用 `max_turns` 防止死循环**：设置合理上限，配合重试退避机制
4. **启用可观测性**：使用 `--port` 启动 Web Dashboard 方便监控
5. **检查停滞检测**：`stall_timeout_ms` 确保无响应的 Codex 进程被及时处理

### 8.4 监控建议

1. **启用 Web Dashboard**：实时查看运行状态、token 消耗和速率限制
2. **关注终端仪表盘**：本地 ANSI 终端显示 TPS (每秒 token 数) 和活跃 session
3. **日志告警**：监控 `[error]` 级别日志
4. **使用 JSON API**：`/api/v1/state` 可集成到外部监控系统

---

## 附录

### A. 项目文件结构

```
symphony/
├── SPEC.md                      # 协议规格说明
├── CLAUDE.md                    # Claude Code 指引
├── run.sh                       # Codex 启动脚本 (WORKFLOW.md 中引用)
├── docs/
│   ├── manual.md                # 本操作手册
│   ├── logging.md               # 日志规范
│   └── token_accounting.md      # Token 计费说明
├── elixir/
│   ├── mix.exs                  # Elixir 项目配置
│   ├── mise.toml                # 版本管理配置
│   ├── Makefile                 # 构建命令
│   ├── WORKFLOW.md              # 默认工作流配置
│   ├── config/config.exs        # Phoenix 基础配置
│   ├── lib/
│   │   ├── symphony_elixir.ex   # OTP Application 入口
│   │   ├── symphony_elixir/
│   │   │   ├── orchestrator.ex  # 核心编排 GenServer
│   │   │   ├── agent_runner.ex  # 单 issue 执行器
│   │   │   ├── linear/          # Linear API 客户端
│   │   │   ├── gitlab/          # GitLab API 客户端
│   │   │   ├── codex/           # Codex 子进程集成
│   │   │   ├── config.ex        # 配置访问层
│   │   │   ├── workflow.ex      # 工作流解析
│   │   │   └── workspace.ex     # 工作区管理
│   │   └── symphony_elixir_web/ # Phoenix Web 层
│   ├── test/                    # 测试文件
│   ├── bin/symphony             # 编译产物 (escript)
│   └── log/                     # 日志目录
```

### B. 开发常用命令

```bash
cd elixir

# 开发测试
mise exec -- mix test                          # 运行全部测试
mise exec -- mix test test/symphony_elixir/orchestrator_test.exs  # 单个测试文件
mise exec -- mix test --cover                  # 覆盖率测试 (100% 阈值)

# 代码质量
mise exec -- mix format                        # 代码格式化
mise exec -- mix format --check-formatted      # 格式化检查
mise exec -- mix lint                          # specs.check + credo
mise exec -- mix dialyzer                      # 类型检查

# 构建
mise exec -- mix build                         # 构建 escript

# 快照测试
UPDATE_SNAPSHOTS=1 mise exec -- mix test       # 更新仪表盘快照

# E2E 测试
mise exec -- make e2e                          # 真实 E2E 测试 (需 Codex + Linear)

# 完整质量门禁
mise exec -- make all                          # setup + build + fmt-check + lint + coverage + dialyzer
```

### C. 核心依赖

| 依赖 | 用途 |
|------|------|
| `solid` | Liquid 模板引擎，渲染 WORKFLOW.md 模板 |
| `yaml_elixir` | YAML 前置元数据解析 |
| `ecto` | 嵌入式 Schema 校验 (不涉及数据库) |
| `req` | HTTP 客户端，调用 Linear GraphQL API 和 GitLab REST API |
| `phoenix` / `phoenix_live_view` | 可选 Web 监控界面 |
| `bandit` | Phoenix HTTP 服务器 |
| `credo` | Elixir 代码检查 |
| `dialyxir` | 类型检查 |

### D. Linear 状态流转参考

```
Todo → In Progress → In Review → Merging → Done
                      ↓                        ↑
                    Rework ────────────────────┘
```

Symphony 轮询 `active_states` 中的问题，当问题进入 `terminal_states` 时自动清理对应工作区。
