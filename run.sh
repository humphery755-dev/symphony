#!/bin/bash

# HuggingFace 镜像加速 (国内网络环境优化)
export HF_ENDPOINT=https://hf-mirror.com
export PRG_HOME="$(cd "$(dirname "$0")" && pwd)"
echo "PRG_HOME=$PRG_HOME"
[ -f "$PRG_HOME/.env" ] && export $(grep -v '^#' $PRG_HOME/.env | xargs)
cmd="$1"
shift

#export -p
#codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh -m moonshotai/kimi-k2.5 app-server
#codex -q -p aicoding -m openai/gpt-5.3-codex "Hello"
#codex -q --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh -m qwen/qwen3.5-397b-a17b app-server
#exit 0
#codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model openai/gpt-5.3-codex app-server

# =============================================================================
# 命令路由表
# =============================================================================

# 清理临时文件
_start_time=`date +%s`
find . -name "__pycache__" -type d -exec rm -rf {} +
find . -name ".ipynb_checkpoints" -type d -exec rm -rf {} +
rm -rf elixir/log/*

case $cmd in
  workflow)
    codex app-server --config shell_environment_policy.inherit=all
    ;;
  debug)
    echo "*** debug ***: $@"
    #codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh -m moonshotai/kimi-k2.5 app-server
    codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh -m deepseek-v4-pro app-server
    ;;
  stop)
    pkill -f 'bin/symphony' && echo 'Symphony stopped' || echo 'No Symphony process found'
    ;;

  dev)
    echo '*** Building Symphony escript ***'
    cd $PRG_HOME/elixir && mise exec -- mix escript.build
    cd $PRG_HOME/elixir && mise exec -- ./bin/symphony \
      --port 4000 \
      --i-understand-that-this-will-be-running-without-the-usual-guardrails \
      ../_test/WORKFLOW.md
    ;;
  # 未知命令
  *)
    echo "[BASH DEBUG] Entering default symphony execution" >&2
esac
_end_time=`date +%s`
echo "本次运行时间： "$((_end_time - _start_time))"s"
