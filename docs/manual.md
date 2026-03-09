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

- **轮询 Linear 问题**：持续从 Linear 项目管理工具获取待处理的 issues
- **创建隔离工作区**：为每个问题创建独立的文件系统工作区
- **运行 Codex 代理**：在每个工作区内启动 OpenAI 的 Codex 编码代理
- **自动化工作流**：根据预定义的工作流自动完成代码编写、PR 创建等任务

### 1.2 核心架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        Symphony                                  │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  Orchestrator │───▶│ AgentRunner  │───▶│Codex.AppServer│    │
│  │  (轮询调度)   │    │  (任务执行)   │    │   (AI 代理)   │    │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│         │                   │                   │               │
│         ▼                   ▼                   ▼               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Tracker    │    │  Workspace   │    │Linear GraphQL│      │
│  │ (Linear API) │    │  (工作区管理)  │    │   (工具)      │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 数据流

```
Linear 问题 ──▶ Orchestrator 轮询 ──▶ AgentRunner 创建工作区
                                                      │
                                                      ▼
                                            Codex.AppServer 执行
                                                      │
                                                      ▼
                                            Codex 调用 Linear API
                                                      │
                                                      ▼
                                            完成 → 清理工作区
```

---

## 2. 快速开始

### 2.1 环境要求

- **Elixir**: 1.19+ (通过 mise 管理)
- **Erlang**: OTP 28
- **Git**: 用于工作区代码管理
- **Codex**: OpenAI Codex CLI (用于 AI 编码)

### 2.2 安装步骤

```bash
# 1. 克隆仓库
git clone https://github.com/humphery755-dev/symphony.git
cd symphony

# 2. 安装 Elixir/Erlang (使用 mise)
mise install

# 3. 安装依赖
cd elixir
mix setup

# 4. 编译项目
mix build
```

### 2.3 首次启动

```bash
# 1. 设置 Linear API 密钥
export LINEAR_API_KEY="你的 Linear API 密钥"

# 2. 启动服务
cd elixir
./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md

# 3. (可选) 启动 Web 界面
./bin/symphony --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

### 2.4 获取 Linear API 密钥

1. 登录 Linear (linear.app)
2. 进入 Settings → Security & access
3. 点击 "Create personal API key"
4. 复制生成的密钥

---

## 3. 配置详解

### 3.1 WORKFLOW.md 结构

WORKFLOW.md 是 Symphony 的核心配置文件，包含两部分：

1. **YAML 头部**：配置参数
2. **Markdown 主体**：Codex 代理的提示词模板

### 3.2 配置参数说明

```yaml
---
tracker:
  kind: linear                    # 追踪器类型 (目前仅支持 linear)
  project_slug: "your-project"    # Linear 项目 slug
  active_states:                  # 活跃状态列表
    - Todo
    - In Progress
  terminal_states:                # 终止状态列表
    - Done
    - Closed

polling:
  interval_ms: 5000               # 轮询间隔 (毫秒)

workspace:
  root: ~/code/workspaces         # 工作区根目录

hooks:
  after_create: |                 # 工作区创建后执行的脚本
    git clone https://github.com/your-org/your-repo.git .
  before_remove: |                # 工作区删除前执行的脚本
    echo "Cleaning up..."

agent:
  max_concurrent_agents: 10       # 最大并发代理数
  max_turns: 20                   # 单个问题最大尝试次数

codex:
  command: codex app-server       # Codex 命令
  approval_policy: never          # 审批策略 (never/on-request/on-failure)
  thread_sandbox: workspace-write # 线程沙箱模式
  turn_sandbox_policy:           # 回合沙箱策略
    type: workspaceWrite
---
```

### 3.3 变量插值

WORKFLOW.md 支持以下变量：

| 变量 | 说明 |
|------|------|
| `{{ issue.identifier }}` | 问题标识符 (如 MT-620) |
| `{{ issue.id }}` | 问题内部 UUID |
| `{{ issue.title }}` | 问题标题 |
| `{{ issue.description }}` | 问题描述 |
| `{{ issue.state }}` | 当前状态 |
| `{{ issue.labels }}` | 标签列表 |
| `{{ issue.url }}` | 问题 URL |
| `{{ attempt }}` | 当前尝试次数 |

---

## 4. 使用场景案例

### 4.1 场景一：简单项目 - 自动修复 Bug

**目标**：配置一个简单的 Symphony 实例，自动处理项目中的 Bug

**项目背景**：
- 一个简单的 Node.js API 项目
- 使用 GitHub 托管代码
- 使用 Linear 管理问题

**配置步骤**：

#### 步骤 1：创建 WORKFLOW.md

```yaml
---
tracker:
  kind: linear
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

