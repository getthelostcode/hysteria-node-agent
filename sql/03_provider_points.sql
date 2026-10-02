-- =============================================================================
-- 03 · 服务商 points（钱包 + 账本）
-- 放在 usage_ledger 之前：usage_ledger 需要外键引用 provider_points_ledger
-- =============================================================================

-- -----------------------------------------------------------------------------
-- provider_points_wallets · 服务商 points 钱包（缓存层）
-- balance = 累计应得 - 已结算（含冻结）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_points_wallets (
  provider_id    BIGINT UNSIGNED NOT NULL,
  balance        DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '可用(累计赚取-已结算,缓存)',
  total_earned   DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '累计赚取',
  total_settled  DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '累计已结算',
  frozen         DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '结算冻结中',
  last_ledger_id BIGINT UNSIGNED NULL,
  version        BIGINT UNSIGNED NOT NULL DEFAULT 0,
  updated_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (provider_id),
  CONSTRAINT fk_ppw_provider FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE CASCADE,
  CONSTRAINT ck_ppw_balance  CHECK (balance >= 0),
  CONSTRAINT ck_ppw_frozen   CHECK (frozen  >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='服务商 points 钱包(缓存层)';

-- -----------------------------------------------------------------------------
-- provider_points_ledger · 服务商 points 账本（不可变，红冲修正）
--   usage_earning : 每笔计费给服务商记应得（credit）
--   settlement    : 结算时把应得转出（debit）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_points_ledger (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  provider_id     BIGINT UNSIGNED NOT NULL,
  biz_type        ENUM('usage_earning','settlement','adjust','reversal') NOT NULL COMMENT '赚取/结算转出/调整/红冲',
  direction       ENUM('credit','debit') NOT NULL,
  amount          DECIMAL(30,8)   NOT NULL COMMENT '恒为正',
  signed_amount   DECIMAL(30,8)   GENERATED ALWAYS AS
                    (CASE WHEN direction = 'credit' THEN amount ELSE -amount END) STORED,
  balance_after   DECIMAL(30,8)   NOT NULL COMMENT '该分录后余额快照',
  biz_ref_type    VARCHAR(32)     NULL COMMENT 'usage_ledger/provider_settlements',
  biz_ref_id      BIGINT UNSIGNED NULL,
  idempotency_key VARCHAR(128)    NULL,
  reversal_of_id  BIGINT UNSIGNED NULL,
  remark          VARCHAR(255)    NULL,
  metadata        JSON            NULL,
  created_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_ppl_idem (idempotency_key),
  UNIQUE KEY uk_ppl_biz  (biz_type, biz_ref_type, biz_ref_id, provider_id, direction),
  KEY idx_ppl_provider_time (provider_id, created_at),
  KEY idx_ppl_ref (biz_ref_type, biz_ref_id),
  CONSTRAINT fk_ppl_provider FOREIGN KEY (provider_id)     REFERENCES providers(id),
  CONSTRAINT fk_ppl_reversal FOREIGN KEY (reversal_of_id)  REFERENCES provider_points_ledger(id),
  CONSTRAINT ck_ppl_amount   CHECK (amount > 0),
  CONSTRAINT ck_ppl_balance  CHECK (balance_after >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='服务商 points 账本(不可变)';
