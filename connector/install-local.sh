#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
# SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

set -eu
umask 077

task_tunnel=false
task_stop=false
task_mode=auto
for task_arg in "$@"; do
  case "$task_arg" in
    --tunnel) task_tunnel=true ;;
    --stop) task_stop=true ;;
    --node|--docker)
      [ "$task_mode" = auto ] || { echo '--node 与 --docker 只能选择一个。' >&2; exit 2; }
      task_mode=${task_arg#--} ;;
    -h|--help)
      echo '用法：sh connector/install-local.sh [--node | --docker] [--tunnel | --stop]'
      echo '首次优先使用 Node 22.5 以上，缺少合适的 Node 时才使用 Docker；重复运行沿用已有方式。'
      echo '默认在本机运行；--tunnel 开启 Cloudflare 快速隧道；--stop 停止服务并保留数据。'
      echo '端口默认 8787，可在 connector/.local/local.env 中修改 TINCALL_LOCAL_PORT。'
      exit 0 ;;
    *) printf '未知参数：%s。请使用 --help 查看用法。\n' "$task_arg" >&2; exit 2 ;;
  esac
done
if "$task_tunnel" && "$task_stop"; then
  echo '--tunnel 与 --stop 不能同时使用。' >&2; exit 2
fi
task_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
task_private="$task_directory/.local"
task_env="$task_private/local.env"
task_helper="$task_directory/local-service.mjs"
task_backend_file="$task_private/backend"
task_manager_file="$task_private/manager"
export TINCALL_LOCAL_ENV_FILE="$task_env"
compose() {
  docker compose --project-name tincall-local --project-directory "$task_directory" \
    --env-file "$task_env" -f "$task_directory/docker-compose.yml" "$@"
}
require_docker() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || {
    echo 'Docker 方式需要 Docker 和 Compose 插件。请按 https://docs.docker.com/get-started/get-docker/ 安装并启动，或安装 Node 后使用 --node。' >&2; exit 1
  }
  docker info >/dev/null 2>&1 || {
    echo '无法连接 Docker。请启动 Docker 并确认当前用户有权访问。' >&2; exit 1
  }
}
stop_pid() {
  task_kind=$1
  task_pid_file="$task_private/$task_kind.pid"
  [ -f "$task_pid_file" ] || return 0
  task_pid=$(cat "$task_pid_file")
  case "$task_pid" in ''|*[!0-9]*) echo '进程记录无效，请检查私密目录中的 pid 文件。' >&2; exit 1;; esac
  [ "$task_pid" -gt 1 ] || { echo '进程记录无效。' >&2; exit 1; }
  task_marker="$task_helper $task_kind $task_private "
  task_command=$(ps -p "$task_pid" -o command= 2>/dev/null || true)
  case "$task_command" in
    *"$task_marker"*)
      kill -TERM "$task_pid"
      task_attempt=0
      while [ "$task_attempt" -lt 15 ]; do
        task_command=$(ps -p "$task_pid" -o command= 2>/dev/null || true)
        case "$task_command" in *"$task_marker"*) ;; *) break;; esac
        sleep 1; task_attempt=$((task_attempt + 1))
      done
      task_command=$(ps -p "$task_pid" -o command= 2>/dev/null || true)
      case "$task_command" in *"$task_marker"*) kill -KILL "$task_pid";; esac ;;
    '') ;;
    *) echo '原进程已退出，pid 已被其他进程使用；未终止该进程。' >&2 ;;
  esac
  rm -f "$task_pid_file"
}
stop_node() {
  task_old_manager=$(cat "$task_manager_file" 2>/dev/null || true)
  for task_name in tunnel connector; do
    case "$task_old_manager" in
      launchd)
        task_target="$HOME/Library/LaunchAgents/com.tincall.$task_name.plist"
        if launchctl print "gui/$(id -u)/com.tincall.$task_name" >/dev/null 2>&1; then
          launchctl bootout "gui/$(id -u)/com.tincall.$task_name"
        fi
        rm -f "$task_target" ;;
      systemd)
        task_target="$HOME/.config/systemd/user/tincall-$task_name.service"
        if [ -f "$task_target" ]; then
          systemctl --user disable --now "tincall-$task_name.service"
          rm -f "$task_target"
        fi ;;
    esac
  done
  [ "$task_old_manager" != systemd ] || systemctl --user daemon-reload
  stop_pid tunnel
  stop_pid serve
  rm -f "$task_manager_file"
}