#### 步骤 2：启动服务

```bash
export LINEAR_API_KEY="your-api-key"
./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

#### 步骤 3：在 Linear 创建问题

在 Linear 项目中创建一个问题，设置为 `Todo` 状态：

```
Title: Fix login timeout issue
Description: Users are getting logged out after 5 minutes instead of 1 hour.
```

#### 步骤 4：观察执行

Symphony 会自动：
1. 检测到新的 `Todo` 问题
2. 创建工作区并克隆代码
3. 运行 Codex 代理分析并修复问题
4. 创建 GitHub PR
5. 更新问题状态

---

### 4.2 场景二：复杂项目 - 全功能开发工作流

**目标**：配置一个完整的开发流程，支持特性开发、代码审查、PR 合并

**项目背景**：
- 复杂的全栈项目 (React + Node.js)
- 需要遵循严格的代码审查流程
- 多阶段状态流转

**配置步骤**：

#### 步骤 1：创建 WORKFLOW.md

```yaml
---
tracker:
  kind: linear
  project_slug: "fullstack-app"
  active_states:
    - Todo
    - In Progress
    - Human Review
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
    cd ..
  before_remove: |
    # 清理构建产物
    rm -rf node_modules client/node_modules

agent:
  max_concurrent_agents: 10
  max_turns: 30

codex:
  command: codex --config model_reasoning_effort=xhigh app-server
  approval_policy: on-failure
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    allowed_paths:
      - /var/workspaces/symphony
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
- `Human Review` → Wait for PR review
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

3. **Review (Human Review)**
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
- Keep the PR description updated
- Use the workpad comment for all progress tracking
```

#### 步骤 2：启动服务

```bash
export LINEAR_API_KEY="your-key"
./bin/symphony --port 4000 --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

#### 步骤 3：使用 Web 界面监控

打开浏览器访问 `http://localhost:4000`，可以看到：
- 当前活跃的代理数量
- 每个问题的执行状态
- Token 使用统计
- 实时日志

---

### 4.3 场景三：多语言项目 - Python + React

**目标**：处理包含前后端的复杂项目

**配置示例**：

```yaml
---
tracker:
  kind: linear
  project_slug: "my-saas-product"

workspace:
  root: ~/workspaces

hooks:
  after_create: |
    # 根据项目结构克隆代码
    git clone --depth 1 https://github.com/my-org/backend-api.git ./backend
    git clone --depth 1 https://github.com/my-org/frontend-app.git ./frontend

    # 安装依赖
    cd backend && pip install -r requirements.txt
    cd ../frontend && npm install

agent:
  max_concurrent_agents: 8
  max_turns: 25

codex:
  command: codex app-server
---

You are working on {{ issue.identifier }}: {{ issue.title }}

{% if issue.description %}
## Requirements
{{ issue.description }}
{% endif %}

## Project Structure
- `./backend` - Python FastAPI 后端
- `./frontend` - React 前端

## Tasks
1. Understand the requirements
2. Make necessary changes to backend and/or frontend
3. Run tests to verify changes
4. Create PRs as needed

Note: You may need to work on both backend and frontend to complete this issue.
```

---

### 4.4 场景四：自定义 Codex 命令

**目标**：使用特定的 Codex 配置

```yaml
---
codex:
  # 使用特定模型
  command: codex --model gpt-5.3-codex app-server

  # 启用推理分析
  command: codex --config model_reasoning_effort=xhigh app-server

  # 禁用沙箱 (仅用于完全可信环境)
  approval_policy: never
  thread_sandbox: danger-full-access

  # 自定义工具配置
  turn_sandbox_policy:
    type: workspaceWrite
    allowed_paths:
      - /custom/workspace/path
---

# 你的提示词
...
```

