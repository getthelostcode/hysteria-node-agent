-- =============================================================================
-- 06 · 服务商结算（条款版本化 · 结算单 · 结算明细）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- provider_settlement_terms · 结算条款（版本化：汇率 / 抽成 / 手续费 / 税 / 冻结期）
-- 计费与结算都必须"按时间点"取条款，不能用最新条款倒算历史账。
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_settlement_terms (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  provider_id         BIGINT UNSIGNED NOT NULL,
  currency            CHAR(3)         NOT NULL DEFAULT 'CNY' COMMENT '结算法币',
  points_to_fiat_rate DECIMAL(30,8)   NOT NULL COMMENT '1 Point = X 法币',
  commission_rate     DECIMAL(9,6)    NOT NULL COMMENT '平台抽成比例 0~1',
  payout_fee_rate     DECIMAL(9,6)    NOT NULL DEFAULT 0.000000 COMMENT '打款手续费率',
  tax_rate            DECIMAL(9,6)    NOT NULL DEFAULT 0.000000 COMMENT '税率',
  min_payout_points   DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '起结门槛',
  hold_days           INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT '流量发生到可结算的冻结天数',
  settlement_cycle    ENUM('weekly','biweekly','monthly','manual') NOT NULL DEFAULT 'monthly',
  priority            INT             NOT NULL DEFAULT 0 COMMENT '同刻多条款时取大',
  status              ENUM('active','inactive') NOT NULL DEFAULT 'active',
  effective_from      DATETIME(6)     NOT NULL,
  effective_to        DATETIME(6)     NULL COMMENT '[from,to),NULL=长期',
  metadata            JSON            NULL,
  created_at          DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at          DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  KEY idx_pst_match (provider_id, status, effective_from, effective_to),
  CONSTRAINT fk_pst_provider FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE CASCADE,
  CONSTRAINT ck_pst_rate CHECK (commission_rate >= 0 AND commission_rate < 1),
  CONSTRAINT ck_pst_fee  CHECK (payout_fee_rate >= 0 AND payout_fee_rate < 1 AND tax_rate >= 0 AND tax_rate < 1),
  CONSTRAINT ck_pst_fx   CHECK (points_to_fiat_rate > 0),
  CONSTRAINT ck_pst_win  CHECK (effective_to IS NULL OR effective_to > effective_from)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='服务商结算条款(版本化)';

-- -----------------------------------------------------------------------------
-- provider_settlements · 结算单
-- uk_ps_provider_period ⇒ 同一服务商同一区间只可能有一张结算单
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_settlements (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  settlement_no     VARCHAR(40)     NOT NULL COMMENT '结算单号',
  provider_id       BIGINT UNSIGNED NOT NULL,
  term_id           BIGINT UNSIGNED NULL COMMENT '采用的条款版本',
  period_start      DATETIME(6)     NOT NULL COMMENT '结算区间起点(UTC,含)',
  period_end        DATETIME(6)     NOT NULL COMMENT '结算区间终点(UTC,不含)',
  points_amount     DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '纳入结算的 points 毛额',
  commission_points DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '平台抽成(展示)',
  payout_fee_points DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '打款手续费',
  tax_points        DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '税费',
  net_points        DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '净 points',
  exchange_rate     DECIMAL(30,8)   NOT NULL COMMENT 'points→法币汇率快照',
  fiat_amount       DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '应付法币',
  currency          CHAR(3)         NOT NULL,
  item_count        INT UNSIGNED    NOT NULL DEFAULT 0 COMMENT '明细条数(对账)',
  status            ENUM('draft','pending','approved','paid','failed','cancelled') NOT NULL DEFAULT 'draft',
  payout_method     VARCHAR(32)     NULL,
  payout_ref        VARCHAR(128)    NULL COMMENT '打款流水号',
  metadata          JSON            NULL,
  requested_at      DATETIME(6)     NULL,
  approved_at       DATETIME(6)     NULL,
  paid_at           DATETIME(6)     NULL,
  created_at        DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at        DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_ps_no              (settlement_no),
  UNIQUE KEY uk_ps_provider_period (provider_id, period_start, period_end),
  KEY idx_ps_status (status, period_end),
  CONSTRAINT fk_ps_provider FOREIGN KEY (provider_id) REFERENCES providers(id),
  CONSTRAINT fk_ps_term     FOREIGN KEY (term_id)     REFERENCES provider_settlement_terms(id),
  CONSTRAINT ck_ps_win    CHECK (period_end > period_start),
  CONSTRAINT ck_ps_amount CHECK (points_amount >= 0 AND net_points >= 0 AND fiat_amount >= 0),
  CONSTRAINT ck_ps_fx     CHECK (exchange_rate > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='服务商结算单';

-- -----------------------------------------------------------------------------
-- provider_settlement_items · 结算明细（usage 级）
-- uk_psi_usage ⇒ 一条 usage_ledger 只能被结算一次（防双结的关键）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_settlement_items (
  id                     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  settlement_id          BIGINT UNSIGNED NOT NULL,
  usage_ledger_id        BIGINT UNSIGNED NOT NULL,
  provider_id            BIGINT UNSIGNED NOT NULL,
  user_id                BIGINT UNSIGNED NOT NULL,
  node_id                BIGINT UNSIGNED NOT NULL,
  period_start           DATETIME(6)     NOT NULL,
  period_end             DATETIME(6)     NOT NULL,
  billable_gb            DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000,
  user_points_amount     DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000,
  platform_points_amount DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000,
  provider_points_amount DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000,
  created_at             DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_psi_usage      (usage_ledger_id) COMMENT '一条计费明细只能被结算一次',
  KEY idx_psi_settlement (settlement_id, period_start),
  KEY idx_psi_provider   (provider_id, period_end),
  CONSTRAINT fk_psi_settlement FOREIGN KEY (settlement_id)   REFERENCES provider_settlements(id) ON DELETE CASCADE,
  CONSTRAINT fk_psi_usage      FOREIGN KEY (usage_ledger_id) REFERENCES usage_ledger(id),
  CONSTRAINT fk_psi_provider   FOREIGN KEY (provider_id)     REFERENCES providers(id),
  CONSTRAINT fk_psi_user       FOREIGN KEY (user_id)         REFERENCES users(id),
  CONSTRAINT fk_psi_node       FOREIGN KEY (node_id)         REFERENCES provider_nodes(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='结算明细(usage 级)';
