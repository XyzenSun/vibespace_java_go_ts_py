#!/bin/bash
set -e

# ============================================
# 对象存储持久化配置 (环境变量)
# ============================================
# OSS_ENABLED: 是否启用持久化 (默认 true)
# OSS_ENDPOINT: S3 endpoint (如 https://oss-cn-beijing.aliyuncs.com)
# OSS_ACCESS_KEY: Access Key ID
# OSS_SECRET_KEY: Secret Access Key
# OSS_BUCKET: 桶名
# OSS_REGION: 区域 (默认 auto)
# OSS_PROJECT: 项目名，用于快照文件命名前缀 (默认 devbox)
# OSS_PATHS: 要持久化的目录列表 (逗号分隔)
# OSS_KEEP_COUNT: 保留快照数量 (默认 3)
# OSS_SYNC_INTERVAL: 同步间隔分钟 (默认 30)

OSS_ENABLED="true"
OSS_ENDPOINT="${OSS_ENDPOINT:-}"
OSS_ACCESS_KEY="${OSS_ACCESS_KEY:-}"
OSS_SECRET_KEY="${OSS_SECRET_KEY:-}"
OSS_BUCKET="${OSS_BUCKET:-}"
OSS_REGION="${OSS_REGION:-auto}"
OSS_PROJECT="${OSS_PROJECT:-devbox}"
OSS_PATHS="${OSS_PATHS:-/root/.claude,/root/.ssh,/root/.cc-switch,/root/.local/share/code-server/User/globalStorage,/root/.vscode-server/data/User/globalStorage}"
OSS_KEEP_COUNT="${OSS_KEEP_COUNT:-5}"
OSS_SYNC_INTERVAL="${OSS_SYNC_INTERVAL:-5}"

# rclone 内联配置字符串
RCLONE_REMOTE=":s3,provider=Other,access_key_id='${OSS_ACCESS_KEY}',secret_access_key='${OSS_SECRET_KEY}',region='${OSS_REGION}',endpoint='${OSS_ENDPOINT}'"

# 快照命名格式: 项目名-cnb-YYYYMMDD-HHMMSS.tar.zst
SNAPSHOT_NAME="${OSS_PROJECT}-cnb-$(date +%Y%m%d-%H%M%S).tar.zst"

# ============================================
# 函数: 上传快照到对象存储
# ============================================
upload_snapshot() {
    if [ "$OSS_ENABLED" != "true" ] || [ -z "$OSS_ENDPOINT" ] || [ -z "$OSS_ACCESS_KEY" ]; then
        echo "[OSS] 持久化未配置，跳过上传"
        return 0
    fi
    if [ ! -f /root/syncflag.txt ]; then
        echo "[OSS] 警告：未检测到 /root/syncflag.txt 标记！"
        echo "[OSS] 原因：本次容器启动时未能成功恢复云端数据。"
        echo "[OSS] 动作：已拦截本次上传，以保护云端数据不被覆盖。"
        return 1
    fi

    echo "[OSS] 开始上传快照..."
    local staging_dir="/tmp/oss-staging-$(date +%s)"
    local snapshot_file="/tmp/${SNAPSHOT_NAME}"
    local copy_failed=0

    # 1. 复制目标目录/文件到 staging
    mkdir -p "$staging_dir"
    IFS=, read -ra PATHS <<< "$OSS_PATHS"
    for path in "${PATHS[@]}"; do
        if [ -d "$path" ]; then
            # 目录：保持相对路径结构
            local rel_path="${path#/}"
            local target_dir="$staging_dir/$rel_path"
            mkdir -p "$target_dir"
            if ! cp -a "$path/." "$target_dir/"; then
                echo "[OSS] 复制失败: $path"
                copy_failed=1
            else
                echo "[OSS] 已复制: $path"
            fi
        elif [ -f "$path" ]; then
            # 文件：复制到对应父目录
            local rel_path="${path#/}"
            local parent_dir="$(dirname "$rel_path")"
            local target_parent="$staging_dir/$parent_dir"
            mkdir -p "$target_parent"
            if ! cp -a "$path" "$target_parent/"; then
                echo "[OSS] 复制失败: $path"
                copy_failed=1
            else
                echo "[OSS] 已复制: $path"
            fi
        else
            echo "[OSS] 跳过（不存在）: $path"
        fi
    done

    # 复制失败则中止，不上传，不清理旧快照
    if [ $copy_failed -eq 1 ]; then
        echo "[OSS] 复制阶段失败，中止上传"
        rm -rf "$staging_dir"
        return 1
    fi

    # 2. 打包为 tar.zst
    echo "[OSS] 打包压缩..."
    if ! tar -I zstd -cf "$snapshot_file" -C "$staging_dir" .; then
        echo "[OSS] 打包失败，中止上传"
        rm -rf "$staging_dir" "$snapshot_file"
        return 1
    fi

    # 3. 上传到对象存储
    local remote_path="${OSS_BUCKET}/${SNAPSHOT_NAME}"
    echo "[OSS] 上传到: $remote_path"
    if ! rclone copyto "$snapshot_file" "${RCLONE_REMOTE}:${remote_path}" -P --quiet >> /var/log/vibespace-rclone.log 2>&1; then
        echo "[OSS] 上传失败"
        rm -rf "$staging_dir" "$snapshot_file"
        return 1
    fi

    # 4. 清理本地临时文件
    rm -rf "$staging_dir" "$snapshot_file"

    # 5. 清理旧快照，保留最近 N 份
    echo "[OSS] 清理旧快照，保留 ${OSS_KEEP_COUNT} 份..."
    rclone lsf "${RCLONE_REMOTE}:${OSS_BUCKET}/" --files-only 2>> /var/log/vibespace-rclone.log | \
        grep "^${OSS_PROJECT}-cnb-" | sort -r | \
        tail -n +$((OSS_KEEP_COUNT + 1)) | \
        while IFS= read -r snap; do
            if [ -n "$snap" ]; then
                echo "[OSS] 删除旧快照: $snap"
                rclone delete "${RCLONE_REMOTE}:${OSS_BUCKET}/$snap" --quiet >> /var/log/vibespace-rclone.log 2>&1 || true
            fi
        done

    echo "[OSS] 上传完成"
}

