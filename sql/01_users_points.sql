-- =============================================================================
-- 01 · 用户与积分（Hyper Points）
-- 核心：用户表不存 current_provider_id；钱包只是缓存；所有 points 变动走账本
-- =============================================================================

-- -----------------------------------------------------------------------------
-- users · 用户表
-- 设计要点：刻意不设 current_provider_id 字段。
--           当前服务商 = user_provider_bindings 中 status='active' 的那一条。
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '用户ID',
  uuid            CHAR(36)        NOT NULL COMMENT '对外唯一标识(UUIDv4)',
  username        VARCHAR(64)     NOT NULL COMMENT '登录名',
  email           VARCHAR(190)    NULL     COMMENT '邮箱(唯一,可空)',
  phone           VARCHAR(32)     NULL     COMMENT '手机号(唯一,可空)',
  password_hash   VARCHAR(255)    NOT NULL COMMENT '密码哈希',
  status          ENUM('active','suspended','banned','deleted') NOT NULL DEFAULT 'active' COMMENT '账号状态',
  locale          VARCHAR(16)     NOT NULL DEFAULT 'zh-CN' COMMENT '语言/区域',
  registered_at   DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '注册时间(UTC)',
  last_login_at   DATETIME(6)     NULL     COMMENT '最后登录(UTC)',
  created_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_users_uuid     (uuid),
  UNIQUE KEY uk_users_username (username),
  UNIQUE KEY uk_users_email    (email),   -- MySQL 唯一索引允许多个 NULL，可空列照常唯一
  UNIQUE KEY uk_users_phone    (phone),
  KEY idx_users_status (status, registered_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci ROW_FORMAT=DYNAMIC COMMENT='用户表';

-- -----------------------------------------------------------------------------
-- user_points_wallets · 用户 points 钱包（缓存层，权威值来自 user_points_ledger）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_points_wallets (
  user_id          BIGINT UNSIGNED NOT NULL COMMENT '用户ID',
  balance          DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '可用余额(缓存,权威=ledger聚合)',
  frozen           DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '冻结(预扣)',
  total_recharged  DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '累计充值',
  total_consumed   DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '累计消费',
  last_ledger_id   BIGINT UNSIGNED NULL COMMENT '最后一条账本分录(对账用)',
  version          BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '乐观锁版本',
  updated_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (user_id),
  CONSTRAINT fk_upw_user      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT ck_upw_balance   CHECK (balance >= 0),
  CONSTRAINT ck_upw_frozen    CHECK (frozen  >= 0),
  CONSTRAINT ck_upw_recharged CHECK (total_recharged >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='用户 points 钱包(缓存层)';

-- -----------------------------------------------------------------------------
-- points_packages · points 售卖套餐（法币计价）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS points_packages (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code           VARCHAR(64)     NOT NULL COMMENT '套餐编码',
  name           VARCHAR(128)    NOT NULL COMMENT '套餐名',
  base_points    DECIMAL(30,8)   NOT NULL COMMENT '基础 points',
  bonus_points   DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '赠送 points',
  price_amount   DECIMAL(30,8)   NOT NULL COMMENT '法币售价',
  currency       CHAR(3)         NOT NULL DEFAULT 'USD' COMMENT 'ISO-4217',
  status         ENUM('active','inactive') NOT NULL DEFAULT 'active',
  sort_order     INT             NOT NULL DEFAULT 0,
  effective_from DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '上架时间(UTC)',
  effective_to   DATETIME(6)     NULL COMMENT '下架时间,NULL=长期;[from,to)',
  metadata       JSON            NULL COMMENT '扩展(限购/渠道等)',
  created_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at     DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_pp_code (code),
  KEY idx_pp_status (status, sort_order),
  CONSTRAINT ck_pp_price  CHECK (price_amount > 0),
  CONSTRAINT ck_pp_points CHECK (base_points >= 0 AND bonus_points >= 0),
  CONSTRAINT ck_pp_win    CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT ck_pp_meta   CHECK (metadata IS NULL OR JSON_VALID(metadata))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='points 售卖套餐';

-- -----------------------------------------------------------------------------
-- points_orders · 法币购买 points 订单
-- 关键唯一键：payment_channel + payment_ref ⇒ 同一支付流水不可能重复入账
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS points_orders (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_no         VARCHAR(40)     NOT NULL COMMENT '业务单号',
  user_id          BIGINT UNSIGNED NOT NULL,
  package_id       BIGINT UNSIGNED NULL COMMENT '套餐(可空:自定义充值)',
  base_points      DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000,
  bonus_points     DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000,
  points_amount    DECIMAL(30,8)   NOT NULL COMMENT '本单到账总量=base+bonus',
  fiat_amount      DECIMAL(30,8)   NOT NULL COMMENT '实付法币金额',
  fiat_currency    CHAR(3)         NOT NULL COMMENT '法币币种',
  payment_method   VARCHAR(32)     NOT NULL COMMENT 'alipay/usdt/card...',
  payment_channel  VARCHAR(32)     NULL COMMENT '支付通道',
  payment_ref      VARCHAR(128)    NULL COMMENT '第三方支付流水号',
  status           ENUM('pending','paid','failed','cancelled','refunding','refunded') NOT NULL DEFAULT 'pending',
  idempotency_key  VARCHAR(128)    NULL COMMENT '下单幂等键',
  ledger_id        BIGINT UNSIGNED NULL COMMENT '入账的 user_points_ledger.id',
  raw_payload      JSON            NULL COMMENT '支付回调原文',
  expire_at        DATETIME(6)     NULL COMMENT '订单过期(UTC)',
  paid_at          DATETIME(6)     NULL,
  refunded_at      DATETIME(6)     NULL,
  created_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_po_order_no (order_no),
  UNIQUE KEY uk_po_idem     (idempotency_key),
  UNIQUE KEY uk_po_pay_ref  (payment_channel, payment_ref),
  KEY idx_po_user (user_id, status, created_at),
  CONSTRAINT fk_po_user    FOREIGN KEY (user_id)    REFERENCES users(id),
  CONSTRAINT fk_po_package FOREIGN KEY (package_id) REFERENCES points_packages(id),
  CONSTRAINT ck_po_amount  CHECK (fiat_amount >= 0 AND points_amount >= 0),
  CONSTRAINT ck_po_sum     CHECK (points_amount = base_points + bonus_points)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='法币购买 points 订单';

-- -----------------------------------------------------------------------------
-- user_points_ledger · 用户 points 账本（不可变；撤销走红冲 reversal_of_id）
-- 权威余额 = SUM(signed_amount)；钱包的 balance 只是它的缓存
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_points_ledger (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id          BIGINT UNSIGNED NOT NULL,
  biz_type         ENUM('recharge','bonus','usage','refund','adjust','expire','reversal') NOT NULL COMMENT '业务类型',
  direction        ENUM('credit','debit') NOT NULL COMMENT 'credit=加,debit=减',
  amount           DECIMAL(30,8)   NOT NULL COMMENT '金额,恒为正',
  signed_amount    DECIMAL(30,8)   GENERATED ALWAYS AS
                     (CASE WHEN direction = 'credit' THEN amount ELSE -amount END) STORED
                     COMMENT '有符号金额,SUM(signed_amount)即权威余额',
  balance_after    DECIMAL(30,8)   NOT NULL COMMENT '该分录后余额快照',
  biz_ref_type     VARCHAR(32)     NULL COMMENT 'usage_ledger/points_orders/...',
  biz_ref_id       BIGINT UNSIGNED NULL COMMENT '关联业务主键',
  idempotency_key  VARCHAR(128)    NULL COMMENT '幂等键,唯一',
  reversal_of_id   BIGINT UNSIGNED NULL COMMENT '红冲:指向被冲销的原分录',
  remark           VARCHAR(255)    NULL,
  metadata         JSON            NULL,
  created_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '记账时间(UTC)',
  PRIMARY KEY (id),
  UNIQUE KEY uk_upl_idem (idempotency_key),
  UNIQUE KEY uk_upl_biz  (biz_type, biz_ref_type, biz_ref_id, user_id, direction),
  KEY idx_upl_user_time  (user_id, created_at),
  KEY idx_upl_ref        (biz_ref_type, biz_ref_id),
  KEY idx_upl_reversal   (reversal_of_id),
  CONSTRAINT fk_upl_user     FOREIGN KEY (user_id)        REFERENCES users(id),
  CONSTRAINT fk_upl_reversal FOREIGN KEY (reversal_of_id) REFERENCES user_points_ledger(id),
  CONSTRAINT ck_upl_amount  CHECK (amount > 0),
  CONSTRAINT ck_upl_balance CHECK (balance_after >= 0)
  -- 注意:不能写 CHECK (reversal_of_id <> id)，MySQL 禁止 CHECK 约束引用 AUTO_INCREMENT 列
  --       (ERROR 3818)，"红冲不能指向自己"由应用层校验。
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='用户 points 账本(不可变,红冲修正)';