test ! -L "$task_private" && test ! -L "$task_env" || {
  echo '私密配置目录和文件不能是符号链接。请检查 connector/.local。' >&2; exit 1
}
task_previous=$(cat "$task_backend_file" 2>/dev/null || true)
case "$task_previous" in ''|node|docker) ;; *) echo '运行方式记录无效，请检查 connector/.local/backend。' >&2; exit 1;; esac
# Older Docker-only installs have local.env but no backend marker.
if [ -z "$task_previous" ] && [ -f "$task_env" ]; then
  if [ -f "$task_private/data/tincall.sqlite" ]; then task_previous=node
  else task_previous=docker
  fi
fi
if "$task_stop"; then
  if [ "$task_previous" = docker ] && [ -f "$task_env" ]; then require_docker; compose --profile tunnel stop; fi
  stop_node
  echo '服务已停止，开机自启已移除；令牌、数据库和媒体数据均已保留。'
  exit 0
fi

# Probe the real SQLite module, not just the version string. Node 22.5–22.12
# (and early Node 23) need --experimental-sqlite; later versions do not.
task_node=''
task_sqlite_flag=''
task_probe='const [a,b]=process.versions.node.split(".").map(Number);if(a<22||(a===22&&b<5))process.exit(1);const db=new(require("node:sqlite").DatabaseSync)(":memory:");db.prepare("SELECT 1").get();db.close();'
if command -v node >/dev/null 2>&1; then
  if node -e "$task_probe" >/dev/null 2>&1; then task_node=$(node -p 'process.execPath')
  elif node --experimental-sqlite -e "$task_probe" >/dev/null 2>&1; then
    task_node=$(node -p 'process.execPath'); task_sqlite_flag=--experimental-sqlite
  fi
fi
if [ "$task_mode" = auto ]; then
  if [ -n "$task_previous" ]; then task_mode=$task_previous
  elif [ -n "$task_node" ]; then task_mode=node
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then task_mode=docker
  else
    echo '未找到可用的 Node 或 Docker。推荐从 https://nodejs.org/ 安装 Node LTS（至少 22.5，且支持 node:sqlite），然后重新运行本脚本；无需 Docker，也无需 npm 依赖。' >&2; exit 1
  fi
fi
if [ -n "$task_previous" ] && [ "$task_previous" != "$task_mode" ]; then
  echo '已有安装使用另一种方式。为避免切换到空数据库，请先停止并手动迁移 SQLite 数据及媒体，再调整私密目录中的 backend 记录；脚本不会自动迁移或删除数据。' >&2; exit 1
fi
if [ "$task_mode" = node ]; then
  [ -n "$task_node" ] || { echo 'Node 方式需要可用的 Node 22.5 以上及 node:sqlite。推荐从 https://nodejs.org/ 安装 Node LTS 后重试。' >&2; exit 1; }
else require_docker
fi

mkdir -p "$task_private"
chmod 700 "$task_private"
if [ ! -e "$task_env" ]; then
  random_hex() {
    if [ -n "$task_node" ]; then "$task_node" -e 'process.stdout.write(require("node:crypto").randomBytes(Number(process.argv[1])).toString("hex"))' "$1"
    else openssl rand -hex "$1"
    fi
  }
  [ -n "$task_node" ] || command -v openssl >/dev/null 2>&1 || {
    echo 'Docker 方式首次生成令牌还需 OpenSSL；也可安装 Node LTS 后直接运行。' >&2; exit 1
  }
  task_phone=$(random_hex 32)
  task_worker=$(random_hex 32)
  task_owner_raw=$(random_hex 16)
  task_owner=$(printf '%s\n' "$task_owner_raw" | sed 's/^\(........\)\(....\).\(...\).\(...\)\(............\)$/\1-\2-4\3-8\4-\5/')
  task_temporary=$(mktemp "$task_private/local.env.XXXXXX")
  trap 'rm -f "$task_temporary"' 0
  trap 'exit 1' HUP INT TERM
  cat > "$task_temporary" <<EOF