# ============================================
# 函数: 从对象存储恢复快照
# ============================================
restore_snapshot() {
    if [ "$OSS_ENABLED" != "true" ] || [ -z "$OSS_ENDPOINT" ] || [ -z "$OSS_ACCESS_KEY" ]; then
        echo "[OSS] 持久化未配置，跳过恢复"
        return 0
    fi

    echo "[OSS] 开始恢复快照..."

    # 1. 查找最新快照
    local latest_snapshot
    latest_snapshot=$(rclone lsf "${RCLONE_REMOTE}:${OSS_BUCKET}/" --files-only 2>> /var/log/vibespace-rclone.log | grep "^${OSS_PROJECT}-cnb-" | sort -r | head -1)

    if [ -z "$latest_snapshot" ]; then
        echo "[OSS] 未找到快照，视为首次运行，允许同步"
        touch /root/syncflag.txt
        return 0
    fi

    echo "[OSS] 最新快照: $latest_snapshot"

    # 2. 下载快照
    local snapshot_file="/tmp/${latest_snapshot}"
    local remote_path="${OSS_BUCKET}/${latest_snapshot}"
    echo "[OSS] 下载快照..."
    if ! rclone copyto "${RCLONE_REMOTE}:${remote_path}" "$snapshot_file" --quiet >> /var/log/vibespace-rclone.log 2>&1; then
        echo "[OSS] 下载失败，跳过恢复"
        return 1
    fi

    # 3. 备份当前目录 (防止恢复失败导致数据丢失)
    echo "[OSS] 备份当前目录..."
    local backup_dir="/tmp/pre-restore-backup-$(date +%s)"
    mkdir -p "$backup_dir"
    IFS=, read -ra PATHS <<< "$OSS_PATHS"
    for path in "${PATHS[@]}"; do
        if [ -d "$path" ]; then
            # 目录：备份整个目录
            local rel_path="${path#/}"
            mkdir -p "$backup_dir/$rel_path"
            cp -a "$path/." "$backup_dir/$rel_path/" 2>/dev/null || true
        elif [ -f "$path" ]; then
            # 文件：备份到对应父目录
            local rel_path="${path#/}"
            local parent_dir="$(dirname "$rel_path")"
            mkdir -p "$backup_dir/$parent_dir"
            cp -a "$path" "$backup_dir/$parent_dir/" 2>/dev/null || true
        fi
    done

    # 4. 清空目标目录/删除目标文件
    echo "[OSS] 清空目标..."
    for path in "${PATHS[@]}"; do
        if [ -d "$path" ]; then
            # 目录：清空内容
            rm -rf "$path"/* 2>/dev/null || true
            rm -rf "$path"/.[!.]* 2>/dev/null || true
            rm -rf "$path"/..?* 2>/dev/null || true
        elif [ -f "$path" ]; then
            # 文件：直接删除
            rm -f "$path" 2>/dev/null || true
        fi
    done

    # 5. 解包恢复
    echo "[OSS] 解包恢复..."
    local staging_dir="/tmp/oss-restore-$(date +%s)"
    mkdir -p "$staging_dir"
    if ! tar -I zstd -xf "$snapshot_file" -C "$staging_dir"; then
        echo "[OSS] 解包失败，恢复备份..."
        for path in "${PATHS[@]}"; do
            local rel_path="${path#/}"
            if [ -d "$backup_dir/$rel_path" ]; then
                # 目录：恢复整个目录
                mkdir -p "$path"
                cp -a "$backup_dir/$rel_path/." "$path/" 2>/dev/null || true
            elif [ -f "$backup_dir/$rel_path" ]; then
                # 文件：恢复单个文件
                local parent_dir="$(dirname "$path")"
                mkdir -p "$parent_dir"
                cp -a "$backup_dir/$rel_path" "$path" 2>/dev/null || true
            fi
        done
        rm -rf "$snapshot_file" "$staging_dir" "$backup_dir"
        return 1
    fi

    # 6. 复制恢复的文件到目标位置
    for path in "${PATHS[@]}"; do
        local rel_path="${path#/}"
        if [ -d "$staging_dir/$rel_path" ]; then
            # 目录：恢复整个目录
            mkdir -p "$path"
            cp -a "$staging_dir/$rel_path/." "$path/" 2>/dev/null || true
            echo "[OSS] 已恢复: $path"
        elif [ -f "$staging_dir/$rel_path" ]; then
            # 文件：恢复单个文件
            local parent_dir="$(dirname "$path")"
            mkdir -p "$parent_dir"
            cp -a "$staging_dir/$rel_path" "$path" 2>/dev/null || true
            echo "[OSS] 已恢复: $path"
        fi
    done

    # 7. 清理临时文件
    rm -rf "$snapshot_file" "$staging_dir" "$backup_dir"
    touch /root/syncflag.txt
    echo "[OSS] 恢复完成"
}

# ============================================
# 函数: 定时同步 (cron)
# ============================================
setup_periodic_sync() {
    if [ "$OSS_ENABLED" != "true" ]; then
        return 0
    fi

    # 使用 /etc/cron.d/ 目录，避免覆盖其他 cron 任务
    cat > /etc/cron.d/oss-sync << 'CRON_EOF'
# OSS 定时同步任务
*/OSS_SYNC_INTERVAL * * * * root /usr/local/bin/entrypoint.sh --sync >> /var/log/oss-sync.log 2>&1

CRON_EOF

    # 替换间隔变量
    sed -i "s/OSS_SYNC_INTERVAL/${OSS_SYNC_INTERVAL}/g" /etc/cron.d/oss-sync

    # 设置正确权限
    chmod 644 /etc/cron.d/oss-sync

    # 启动 cron 服务
    service cron start 2>/dev/null || cron 2>/dev/null || true

    echo "[OSS] 定时同步已启用，间隔 ${OSS_SYNC_INTERVAL} 分钟"
}