---

### 4.5 场景五：使用环境变量

**目标**：保护敏感信息，使用环境变量

```yaml
---
tracker:
  api_key: $LINEAR_API_KEY  # 从环境变量读取

workspace:
  root: $WORKSPACE_ROOT     # 从环境变量读取

hooks:
  after_create: |
    git clone "$REPO_URL" .
    # $SECRET_TOKEN 会在执行时展开
---

codex:
  command: "$CODEX_PATH app-server"
```

启动命令：

```bash
export LINEAR_API_KEY="xxx"
export WORKSPACE_ROOT="/path/to/workspaces"
export REPO_URL="https://github.com/org/repo"
export CODEX_PATH="/usr/local/bin/codex"

./bin/symphony ./WORKFLOW.md
```

---

## 5. 命令行参数

### 5.1 基本参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `WORKFLOW.md` | 工作流配置文件路径 | `./WORKFLOW.md` |
| `--port` | 启动 Web 服务端口 | `--port 4000` |
| `--logs-root` | 日志目录 | `--logs-root ./logs` |
| `--i-understand-that-this-will-be-running-without-the-usual-guardrails` | 确认无保护栏运行 | 必需 |

### 5.2 完整示例

```bash
./bin/symphony \
  --port 4000 \
  --logs-root /var/log/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

---

## 6. Web 界面

### 6.1 访问地址

启动时使用 `--port` 参数后，可通过以下地址访问：

- **Dashboard**: `http://localhost:4000/`
- **JSON API**: `http://localhost:4000/api/v1/*`

### 6.2 API 端点

| 端点 | 说明 |
|------|------|
| `GET /api/v1/state` | 获取当前系统状态 |
| `GET /api/v1/<issue_identifier>` | 获取特定问题的详细信息 |
| `POST /api/v1/refresh` | 强制刷新问题列表 |

---

## 7. 故障排查

### 7.1 常见问题

#### 问题：无法连接 Linear

```
Error: Linear API key is invalid
```

**解决方案**：
1. 确认 `LINEAR_API_KEY` 环境变量已设置
2. 检查 API 密钥是否有效
3. 验证项目 slug 是否正确

#### 问题：工作区创建失败

```
Error: Workspace creation failed
```

**解决方案**：
1. 检查 `workspace.root` 目录权限
2. 确认 `hooks.after_create` 脚本正确
3. 验证 Git 仓库 URL 可访问

#### 问题：Codex 启动失败

```
Error: Codex command not found
```

**解决方案**：
1. 确认 Codex 已安装
2. 检查 `codex.command` 配置
3. 验证 Codex 可执行权限

### 7.2 查看日志

```bash
# 查看实时日志
tail -f log/symphony.log

# 查看错误日志
grep "error" log/symphony.log
```

---

## 8. 最佳实践

### 8.1 安全建议

1. **使用最小权限 API 密钥**：创建只读 Linear API 密钥
2. **限制工作区位置**：确保工作区在安全路径
3. **启用审批策略**：生产环境使用 `on-failure` 或 `on-request`
4. **定期清理工作区**：配置 `before_remove` 钩子

### 8.2 性能优化

1. **合理设置并发数**：根据项目复杂度调整 `max_concurrent_agents`
2. **调整轮询间隔**：根据团队工作节奏调整 `polling.interval_ms`
3. **优化工作区创建**：使用 `--depth 1` 加速克隆

### 8.3 监控建议

1. **启用 Web 界面**：方便实时监控
2. **配置日志告警**：关键错误告警
3. **跟踪 Token 使用**：控制成本

---

## 附录

### A. 相关文件位置

- **主程序**: `elixir/bin/symphony`
- **配置文件**: `WORKFLOW.md`
- **日志目录**: `log/` (默认)
- **工作区**: `~/code/symphony-workspaces` (默认)

### B. 相关命令

```bash
# 开发测试
mix test                  # 运行测试
mix format               # 代码格式化
mix lint                 # 代码检查

# 构建发布
mix build                # 构建 escript

# 质量检查
make all                 # 完整质量门禁
```

### C. 依赖版本

- Elixir: 1.19+
- Erlang: OTP 28
- mise: 推荐用于版本管理