TINCALL_LOCAL_PORT=8787
TINCALL_LOCAL_PHONE_TOKEN=$task_phone
TINCALL_CLIENTS=[{"token":"$task_phone","owner_id":"$task_owner"}]
TINCALL_WORKER_TOKEN=$task_worker
TINCALL_BINDINGS=[]
TINCALL_ALLOWED_ORIGINS=[]
EOF
  chmod 600 "$task_temporary"
  # Publish atomically without overwriting a concurrent install's credentials.
  ln "$task_temporary" "$task_env" || {
    echo '配置文件已出现，未覆盖任何令牌。请重新运行脚本。' >&2; exit 1
  }
  rm -f "$task_temporary"
  trap - 0 HUP INT TERM
  unset task_worker task_owner_raw
else
  echo '复用已有私密配置，保留令牌和数据。'
fi
test -f "$task_env" || { echo '私密配置不是普通文件。' >&2; exit 1; }
chmod 600 "$task_env"
printf '%s\n' "$task_mode" > "$task_backend_file"
# Read data only; never execute the private env file as a shell script.
task_phone=$(sed -n 's/^TINCALL_LOCAL_PHONE_TOKEN=//p' "$task_env")
task_port=${TINCALL_LOCAL_PORT:-$(sed -n 's/^TINCALL_LOCAL_PORT=//p' "$task_env")}
case "$task_phone" in ''|*[!0-9a-f]*) echo '手机令牌配置无效，请检查原配置文件，不要删除或重建令牌。' >&2; exit 1;; esac
test "${#task_phone}" -eq 64 || { echo '手机令牌配置不完整，请检查原配置文件。' >&2; exit 1; }
case "$task_port" in ''|*[!0-9]*|??????*) echo '端口必须是 1 至 65535 的整数。' >&2; exit 2;; esac
if [ "$task_port" -lt 1 ] || [ "$task_port" -gt 65535 ]; then
  echo '端口必须是 1 至 65535 的整数。' >&2; exit 2