# 支持 --sync 参数，仅执行上传（用于 cron 定时任务）
if [ "$1" = "--sync" ]; then
    # cron 无法继承容器环境变量，从 PID 1 (容器主进程) 读取
    eval $(cat /proc/1/environ | tr '\0' '\n' | grep -E '^OSS_' | sed 's/^/export /')
    upload_snapshot
    exit $?
fi

# 支持 --commands 参数（交互式菜单）
if [ "$1" = "--commands" ]; then
    echo "============================================"
    echo "  Vibespace 管理菜单"
    echo "============================================"
    echo "  1. 上传到对象存储"
    echo "  2. 从对象存储下载并覆盖本地"
    echo "  3. 手动同步 (上传快照)"
    echo "  0. 退出"
    echo "============================================"
    read -p "请选择操作 [0-3]: " choice

    case "$choice" in
        1)
            echo "[操作] 上传到对象存储..."
            upload_snapshot
            ;;
        2)
            echo "[操作] 从对象存储下载并覆盖本地..."
            # 先清空 syncflag 以允许强制覆盖
            rm -f /root/syncflag.txt
            restore_snapshot
            ;;
        3)
            echo "[操作] 手动同步 (上传快照)..."
            upload_snapshot
            ;;
        0)
            echo "退出"
            exit 0
            ;;
        *)
            echo "无效选择: $choice"
            exit 1
            ;;
    esac
    exit 0
fi
# ============================================
# 容器启动执行
# ============================================
rm -f /root/syncflag.txt


# --- 从对象存储恢复 ---
restore_snapshot

# --- 恢复 /root 默认文件 ---
cp -an /root-defaults/root/. /root/ 2>/dev/null || true

# --- Git ---
if [ -n "$GIT_USER_NAME" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# --- SSH authorized_keys ---
if [ -n "$SSH_PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    echo "$SSH_PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

# --- SSH 密码 ---
echo "root:${ROOT_PASSWORD:-root123}" | chpasswd

# --- code-server 认证 ---
AUTH_ARGS="--auth none"
if [ -n "$CS_PASSWORD" ]; then
    export PASSWORD="$CS_PASSWORD"
    AUTH_ARGS="--auth password"
fi

# --- 设置定时同步 ---
setup_periodic_sync

# --- 启动SSH ---
/usr/sbin/sshd

# --- code-server (CNB 平台) ---
# CNB 会自动注入 code-server 进程，检测是否已运行
if pgrep -f '(^|/)code-server( |$)' >/dev/null || pgrep -f '/usr/lib/code-server/lib/node /usr/lib/code-server' >/dev/null; then
 echo "[code-server] 检测到 CNB 注入的进程，跳过启动"
else
 exec code-server --bind-addr 0.0.0.0:12345 $AUTH_ARGS /workspace
fi