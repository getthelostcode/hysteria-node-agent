-- =============================================================================
-- 04 · 流量（原始明细 · 全局幂等 · 小时聚合）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- traffic_raw · 流量原始明细
--
-- 【MySQL 分区硬限制，务必理解】
--  1. 分区表**不能建外键**，别的表也不能外键引用分区表。
--     ⇒ provider_id / node_id / user_id / binding_id 全部由应用层保证，
--       并配合 09_reconciliation_queries.sql 的孤儿数据巡检兜底。
--  2. 分区表上**所有唯一键（含主键）必须包含分区列** occurred_at。
--     ⇒ UNIQUE(idempotency_key, occurred_at) 只在"分区内"唯一，
--       跨月重放的上报理论上可以重复插入 ⇒ 用 traffic_ingest_idempotency 兜底。
--  3. AUTO_INCREMENT 列必须是某个索引的首列 ⇒ PRIMARY KEY(id, occurred_at) 满足。
--  4. 分区裁剪要求 WHERE 直接比较分区列：occurred_at >= ? AND occurred_at < ?；
--     写成 WHERE DATE(occurred_at) = ? 会导致全分区扫描。
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS traffic_raw (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  provider_id      BIGINT UNSIGNED NOT NULL,
  node_id          BIGINT UNSIGNED NOT NULL,
  user_id          BIGINT UNSIGNED NOT NULL,
  binding_id       BIGINT UNSIGNED NOT NULL COMMENT '按 occurred_at 解析出的绑定快照',
  session_id       VARCHAR(128)    NOT NULL COMMENT 'Hysteria 会话ID',
  external_user_id VARCHAR(128)    NULL COMMENT '服务商侧用户ID(原样保留)',
  occurred_at      DATETIME(6)     NOT NULL COMMENT '流量发生时间(UTC)=分区键',
  period_start     DATETIME(6)     NOT NULL COMMENT '本条覆盖窗口起点(UTC)',
  period_end       DATETIME(6)     NOT NULL COMMENT '本条覆盖窗口终点(UTC)',
  upload_bytes     BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '上行字节',
  download_bytes   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '下行字节',
  total_bytes      BIGINT UNSIGNED GENERATED ALWAYS AS (upload_bytes + download_bytes) STORED COMMENT '总字节',
  idempotency_key  VARCHAR(128)    NOT NULL COMMENT '幂等键=SHA2(provider|node|binding|session|period_start|period_end)',
  source           ENUM('node_push','node_pull','reconcile','manual') NOT NULL DEFAULT 'node_push',
  raw_payload      JSON            NULL COMMENT '节点上报原文',
  created_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id, occurred_at),
  UNIQUE KEY uk_tr_idem    (idempotency_key, occurred_at) COMMENT '分区内唯一,全局唯一见 traffic_ingest_idempotency',
  KEY idx_tr_provider_time (provider_id, occurred_at),
  KEY idx_tr_node_time     (node_id, occurred_at),
  KEY idx_tr_user_time     (user_id, occurred_at),
  KEY idx_tr_binding_time  (binding_id, occurred_at),
  KEY idx_tr_session       (session_id),
  CONSTRAINT ck_tr_win     CHECK (period_end > period_start),
  CONSTRAINT ck_tr_payload CHECK (raw_payload IS NULL OR JSON_VALID(raw_payload))
  -- 注意：无外键（分区表限制），见文件头说明
)
ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
COMMENT='流量原始明细(按月分区,无外键)'
PARTITION BY RANGE COLUMNS(occurred_at) (
  PARTITION p202601 VALUES LESS THAN ('2026-02-01 00:00:00'),
  PARTITION p202602 VALUES LESS THAN ('2026-03-01 00:00:00'),
  PARTITION p202603 VALUES LESS THAN ('2026-04-01 00:00:00'),
  PARTITION p202604 VALUES LESS THAN ('2026-05-01 00:00:00'),
  PARTITION p202605 VALUES LESS THAN ('2026-06-01 00:00:00'),
  PARTITION p202606 VALUES LESS THAN ('2026-07-01 00:00:00'),
  PARTITION p202607 VALUES LESS THAN ('2026-08-01 00:00:00'),
  PARTITION p202608 VALUES LESS THAN ('2026-09-01 00:00:00'),
  PARTITION p202609 VALUES LESS THAN ('2026-10-01 00:00:00'),
  PARTITION p202610 VALUES LESS THAN ('2026-11-01 00:00:00'),
  PARTITION p202611 VALUES LESS THAN ('2026-12-01 00:00:00'),
  PARTITION p202612 VALUES LESS THAN ('2027-01-01 00:00:00'),
  PARTITION pmax    VALUES LESS THAN (MAXVALUE)   -- 兜底，每月用 REORGANIZE 前滚
);