fi
export TINCALL_LOCAL_PORT="$task_port"
task_url="http://127.0.0.1:$task_port"
if [ "$task_mode" = node ]; then
  task_cloudflared=''
  if "$task_tunnel"; then
    task_cloudflared=$(command -v cloudflared || true)
    if [ -z "$task_cloudflared" ]; then
      echo '未找到 cloudflared，已跳过隧道。需要外网访问时，请按 https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/ 安装后重新运行 --tunnel；本脚本不会安装软件。'
      task_tunnel=false
    fi
  fi
  stop_node
  task_manager=nohup
  case "$(uname -s)" in
    Darwin) task_manager=launchd ;;
    Linux) if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then task_manager=systemd; fi ;;
  esac
  if [ "$task_manager" = nohup ]; then
    command -v nohup >/dev/null 2>&1 || { echo '当前环境没有 nohup，无法在后台运行。请使用 macOS／Linux 的服务管理器或 Docker 方式。' >&2; exit 1; }
  fi
  # Recreate the quick-tunnel log to avoid printing a URL from the previous run.
  : > "$task_private/tunnel.log"
  touch "$task_private/connector.log"
  chmod 600 "$task_private/tunnel.log" "$task_private/connector.log"
  export TINCALL_SQLITE_FLAG="$task_sqlite_flag"
  if [ "$task_manager" != nohup ]; then
    "$task_node" "$task_helper" render "$task_private" "$task_port" "$task_manager" "$task_cloudflared"
  fi
  printf '%s\n' "$task_manager" > "$task_manager_file"
  for task_name in connector $(if "$task_tunnel"; then echo tunnel; fi); do
    task_kind=serve
    [ "$task_name" != tunnel ] || task_kind=tunnel
    case "$task_manager" in
      launchd)
        mkdir -p "$HOME/Library/LaunchAgents"
        task_target="$HOME/Library/LaunchAgents/com.tincall.$task_name.plist"
        cp "$task_private/$task_name.plist" "$task_target"
        chmod 600 "$task_target"
        plutil -lint "$task_target" >/dev/null
        launchctl enable "gui/$(id -u)/com.tincall.$task_name"
        launchctl bootstrap "gui/$(id -u)" "$task_target" ;;
      systemd)
        mkdir -p "$HOME/.config/systemd/user"
        cp "$task_private/tincall-$task_name.service" "$HOME/.config/systemd/user/"
        systemctl --user daemon-reload
        systemctl --user enable --now "tincall-$task_name.service" ;;
      nohup)
        if [ -n "$task_sqlite_flag" ]; then set -- "$task_node" "$task_sqlite_flag"; else set -- "$task_node"; fi
        nohup "$@" "$task_helper" "$task_kind" "$task_private" "$task_port" "$task_cloudflared" >> "$task_private/$task_name.log" 2>&1 < /dev/null &
        ;;
    esac
  done
  case "$task_manager" in
    launchd) echo '已配置 launchd：当前已启动，以后在用户登录时自动启动。' ;;
    systemd)
      if command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$(id -un)"; then
        echo '已启用 systemd 用户服务和 linger，可在开机后自动启动。'
      else echo '已启用 systemd 用户服务，登录后自动启动；如需开机后无需登录即可运行，请管理员执行 loginctl enable-linger 用户名。'; fi ;;
    nohup) echo '未找到可用的 launchd／systemd 用户服务，已用 nohup 后台运行；重启后需要重新执行本脚本。' ;;
  esac
  task_ready=false
  task_attempt=0
  while [ "$task_attempt" -lt 15 ]; do
    if "$task_node" "$task_helper" check "$task_private" "$task_port" >/dev/null 2>&1; then task_ready=true; break; fi
    task_attempt=$((task_attempt + 1)); sleep 2
  done
  "$task_ready" || { printf '连接端未通过启动检查，请查看 %s/connector.log；令牌和数据已保留。\n' "$task_private" >&2; exit 1; }
  printf 'Node 日志：%s/connector.log；数据：%s/data/\n' "$task_private" "$task_private"
else
  if "$task_tunnel"; then compose --profile tunnel up -d --build --force-recreate --wait --wait-timeout 90
  else
    compose --profile tunnel stop cloudflared
    compose up -d --build --force-recreate --wait --wait-timeout 90 connector
  fi
fi

if "$task_tunnel"; then
  task_url=''
  task_attempt=0
  while [ "$task_attempt" -lt 30 ]; do
    if [ "$task_mode" = node ]; then task_logs=$(cat "$task_private/tunnel.log")
    else task_logs=$(compose --profile tunnel logs --no-color cloudflared); fi
    task_url=$(printf '%s\n' "$task_logs" | sed -n 's|.*\(https://[a-z0-9-]*\.trycloudflare\.com\).*|\1|p' | tail -n 1)
    [ -z "$task_url" ] || break
    task_attempt=$((task_attempt + 1)); sleep 2
  done
  if [ -z "$task_url" ]; then
    echo '连接端已启动，但未在 60 秒内取得快速隧道地址。请检查隧道日志和网络后重新运行 --tunnel；原令牌和数据已保留。' >&2; exit 1
  fi
fi
printf '\n连接地址：%s\n手机访问令牌：%s\n' "$task_url" "$task_phone"
if "$task_tunnel"; then
  echo '请将上述 HTTPS 地址和令牌填入 Tincall「连接已有服务」页。'
  echo '快速隧道地址每次重启或更新都可能变化，变化后需更新 App 和 AI 平台的 MCP 地址。长期使用建议绑定自己的 Cloudflare 隧道，或使用有公网地址的服务器和 HTTPS 反向代理。'
else
  echo '上述 HTTP 地址仅供本机访问。手机和远程 AI 平台需要 HTTPS：没有公网地址时请加 --tunnel 重新运行；有公网地址时请配置 HTTPS 反向代理转发到上述地址，再将 HTTPS 地址和令牌填入 Tincall「连接已有服务」页。'
fi
printf '请妥善保管私密配置：%s（权限 600）。不要分享令牌。\n' "$task_env"
echo '电脑必须保持开机且不能休眠。'
