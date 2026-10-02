-- =============================================================================
-- 02 · 服务商与节点（含版本化定价、版本化绑定）
-- =============================================================================

-- -----------------------------------------------------------------------------
-- providers · Hysteria 服务商
-- default_commission_rate 仅作展示；**计费一律以 provider_settlement_terms 为准**
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS providers (
  id                       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code                     VARCHAR(64)     NOT NULL COMMENT '服务商编码',
  name                     VARCHAR(128)    NOT NULL,
  contact_email            VARCHAR(190)    NULL,
  contact_telegram         VARCHAR(64)     NULL,
  status                   ENUM('pending','active','suspended','terminated') NOT NULL DEFAULT 'pending',
  api_endpoint             VARCHAR(255)    NULL COMMENT '上报/管理 API 基址',
  api_secret_encrypted     VARBINARY(512)  NULL COMMENT '服务商级 API 密钥(应用层加密存储)',
  default_commission_rate  DECIMAL(9,6)    NOT NULL DEFAULT 0.200000 COMMENT '默认抽成(展示用)',
  settlement_cycle         ENUM('weekly','biweekly','monthly','manual') NOT NULL DEFAULT 'monthly',
  metadata                 JSON            NULL,
  created_at               DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at               DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_providers_code (code),
  KEY idx_providers_status (status),
  CONSTRAINT ck_providers_comm CHECK (default_commission_rate >= 0 AND default_commission_rate < 1),
  CONSTRAINT ck_providers_meta CHECK (metadata IS NULL OR JSON_VALID(metadata))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='Hysteria 服务商';

-- -----------------------------------------------------------------------------
-- provider_nodes · 服务商节点
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_nodes (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  provider_id   BIGINT UNSIGNED NOT NULL,
  node_code     VARCHAR(64)     NOT NULL COMMENT '服务商侧节点标识(上报用)',
  name          VARCHAR(128)    NULL,
  region        VARCHAR(64)     NULL COMMENT '区域',
  country_code  CHAR(2)         NULL COMMENT 'ISO-3166-1 alpha2',
  host          VARCHAR(255)    NULL,
  port          SMALLINT UNSIGNED NULL,
  protocol      VARCHAR(32)     NOT NULL DEFAULT 'hysteria2',
  capacity_mbps INT UNSIGNED    NULL COMMENT '带宽上限',
  status        ENUM('active','maintenance','offline','disabled') NOT NULL DEFAULT 'active',
  tags          JSON            NULL COMMENT '标签数组',
  config        JSON            NULL COMMENT '节点扩展配置',
  last_seen_at  DATETIME(6)     NULL COMMENT '最后心跳(UTC)',
  created_at    DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at    DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_pn_provider_code (provider_id, node_code),
  KEY idx_pn_status (status, provider_id),
  KEY idx_pn_lastseen (last_seen_at),
  CONSTRAINT fk_pn_provider FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE CASCADE,
  CONSTRAINT ck_pn_tags CHECK (tags   IS NULL OR JSON_VALID(tags)),
  CONSTRAINT ck_pn_cfg  CHECK (config IS NULL OR JSON_VALID(config))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='服务商节点';

-- -----------------------------------------------------------------------------
-- provider_pricing_rules · 定价规则（版本化：改价只新增，绝不改旧记录）
--   node_id NULL    = 服务商级默认价
--   node_id 非 NULL = 节点覆盖价（优先级高于默认价）
--   生效区间 [effective_from, effective_to)，effective_to 为 NULL 表示长期
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_pricing_rules (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  provider_id       BIGINT UNSIGNED NOT NULL COMMENT '服务商',
  node_id           BIGINT UNSIGNED NULL COMMENT 'NULL=服务商级默认价;非空=节点覆盖价',
  points_per_gb     DECIMAL(30,8)   NOT NULL COMMENT '多少 Hyper Points = 1GB',
  upload_ratio      DECIMAL(10,6)   NOT NULL DEFAULT 1.000000 COMMENT '上行计费系数',
  download_ratio    DECIMAL(10,6)   NOT NULL DEFAULT 1.000000 COMMENT '下行计费系数',
  min_charge_points DECIMAL(30,8)   NOT NULL DEFAULT 0.00000000 COMMENT '单次计费最低扣费',
  priority          INT             NOT NULL DEFAULT 0 COMMENT '数值越大越优先',
  status            ENUM('active','inactive') NOT NULL DEFAULT 'active',
  effective_from    DATETIME(6)     NOT NULL COMMENT '生效起点(含),UTC',
  effective_to      DATETIME(6)     NULL COMMENT '失效终点(不含),NULL=长期',
  created_by        BIGINT UNSIGNED NULL COMMENT '操作人',
  remark            VARCHAR(255)    NULL,
  metadata          JSON            NULL,
  created_at        DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at        DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  KEY idx_ppr_match_default (provider_id, status, effective_from, effective_to),
  KEY idx_ppr_match_node    (provider_id, node_id, status, effective_from, effective_to),
  KEY idx_ppr_priority      (provider_id, node_id, priority),
  CONSTRAINT fk_ppr_provider FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE CASCADE,
  CONSTRAINT fk_ppr_node     FOREIGN KEY (node_id)     REFERENCES provider_nodes(id) ON DELETE CASCADE,
  CONSTRAINT ck_ppr_ppg   CHECK (points_per_gb >= 0),
  CONSTRAINT ck_ppr_up    CHECK (upload_ratio >= 0),
  CONSTRAINT ck_ppr_down  CHECK (download_ratio >= 0),
  CONSTRAINT ck_ppr_min   CHECK (min_charge_points >= 0),
  CONSTRAINT ck_ppr_win   CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT ck_ppr_meta  CHECK (metadata IS NULL OR JSON_VALID(metadata))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='服务商定价规则(版本化,改价只增不改)';

-- -----------------------------------------------------------------------------
-- user_provider_bindings · 用户-服务商绑定（版本化 + 唯一 active）
--
-- MySQL 没有 PostgreSQL 的 EXCLUDE 排他约束，用「STORED 生成列 + 唯一索引」
-- 实现"部分唯一索引"效果：仅 status='active' 时生成列取 user_id，其余为 NULL，
-- 而唯一索引允许多个 NULL ⇒ 同一用户最多只能有 1 条 active 绑定。
--
-- 注意：active_binding_key 是生成列，INSERT/UPDATE 时**必须省略该列**，
--       显式写入会报 ERROR 3105。
-- 注意：关闭旧绑定(M->status='closed')后生成列变 NULL，唯一索引才不再拦截，
--       所以"先关旧、再插新"的顺序不能颠倒。
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_provider_bindings (
  id                     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id                BIGINT UNSIGNED NOT NULL,
  provider_id            BIGINT UNSIGNED NOT NULL,
  external_user_id       VARCHAR(128)    NOT NULL COMMENT '服务商侧用户标识',
  auth_secret_encrypted  VARBINARY(512)  NOT NULL COMMENT '服务商侧鉴权密钥(应用层加密)',
  status                 ENUM('pending','active','suspended','closed') NOT NULL DEFAULT 'pending',
  active_binding_key     BIGINT UNSIGNED GENERATED ALWAYS AS
                           (CASE WHEN status = 'active' THEN user_id ELSE NULL END) STORED
                           COMMENT '唯一约束载体(生成列,禁止显式写入)',
  effective_from         DATETIME(6)     NOT NULL COMMENT '绑定生效起点(含),UTC',
  effective_to           DATETIME(6)     NULL COMMENT '绑定结束终点(不含),NULL=至今',
  switch_from_binding_id BIGINT UNSIGNED NULL COMMENT '从哪条绑定切换而来',
  metadata               JSON            NULL,
  created_at             DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at             DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_user_active_binding (active_binding_key) COMMENT '一用户同时仅一条 active 绑定',
  KEY idx_upb_user_time         (user_id, effective_from, effective_to),
  KEY idx_upb_provider_status   (provider_id, status, effective_from),
  KEY idx_upb_provider_external (provider_id, external_user_id),
  CONSTRAINT fk_upb_user     FOREIGN KEY (user_id)     REFERENCES users(id),
  CONSTRAINT fk_upb_provider FOREIGN KEY (provider_id) REFERENCES providers(id),
  CONSTRAINT fk_upb_prev     FOREIGN KEY (switch_from_binding_id) REFERENCES user_provider_bindings(id),
  CONSTRAINT ck_upb_win  CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT ck_upb_open CHECK (status <> 'active' OR effective_to IS NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='用户-服务商绑定(版本化,唯一 active)';

-- -----------------------------------------------------------------------------
-- provider_switch_logs · 服务商切换审计
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS provider_switch_logs (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id          BIGINT UNSIGNED NOT NULL,
  from_binding_id  BIGINT UNSIGNED NULL COMMENT '旧绑定(首次绑定时为空)',
  to_binding_id    BIGINT UNSIGNED NOT NULL COMMENT '新绑定',
  from_provider_id BIGINT UNSIGNED NULL,
  to_provider_id   BIGINT UNSIGNED NOT NULL,
  effective_at     DATETIME(6)     NOT NULL COMMENT '切换生效时刻(UTC)',
  status           ENUM('success','failed','rolled_back') NOT NULL DEFAULT 'success',
  operator_type    ENUM('user','admin','system') NOT NULL DEFAULT 'user',
  operator_id      BIGINT UNSIGNED NULL,
  reason           VARCHAR(255)    NULL,
  detail           JSON            NULL COMMENT '请求/响应详情',
  created_at       DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  KEY idx_psl_user (user_id, effective_at),
  KEY idx_psl_provider (to_provider_id, effective_at),
  CONSTRAINT fk_psl_user      FOREIGN KEY (user_id)          REFERENCES users(id),
  CONSTRAINT fk_psl_from_bind FOREIGN KEY (from_binding_id)  REFERENCES user_provider_bindings(id),
  CONSTRAINT fk_psl_to_bind   FOREIGN KEY (to_binding_id)    REFERENCES user_provider_bindings(id),
  CONSTRAINT fk_psl_from_prov FOREIGN KEY (from_provider_id) REFERENCES providers(id),
  CONSTRAINT fk_psl_to_prov   FOREIGN KEY (to_provider_id)   REFERENCES providers(id),
  CONSTRAINT ck_psl_detail CHECK (detail IS NULL OR JSON_VALID(detail))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='服务商切换审计';
