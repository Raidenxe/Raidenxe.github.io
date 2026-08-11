#!/bin/bash
# Redis 集群管理脚本 - 核心逻辑精简版
# 功能：主从复制、哨兵、Redis Cluster
# 说明：本版本仅保留核心功能逻辑，删除了详细日志、缓存、颜色输出等辅助代码

set -e

# ============ 基础配置 ============
REDIS_PORT="6379"
CONF_FILE="/etc/redis/redis.conf"
SERVICE_NAME="redis"
SENTINEL_CONF="/etc/redis/sentinel.conf"
SENTINEL_PORT="26379"
SENTINEL_SERVICE="redis-sentinel"

# ============ 辅助函数 ============
get_redis_password() {
    grep "^requirepass" "$CONF_FILE" 2>/dev/null | awk '{print $2}'
}

redis_cli() {
    local pass=$(get_redis_password)
    if [[ -n "$pass" ]]; then
        redis-cli -a "$pass" --no-auth-warning "$@"
    else
        redis-cli --no-auth-warning "$@"
    fi
}

redis_cluster_cli() {
    local pass=$(get_redis_password)
    if [[ -n "$pass" ]]; then
        redis-cli -a "$pass" --no-auth-warning --cluster "$@"
    else
        redis-cli --no-auth-warning --cluster "$@"
    fi
}

sentinel_cli() {
    local pass=$(grep "^sentinel auth-pass" "$SENTINEL_CONF" 2>/dev/null | head -1 | awk '{print $NF}')
    if [[ -n "$pass" ]]; then
        redis-cli -p "$SENTINEL_PORT" -a "$pass" --no-auth-warning "$@"
    else
        redis-cli -p "$SENTINEL_PORT" --no-auth-warning "$@"
    fi
}

# ============================================================
# 第一部分：主从复制
# ============================================================

# 1. 配置主节点复制参数
cluster_setup_master() {
    echo "▶ 配置主节点复制参数"
    redis_cli CONFIG SET replica-serve-stale-data yes
    
    local min_replicas=$(redis_cli CONFIG GET min-replicas-to-write | tail -n1)
    if [[ "$min_replicas" == "0" ]]; then
        read -p "设置最小从节点数（建议1）: " val
        [[ "$val" -gt 0 ]] && redis_cli CONFIG SET min-replicas-to-write "$val"
    fi
    
    local pass=$(get_redis_password)
    if [[ -n "$pass" ]]; then
        redis_cli CONFIG SET masterauth "$pass"
    fi
    echo "✓ 主节点配置完成"
}

# 2. 挂载从节点
cluster_add_slave() {
    echo "▶ 挂载从节点"
    read -p "主节点 IP: " master_ip
    read -p "主节点端口 [6379]: " master_port
    master_port=${master_port:-6379}
    read -s -p "主节点密码（回车跳过）: " master_pass
    echo
    
    # 测试连通性
    if [[ -n "$master_pass" ]]; then
        redis-cli -h "$master_ip" -p "$master_port" -a "$master_pass" PING &>/dev/null || {
            echo "✘ 无法连接主节点"; return 1
        }
    else
        redis-cli -h "$master_ip" -p "$master_port" PING &>/dev/null || {
            echo "✘ 无法连接主节点"; return 1
        }
    fi
    
    # 配置从节点
    [[ -n "$master_pass" ]] && redis_cli CONFIG SET masterauth "$master_pass"
    redis_cli CONFIG SET replica-read-only yes
    redis_cli REPLICAOF "$master_ip" "$master_port"
    
    # 持久化配置
    sed -i "/^replicaof/d" "$CONF_FILE"
    echo "replicaof $master_ip $master_port" >> "$CONF_FILE"
    echo "✓ 从节点已挂载到 $master_ip:$master_port"
}

# 3. 查看复制状态
cluster_status() {
    echo "▶ 主从复制状态"
    redis_cli INFO replication | grep -E "^(role|master_host|master_port|master_link_status|connected_slaves|slave_repl_offset|master_repl_offset):"
}

# 4. 提升从节点为主节点（故障切换）
cluster_failover() {
    echo "▶ 提升从节点为主节点"
    local role=$(redis_cli INFO replication | grep '^role:' | cut -d: -f2 | tr -d '\r')
    if [[ "$role" != "slave" ]]; then
        echo "✘ 当前不是从节点，无法提升"; return 1
    fi
    read -p "确认提升？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    redis_cli REPLICAOF NO ONE
    sed -i "s/^replicaof/#replicaof/" "$CONF_FILE"
    echo "✓ 已提升为主节点"
}

# 5. 主从复制菜单
cluster_menu() {
    while true; do
        echo "========== 主从复制管理 =========="
        echo "1) 配置主节点"
        echo "2) 挂载从节点"
        echo "3) 查看复制状态"
        echo "4) 提升从节点为主节点"
        echo "5) 返回"
        read -p "选择 [1-5]: " choice
        case $choice in
            1) cluster_setup_master ;;
            2) cluster_add_slave ;;
            3) cluster_status ;;
            4) cluster_failover ;;
            5) break ;;
        esac
    done
}