-- -----------------------------------------------------------------------------
-- traffic_ingest_idempotency · 上报全局幂等闸门（非分区小表）
-- 用法：先 INSERT IGNORE 本表；受影响行数=0 ⇒ 重复上报，直接丢弃。
--       这条路径同时解决"同一条上报跨月写入导致分区内唯一键失效"的问题。
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS traffic_ingest_idempotency (
  idempotency_key VARCHAR(128)    NOT NULL,
  provider_id     BIGINT UNSIGNED NOT NULL,
  node_id         BIGINT UNSIGNED NOT NULL,
  traffic_raw_id  BIGINT UNSIGNED NULL COMMENT '成功落库后的明细ID',
  occurred_at     DATETIME(6)     NOT NULL,
  created_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (idempotency_key),
  KEY idx_tii_time (occurred_at),
  KEY idx_tii_provider (provider_id, occurred_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='流量上报全局幂等键(可定期清理90天前)';

-- -----------------------------------------------------------------------------
-- traffic_usage_hourly · 小时聚合桶
-- 唯一键 (binding_id, node_id, period_start) 是 UPSERT 落点，保证聚合幂等。
-- 本表非分区，保留外键；若写入 QPS 极高可去掉外键换性能（应用层保证）。
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS traffic_usage_hourly (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id          BIGINT UNSIGNED NOT NULL,
  provider_id      BIGINT UNSIGNED NOT NULL,
  node_id          BIGINT UNSIGNED NOT NULL,
  binding_id       BIGINT UNSIGNED NOT NULL,
  period_start     DATETIME(6)     NOT NULL COMMENT '小时桶起点(UTC整点)',
  period_end       DATETIME(6)     NOT NULL COMMENT '小时桶终点=+1h',
  upload_bytes     BIGINT UNSIGNED NOT NULL DEFAULT 0,
  download_bytes   BIGINT UNSIGNED NOT NULL DEFAULT 0,
  total_bytes      BIGINT UNSIGNED GENERATED ALWAYS AS (upload_bytes + download_bytes) STORED,
  raw_record_count INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT '聚合的原始条数(对账)',
  billed_status    ENUM('pending','billed','skipped','failed') NOT NULL DEFAULT 'pending',
  usage_ledger_id  BIGINT UNSIGNED NULL COMMENT '已生成的计费明细ID',
  billed_at        DATETIME(6)     NULL,
  created_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_tuh_bucket (binding_id, node_id, period_start),
  KEY idx_tuh_user_time     (user_id, period_start),
  KEY idx_tuh_provider_time (provider_id, period_start),
  KEY idx_tuh_pending       (billed_status, period_end),
  CONSTRAINT fk_tuh_user     FOREIGN KEY (user_id)    REFERENCES users(id),
  CONSTRAINT fk_tuh_provider FOREIGN KEY (provider_id) REFERENCES providers(id),
  CONSTRAINT fk_tuh_node     FOREIGN KEY (node_id)    REFERENCES provider_nodes(id),
  CONSTRAINT fk_tuh_binding  FOREIGN KEY (binding_id) REFERENCES user_provider_bindings(id),
  CONSTRAINT ck_tuh_win      CHECK (period_end > period_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='流量小时聚合桶';
