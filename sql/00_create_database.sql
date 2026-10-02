-- =============================================================================
-- Hysteria VPN 聚合平台 · 数据库初始化
-- MySQL 8.0.16+ / InnoDB / utf8mb4_0900_ai_ci / UTC / DECIMAL(30,8) 不落浮点
-- =============================================================================
-- 前置要求：
--   * MySQL >= 8.0.16（CHECK 约束自 8.0.16 起才真正生效）
--   * 建议 my.cnf:  default-time-zone='+00:00'   innodb_file_per_table=ON
--   * 动态时区表已导入（mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql mysql）
-- =============================================================================

CREATE DATABASE IF NOT EXISTS `hysteria` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

USE `hysteria`;

SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET SESSION time_zone = '+00:00';   -- 全库时间统一 UTC，禁止依赖服务器本地时区
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO';
SET FOREIGN_KEY_CHECKS = 1;         -- 建表顺序已按依赖排列，无需关闭外键检查

-- -----------------------------------------------------------------------------
-- 建表顺序（严格按依赖，apply.sh 会依次执行）
--   01_users_points.sql           users / 钱包 / 套餐 / 订单 / 用户账本
--   02_providers_and_nodes.sql    providers / nodes / 定价 / 绑定 / 切换日志
--   03_provider_points.sql        服务商钱包 / 服务商账本
--   04_traffic.sql                traffic_raw(分区) / 全局幂等表 / 小时聚合
--   05_billing.sql                usage_ledger 计费明细
--   06_settlement.sql             结算条款 / 结算单 / 结算明细
--   07_triggers_optional.sql      (可选) 时间区间不重叠 + 定价只增不改 触发器
--   08_partition_maintenance.sql  (可选) 分区前滚 / 归档 / 巡检
--   09_reconciliation_queries.sql (运维) 对账与巡检 SQL
-- -----------------------------------------------------------------------------