# ============================================================
# 第二部分：哨兵（Sentinel）
# ============================================================

# 1. 初始化哨兵配置
sentinel_init() {
    echo "▶ 初始化哨兵配置"
    read -p "集群名称 [mymaster]: " name
    name=${name:-mymaster}
    read -p "主节点 IP: " ip
    read -p "主节点端口 [6379]: " port
    port=${port:-6379}
    read -p "quorum [2]: " quorum
    quorum=${quorum:-2}
    read -s -p "主节点密码（回车跳过）: " pass
    echo
    
    cat > "$SENTINEL_CONF" <<EOF
port $SENTINEL_PORT
protected-mode no
pidfile /var/run/redis-sentinel.pid
sentinel monitor $name $ip $port $quorum
sentinel down-after-milliseconds $name 5000
sentinel failover-timeout $name 60000
sentinel parallel-syncs $name 1
$( [[ -n "$pass" ]] && echo "sentinel auth-pass $name $pass" )
logfile /var/log/redis/sentinel.log
dir /var/lib/redis
EOF
    echo "✓ 哨兵配置已生成: $SENTINEL_CONF"
    
    # 生成 systemd 服务
    cat > /etc/systemd/system/redis-sentinel.service <<EOF
[Unit]
Description=Redis Sentinel
After=network.target
[Service]
Type=simple
ExecStart=$(which redis-server) $SENTINEL_CONF --sentinel
ExecStop=$(which redis-cli) -p $SENTINEL_PORT SHUTDOWN
User=redis
Group=redis
LimitNOFILE=1000000
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo "✓ systemd 服务已创建"
}

# 2. 启动哨兵
sentinel_start() {
    systemctl start redis-sentinel 2>/dev/null || {
        redis-server "$SENTINEL_CONF" --sentinel &
    }
    echo "✓ 哨兵已启动"
}

# 3. 停止哨兵
sentinel_stop() {
    systemctl stop redis-sentinel 2>/dev/null || {
        redis-cli -p "$SENTINEL_PORT" SHUTDOWN 2>/dev/null
        pkill -f "redis.*sentinel.*$SENTINEL_CONF" 2>/dev/null
    }
    echo "✓ 哨兵已停止"
}

# 4. 查看哨兵状态
sentinel_status() {
    echo "▶ 哨兵监控状态"
    local masters=$(sentinel_cli SENTINEL masters 2>/dev/null | grep -A1 '"name"' | grep -v '"name"' | tr -d '"' | tr -d ' ')
    if [[ -z "$masters" ]]; then
        echo "⚠ 无监控的集群"
        return
    fi
    for name in $masters; do
        echo "集群: $name"
        sentinel_cli SENTINEL master "$name" 2>/dev/null | grep -E '"(ip|port|flags)"' | paste -d: - - | sed 's/^/  /'
        sentinel_cli SENTINEL slaves "$name" 2>/dev/null | grep -E '"(ip|port|flags)"' | paste -d: - - | sed 's/^/  从节点: /'
    done
}

# 5. 手动触发故障转移
sentinel_failover() {
    echo "▶ 手动触发故障转移"
    local masters=$(sentinel_cli SENTINEL masters 2>/dev/null | grep -A1 '"name"' | grep -v '"name"' | tr -d '"' | tr -d ' ')
    if [[ -z "$masters" ]]; then
        echo "✘ 无可用集群"; return 1
    fi
    local i=1
    for name in $masters; do
        echo "$i) $name"; ((i++))
    done
    read -p "选择集群编号: " idx
    local target=$(echo "$masters" | sed -n "${idx}p")
    [[ -z "$target" ]] && { echo "✘ 无效选择"; return 1; }
    read -p "确认触发 $target 故障转移？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    sentinel_cli SENTINEL FAILOVER "$target"
    echo "✓ 故障转移已触发"
}

# 6. 哨兵菜单
sentinel_menu() {
    while true; do
        echo "========== 哨兵管理 =========="
        echo "1) 初始化哨兵配置"
        echo "2) 启动哨兵"
        echo "3) 停止哨兵"
        echo "4) 查看监控状态"
        echo "5) 手动触发故障转移"
        echo "6) 返回"
        read -p "选择 [1-6]: " choice
        case $choice in
            1) sentinel_init ;;
            2) sentinel_start ;;
            3) sentinel_stop ;;
            4) sentinel_status ;;
            5) sentinel_failover ;;
            6) break ;;
        esac
    done
}

# ============================================================
# 第三部分：Redis Cluster
# ============================================================

