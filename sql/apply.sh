#!/usr/bin/env bash
# =============================================================================
# Hysteria VPN 聚合平台 · 数据库一键建库脚本
#
# 用法:
#   ./apply.sh                                  # 默认 127.0.0.1:3306 root 无密码
#   DB_HOST=10.0.0.5 DB_USER=app DB_PASS=xxx DB_NAME=hysteria ./apply.sh
#   ./apply.sh --with-triggers                  # 附带启用可选触发器
#   ./apply.sh --verify                         # 建库后跑一遍对账/巡检 SQL
#
# 要求: MySQL >= 8.0.16 客户端 + 服务端（CHECK 约束 8.0.16 起生效）
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-hysteria}"

WITH_TRIGGERS=0
VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --with-triggers) WITH_TRIGGERS=1 ;;
    --verify)        VERIFY=1 ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

command -v mysql >/dev/null 2>&1 || { echo "[x] 未找到 mysql 客户端"; exit 1; }

MYSQL_ARGS=(-h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" --default-character-set=utf8mb4)
[ -n "$DB_PASS" ] && MYSQL_ARGS+=("-p${DB_PASS}")

# 所有脚本统一注入会话基线：UTF8MB4 排序规则 + 强制 UTC
SESSION_SQL=$'SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;\nSET SESSION time_zone = \'+00:00\';\n'

run_file() {  # run_file <sql文件> [库名]
  local file="$1"
  local db="${2:-}"
  echo "[+] 执行 ${file}"
  if [ -n "$db" ]; then
    printf '%s' "$SESSION_SQL" | cat - "$file" | mysql "${MYSQL_ARGS[@]}" -D"$db" --show-warnings
  else
    printf '%s' "$SESSION_SQL" | cat - "$file" | mysql "${MYSQL_ARGS[@]}" --show-warnings
  fi
}

echo "=== 目标库: ${DB_NAME} @ ${DB_HOST}:${DB_PORT} (user=${DB_USER}) ==="

VER=$(mysql "${MYSQL_ARGS[@]}" -N -B -e "SELECT VERSION();")
echo "[i] MySQL 版本: ${VER}"
case "$VER" in
  8.0.1[6-9]|8.0.[2-9][0-9]|8.[1-9].*|9.*) ;;
  *) echo "[!] 警告: 版本 < 8.0.16 时 CHECK 约束会被静默忽略；非 MySQL 8（如 MariaDB）不支持 utf8mb4_0900_ai_ci / LATERAL，建表会失败" ;;
esac

echo "[+] 创建数据库 ${DB_NAME}"
mysql "${MYSQL_ARGS[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"

# 建表顺序严格按外键依赖排列（00_create_database.sql 仅供手工执行，此处由脚本代替）
FILES=(
  "01_users_points.sql"
  "02_providers_and_nodes.sql"
  "03_provider_points.sql"
  "04_traffic.sql"
  "05_billing.sql"
  "06_settlement.sql"
)
for f in "${FILES[@]}"; do
  run_file "$f" "$DB_NAME"
done

if [ "$WITH_TRIGGERS" = "1" ]; then
  run_file "07_triggers_optional.sql" "$DB_NAME"
else
  echo "[i] 跳过可选触发器（需要时加 --with-triggers）"
fi

run_file "08_partition_maintenance.sql" "$DB_NAME"

echo "[+] 自检: 表清单 / 引擎 / 排序规则 / 分区"
mysql "${MYSQL_ARGS[@]}" -D"${DB_NAME}" -e "
SELECT t.TABLE_NAME, t.ENGINE, t.TABLE_COLLATION,
       COALESCE(CAST(p.cnt AS CHAR), '0') AS partitions
FROM information_schema.TABLES t
LEFT JOIN (SELECT TABLE_NAME, COUNT(*) cnt FROM information_schema.PARTITIONS
           WHERE TABLE_SCHEMA = DATABASE() GROUP BY TABLE_NAME) p
       ON p.TABLE_NAME = t.TABLE_NAME
WHERE t.TABLE_SCHEMA = DATABASE()
ORDER BY t.TABLE_NAME;"

echo "[+] 自检: 生成列（应看到 active_binding_key / signed_amount / total_bytes）"
mysql "${MYSQL_ARGS[@]}" -D"${DB_NAME}" -e "
SELECT TABLE_NAME, COLUMN_NAME, GENERATION_EXPRESSION
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND GENERATION_EXPRESSION <> ''
ORDER BY TABLE_NAME, COLUMN_NAME;"

echo "[+] 自检: 唯一索引 uk_user_active_binding（保证一人一 active 绑定）"
mysql "${MYSQL_ARGS[@]}" -D"${DB_NAME}" -e "
SELECT INDEX_NAME, COLUMN_NAME, NON_UNIQUE
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user_provider_bindings'
ORDER BY INDEX_NAME, SEQ_IN_INDEX;"

if [ "$VERIFY" = "1" ]; then
  echo "[+] 执行 09_reconciliation_queries.sql（空库下对账结果应为空集）"
  mysql "${MYSQL_ARGS[@]}" -D"${DB_NAME}" --show-warnings < "09_reconciliation_queries.sql" || true
fi

echo
echo "✅ 建库完成: ${DB_NAME}"
echo "   连接: mysql -h${DB_HOST} -P${DB_PORT} -u${DB_USER} ${DB_NAME}"