# 1. 创建集群
redis_cluster_create() {
    echo "▶ 创建 Redis Cluster"
    read -p "节点列表 (ip:port ...): " nodes
    read -p "副本数 [1]: " replicas
    replicas=${replicas:-1}
    read -p "确认创建？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    # shellcheck disable=SC2086
    redis_cluster_cli create $nodes --cluster-replicas "$replicas" --cluster-yes
}

# 2. 查看集群状态
redis_cluster_status() {
    echo "▶ 集群状态"
    read -p "任意节点 (ip:port): " entry
    echo "--- CLUSTER INFO ---"
    redis_cli -h "${entry%:*}" -p "${entry#*:}" CLUSTER INFO
    echo "--- CLUSTER NODES ---"
    redis_cli -h "${entry%:*}" -p "${entry#*:}" CLUSTER NODES | awk '{print $2, $3, $8, $9}'
}

# 3. 添加节点
redis_cluster_add_node() {
    echo "▶ 添加节点"
    read -p "集群中任意节点: " existing
    read -p "新节点: " new_node
    read -p "作为从节点？(y/n): " as_slave
    if [[ "$as_slave" == "y" ]]; then
        read -p "主节点ID（回车随机）: " master_id
        if [[ -n "$master_id" ]]; then
            redis_cluster_cli add-node "$new_node" "$existing" --cluster-slave --cluster-master-id "$master_id"
        else
            redis_cluster_cli add-node "$new_node" "$existing" --cluster-slave
        fi
    else
        redis_cluster_cli add-node "$new_node" "$existing"
    fi
}

# 4. 移除节点
redis_cluster_del_node() {
    echo "▶ 移除节点"
    read -p "集群中任意节点: " entry
    echo "当前节点列表:"
    redis_cli -h "${entry%:*}" -p "${entry#*:}" CLUSTER NODES | awk '{print NR")", $2, $3}' | head -10
    read -p "要移除的节点ID: " node_id
    read -p "确认移除？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    redis_cluster_cli del-node "$entry" "$node_id"
}

# 5. 重新分片
redis_cluster_reshard() {
    echo "▶ 重新分片"
    read -p "任意节点: " entry
    read -p "迁移槽位数: " slots
    read -p "目标节点ID（回车自动分配）: " target
    read -p "源节点ID（回车从所有节点）: " source
    local args=("reshard" "$entry" "--cluster-slots" "$slots" "--cluster-yes")
    [[ -n "$source" ]] && args+=("--cluster-from" "$source") || args+=("--cluster-from" "all")
    [[ -n "$target" ]] && args+=("--cluster-to" "$target")
    redis_cluster_cli "${args[@]}"
}

# 6. 负载均衡
redis_cluster_rebalance() {
    echo "▶ 负载均衡"
    read -p "任意节点: " entry
    read -p "权重（可选）: " weight
    local args=("rebalance" "$entry" "--cluster-yes")
    [[ -n "$weight" ]] && args+=("--cluster-weight" "$weight")
    redis_cluster_cli "${args[@]}"
}

# 7. 健康检查
redis_cluster_check() {
    echo "▶ 健康检查"
    read -p "任意节点: " entry
    redis_cluster_cli check "$entry"
}

# 8. 集群修复
redis_cluster_fix() {
    echo "▶ 集群修复"
    read -p "任意节点: " entry
    read -p "确认修复？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    redis_cluster_cli fix "$entry"
}

# 9. Redis Cluster 菜单
redis_cluster_menu() {
    while true; do
        echo "========== Redis Cluster 管理 =========="
        echo "1) 创建集群"
        echo "2) 查看集群状态"
        echo "3) 添加节点"
        echo "4) 移除节点"
        echo "5) 重新分片"
        echo "6) 负载均衡"
        echo "7) 健康检查"
        echo "8) 集群修复"
        echo "9) 返回"
        read -p "选择 [1-9]: " choice
        case $choice in
            1) redis_cluster_create ;;
            2) redis_cluster_status ;;
            3) redis_cluster_add_node ;;
            4) redis_cluster_del_node ;;
            5) redis_cluster_reshard ;;
            6) redis_cluster_rebalance ;;
            7) redis_cluster_check ;;
            8) redis_cluster_fix ;;
            9) break ;;
        esac
    done
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
    clear
    echo "########################################"
    echo "   Redis 集群管理脚本 - 核心精简版"
    echo "########################################"
    echo "1) 主从复制管理"
    echo "2) 哨兵管理"
    echo "3) Redis Cluster 管理"
    echo "0) 退出"
    read -p "选择 [0-3]: " choice
    case $choice in
        1) cluster_menu ;;
        2) sentinel_menu ;;
        3) redis_cluster_menu ;;
        0) exit 0 ;;
    esac
}

# ============================================================
# 入口
# ============================================================
[[ $EUID -ne 0 ]] && { echo "请使用 root 执行"; exit 1; }

while true; do
    main_menu
    echo ""
    read -p "按 Enter 返回菜单..."
done