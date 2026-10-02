-- =============================================================================
-- 10 · 冒烟测试（在真实 MySQL 8 上验证核心规则是否真的被"库"保证）
--
-- 运行方式：
--   mysql -h127.0.0.1 -P3306 -uroot hysteria --force --table < 10_smoke_test.sql
--
-- 注意：本文件里**故意包含会失败的语句**（用于验证约束/触发器/唯一索引生效），
--       必须加 --force 让客户端继续执行；出现下列 ERROR 才是正确结果：
--         ERROR 1062 / uk_user_active_binding   —— 一人一 active 绑定被拦住
--         ERROR 1062 / uk_tr_idem               —— 上报幂等被拦住
--         ERROR 1644 (45000)                    —— 区间重叠 / 定价不可改写 触发器生效
--         ERROR 3819                            —— CHECK 约束生效
-- 每条断言前的注释写明"期望"。
-- =============================================================================

USE hysteria;
SET SESSION time_zone = '+00:00';

SELECT '=== T1 基础数据 ===' AS t;
INSERT INTO users(uuid, username, password_hash) VALUES
 ('11111111-1111-1111-1111-111111111111','alice','x'),
 ('22222222-2222-2222-2222-222222222222','bob','x');
INSERT INTO user_points_wallets(user_id, balance) VALUES (1, 100), (2, 100);
INSERT INTO providers(code, name, status) VALUES ('p1','Provider1','active'), ('p2','Provider2','active');
INSERT INTO provider_nodes(provider_id, node_code, name) VALUES (1,'n1','Node1'), (1,'n2','Node2');
INSERT INTO provider_settlement_terms(provider_id, currency, points_to_fiat_rate, commission_rate,
       effective_from, status) VALUES (1,'CNY', 0.10000000, 0.200000, '2026-01-01 00:00:00','active');

SELECT '=== T2 定价：服务商默认价 10 + 节点 n1 覆盖价 5 ===' AS t;
INSERT INTO provider_pricing_rules(provider_id, node_id, points_per_gb, effective_from, priority)
 VALUES (1, NULL, 10.00000000, '2026-01-01 00:00:00', 0),
        (1, 1,     5.00000000, '2026-01-01 00:00:00', 0);

SELECT '=== T3 建立 active 绑定 (user1 -> provider1) ===' AS t;
INSERT INTO user_provider_bindings(user_id, provider_id, external_user_id, auth_secret_encrypted,
       status, effective_from) VALUES (1, 1, 'ext-1', X'00', 'active', '2026-10-01 00:00:00');

SELECT '=== T4 期望失败: 同一用户第二条 active 绑定 ===' AS t;
SELECT '--- 期望 ERROR 1644(45000) 区间重叠 或 1062 uk_user_active_binding ---' AS hint;
INSERT INTO user_provider_bindings(user_id, provider_id, external_user_id, auth_secret_encrypted,
       status, effective_from) VALUES (1, 2, 'ext-1b', X'00', 'active', '2026-10-01 00:00:00');

SELECT '=== T5 切换服务商：事务内「先关旧 → 再插新」 ===' AS t;
UPDATE user_provider_bindings SET status='closed', effective_to='2026-10-05 00:00:00'
 WHERE user_id=1 AND status='active' AND effective_to IS NULL;
INSERT INTO user_provider_bindings(user_id, provider_id, external_user_id, auth_secret_encrypted,
       status, effective_from, switch_from_binding_id)
 VALUES (1, 2, 'ext-1c', X'00', 'active', '2026-10-05 00:00:00', 1);
INSERT INTO provider_switch_logs(user_id, from_binding_id, to_binding_id, from_provider_id,
       to_provider_id, effective_at) VALUES (1, 1, 2, 1, 2, '2026-10-05 00:00:00');

SELECT '=== T6 当前 active 绑定（期望 provider_id=2, 只有 1 行） ===' AS t;
SELECT b.id AS binding_id, b.provider_id, p.code
FROM user_provider_bindings b JOIN providers p ON p.id=b.provider_id
WHERE b.active_binding_key = 1
  AND b.effective_from <= UTC_TIMESTAMP(6)
  AND (b.effective_to IS NULL OR b.effective_to > UTC_TIMESTAMP(6));

SELECT '=== T7 定价回溯 node1 @2026-10-06（期望取节点价 5.00000000） ===' AS t;
SELECT r.id, r.node_id, r.points_per_gb
FROM provider_pricing_rules r
WHERE r.provider_id=1 AND (r.node_id=1 OR r.node_id IS NULL) AND r.status='active'
  AND r.effective_from <= '2026-10-06 00:00:00'
  AND (r.effective_to IS NULL OR r.effective_to > '2026-10-06 00:00:00')
ORDER BY (r.node_id IS NOT NULL) DESC, r.priority DESC, r.effective_from DESC, r.id DESC LIMIT 1;

SELECT '=== T8 定价回溯 node2 @2026-10-06（期望回落到默认价 10.00000000） ===' AS t;
SELECT r.id, r.node_id, r.points_per_gb
FROM provider_pricing_rules r
WHERE r.provider_id=1 AND (r.node_id=2 OR r.node_id IS NULL) AND r.status='active'
  AND r.effective_from <= '2026-10-06 00:00:00'
  AND (r.effective_to IS NULL OR r.effective_to > '2026-10-06 00:00:00')
ORDER BY (r.node_id IS NOT NULL) DESC, r.priority DESC, r.effective_from DESC, r.id DESC LIMIT 1;

SELECT '=== T9 期望失败: 历史绑定区间重叠 ===' AS t;
SELECT '--- 期望 ERROR 1644(45000) 绑定时间区间与已有记录重叠 ---' AS hint;
INSERT INTO user_provider_bindings(user_id, provider_id, external_user_id, auth_secret_encrypted,
       status, effective_from, effective_to)
 VALUES (1, 1, 'ext-1d', X'00', 'pending', '2026-10-02 00:00:00', '2026-10-03 00:00:00');

SELECT '=== T9b 期望成功: 不重叠的历史区间可以插入（触发器不能误杀） ===' AS t;
INSERT INTO user_provider_bindings(user_id, provider_id, external_user_id, auth_secret_encrypted,
       status, effective_from, effective_to)
 VALUES (2, 1, 'ext-2a', X'00', 'closed', '2026-09-01 00:00:00', '2026-09-15 00:00:00');
SELECT COUNT(*) AS user2_bindings FROM user_provider_bindings WHERE user_id=2;

SELECT '=== T10 期望失败: 改写历史定价 points_per_gb ===' AS t;
SELECT '--- 期望 ERROR 1644(45000) 定价记录不可修改 ---' AS hint;
UPDATE provider_pricing_rules SET points_per_gb = 99 WHERE id = 2;

SELECT '=== T10b 期望成功: 只写 effective_to 关闭旧价（合法操作） ===' AS t;
UPDATE provider_pricing_rules SET effective_to = '2026-12-01 00:00:00' WHERE id = 2;
SELECT id, node_id, points_per_gb, effective_from, effective_to FROM provider_pricing_rules WHERE id=2;

SELECT '=== T11 流量上报 + 幂等重复（第 2 条期望 ERROR 1062 uk_tr_idem） ===' AS t;
INSERT INTO traffic_ingest_idempotency(idempotency_key, provider_id, node_id, occurred_at)
 VALUES ('k-1', 1, 1, '2026-10-01 12:30:00');
INSERT INTO traffic_raw(provider_id, node_id, user_id, binding_id, session_id, occurred_at,
       period_start, period_end, upload_bytes, download_bytes, idempotency_key)
 VALUES (1, 1, 1, 1, 'sess-1', '2026-10-01 12:30:00', '2026-10-01 12:00:00', '2026-10-01 13:00:00',
         1073741824, 0, 'k-1');
SELECT '--- 期望 ERROR 1062 Duplicate entry ... uk_tr_idem ---' AS hint;
INSERT INTO traffic_raw(provider_id, node_id, user_id, binding_id, session_id, occurred_at,
       period_start, period_end, upload_bytes, download_bytes, idempotency_key)
 VALUES (1, 1, 1, 1, 'sess-1', '2026-10-01 12:30:00', '2026-10-01 12:00:00', '2026-10-01 13:00:00',
         1073741824, 0, 'k-1');

SELECT '=== T12 小时聚合 UPSERT（可重跑；别名用 bucket_start，不能用 period_start） ===' AS t;
INSERT INTO traffic_usage_hourly
  (user_id, provider_id, node_id, binding_id, period_start, period_end,
   upload_bytes, download_bytes, raw_record_count)
SELECT t.user_id, t.provider_id, t.node_id, t.binding_id, t.bucket_start,
       TIMESTAMPADD(HOUR, 1, t.bucket_start), t.upload_bytes, t.download_bytes, t.cnt
FROM (
  SELECT r.user_id, r.provider_id, r.node_id, r.binding_id,
         TIMESTAMPADD(HOUR, TIMESTAMPDIFF(HOUR, '1970-01-01 00:00:00', r.occurred_at),
                      '1970-01-01 00:00:00') AS bucket_start,
         SUM(r.upload_bytes) AS upload_bytes, SUM(r.download_bytes) AS download_bytes, COUNT(*) AS cnt
  FROM traffic_raw r
  WHERE r.occurred_at >= '2026-10-01 00:00:00' AND r.occurred_at < '2026-10-02 00:00:00'
  GROUP BY r.user_id, r.provider_id, r.node_id, r.binding_id, bucket_start
) t
ON DUPLICATE KEY UPDATE
  upload_bytes = VALUES(upload_bytes), download_bytes = VALUES(download_bytes),
  raw_record_count = VALUES(raw_record_count);
-- 再跑一次验证幂等（应更新，不新增）
INSERT INTO traffic_usage_hourly
  (user_id, provider_id, node_id, binding_id, period_start, period_end,
   upload_bytes, download_bytes, raw_record_count)
SELECT t.user_id, t.provider_id, t.node_id, t.binding_id, t.bucket_start,
       TIMESTAMPADD(HOUR, 1, t.bucket_start), t.upload_bytes, t.download_bytes, t.cnt
FROM (
  SELECT r.user_id, r.provider_id, r.node_id, r.binding_id,
         TIMESTAMPADD(HOUR, TIMESTAMPDIFF(HOUR, '1970-01-01 00:00:00', r.occurred_at),
                      '1970-01-01 00:00:00') AS bucket_start,
         SUM(r.upload_bytes) AS upload_bytes, SUM(r.download_bytes) AS download_bytes, COUNT(*) AS cnt
  FROM traffic_raw r
  WHERE r.occurred_at >= '2026-10-01 00:00:00' AND r.occurred_at < '2026-10-02 00:00:00'
  GROUP BY r.user_id, r.provider_id, r.node_id, r.binding_id, bucket_start
) t
ON DUPLICATE KEY UPDATE
  upload_bytes = VALUES(upload_bytes), download_bytes = VALUES(download_bytes),
  raw_record_count = VALUES(raw_record_count);
SELECT id, binding_id, period_start, upload_bytes, download_bytes, raw_record_count, billed_status
FROM traffic_usage_hourly;

SELECT '=== T13 生成 usage_ledger（期望 1 行：1GB×5=5，平台 1，服务商 4） ===' AS t;
INSERT INTO usage_ledger
  (ledger_no, user_id, provider_id, node_id, binding_id, pricing_rule_id,
   period_start, period_end, upload_bytes, download_bytes,
   billable_bytes, billable_gb, points_per_gb, upload_ratio, download_ratio,
   raw_points_amount, user_points_amount,
   platform_commission_rate, platform_points_amount, provider_points_amount,
   status, idempotency_key, billed_at)
SELECT CONCAT('UL', DATE_FORMAT(h.period_start, '%Y%m%d%H'), '-', h.binding_id, '-', h.node_id),
       h.user_id, h.provider_id, h.node_id, h.binding_id, r.id,
       h.period_start, h.period_end, h.upload_bytes, h.download_bytes,
       CAST(ROUND(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio) AS UNSIGNED),
       ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
             / 1073741824, 8),
       r.points_per_gb, r.upload_ratio, r.download_ratio,
       ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
             / 1073741824 * r.points_per_gb, 8),
       GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                      / 1073741824 * r.points_per_gb, 8), r.min_charge_points),
       tt.commission_rate,
       ROUND(GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                            / 1073741824 * r.points_per_gb, 8), r.min_charge_points) * tt.commission_rate, 8),
       GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                      / 1073741824 * r.points_per_gb, 8), r.min_charge_points)
       - ROUND(GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                              / 1073741824 * r.points_per_gb, 8), r.min_charge_points) * tt.commission_rate, 8),
       'charged',
       SHA2(CONCAT_WS('|', h.binding_id, h.node_id, h.period_start, h.period_end), 256),
       UTC_TIMESTAMP(6)
FROM traffic_usage_hourly h
JOIN LATERAL (
  SELECT rr.id, rr.points_per_gb, rr.upload_ratio, rr.download_ratio, rr.min_charge_points
  FROM provider_pricing_rules rr
  WHERE rr.provider_id = h.provider_id AND (rr.node_id = h.node_id OR rr.node_id IS NULL)
    AND rr.status='active' AND rr.effective_from <= h.period_start
    AND (rr.effective_to IS NULL OR rr.effective_to > h.period_start)
  ORDER BY (rr.node_id IS NOT NULL) DESC, rr.priority DESC, rr.effective_from DESC, rr.id DESC LIMIT 1
) r ON TRUE
JOIN LATERAL (
  SELECT t2.commission_rate FROM provider_settlement_terms t2
  WHERE t2.provider_id = h.provider_id AND t2.status='active'
    AND t2.effective_from <= h.period_start
    AND (t2.effective_to IS NULL OR t2.effective_to > h.period_start)
  ORDER BY t2.priority DESC, t2.effective_from DESC, t2.id DESC LIMIT 1
) tt ON TRUE
WHERE h.billed_status='pending'
  AND h.period_end <= UTC_TIMESTAMP(6) - INTERVAL 5 MINUTE
  AND h.period_start >= '2026-10-01 00:00:00' AND h.period_start < '2026-10-02 00:00:00';

SELECT id, ledger_no, billable_bytes, billable_gb, points_per_gb, user_points_amount,
       platform_points_amount, provider_points_amount, status FROM usage_ledger;

SELECT '=== T14 三方金额恒等式（期望 0 行） ===' AS t;
SELECT id FROM usage_ledger WHERE is_reversal=0
  AND user_points_amount <> platform_points_amount + provider_points_amount;

SELECT '=== T15 期望失败: points_orders 的 points_amount ≠ base+bonus ===' AS t;
SELECT '--- 期望 ERROR 3819 ck_po_sum ---' AS hint;
INSERT INTO points_orders(order_no, user_id, base_points, bonus_points, points_amount,
       fiat_amount, fiat_currency, payment_method, status)
 VALUES ('PO-T15', 1, 10, 5, 99, 10, 'USD', 'alipay', 'pending');

SELECT '=== T16 期望失败: 钱包余额为负 ===' AS t;
SELECT '--- 期望 ERROR 3819 ck_upw_balance ---' AS hint;
UPDATE user_points_wallets SET balance = -1 WHERE user_id = 1;

SELECT '=== T17 期望失败: usage_ledger 三方金额不守恒 ===' AS t;
SELECT '--- 期望 ERROR 3819 ck_ul_split ---' AS hint;
INSERT INTO usage_ledger(ledger_no, user_id, provider_id, node_id, binding_id, pricing_rule_id,
       period_start, period_end, billable_gb, points_per_gb,
       user_points_amount, platform_points_amount, provider_points_amount, status, idempotency_key)
 VALUES ('PO-T17', 1, 1, 1, 1, 2, '2026-10-01 14:00:00','2026-10-01 15:00:00', 1, 5, 5, 1, 9, 'pending', 'k-t17');

SELECT '=== T18 服务商账本：赚取(credit) → 结算转出(debit) → 余额归零 ===' AS t;
INSERT INTO provider_points_wallets(provider_id) VALUES (1);
INSERT INTO provider_points_ledger(provider_id, biz_type, direction, amount, balance_after,
       biz_ref_type, biz_ref_id, idempotency_key)
 VALUES (1,'usage_earning','credit',4.00000000,4.00000000,'usage_ledger',1,'earn:1');
INSERT INTO provider_points_ledger(provider_id, biz_type, direction, amount, balance_after,
       biz_ref_type, biz_ref_id, idempotency_key)
 VALUES (1,'settlement','debit',4.00000000,0.00000000,'provider_settlements',1,'settle:1');
UPDATE provider_points_wallets w
   SET w.balance = (SELECT SUM(signed_amount) FROM provider_points_ledger WHERE provider_id=1)
 WHERE w.provider_id = 1;
SELECT provider_id, balance,
       (SELECT SUM(signed_amount) FROM provider_points_ledger WHERE provider_id=1) AS ledger_sum
FROM provider_points_wallets WHERE provider_id=1;

SELECT '=== T19 分区裁剪：EXPLAIN 的 partitions 列应只出现 p202610 ===' AS t;
EXPLAIN SELECT COUNT(*) FROM traffic_raw
WHERE occurred_at >= '2026-10-01 00:00:00' AND occurred_at < '2026-11-01 00:00:00';

SELECT '=== T20 期望成功: 跨月的相同 idempotency_key 能插入（这正是需要全局幂等表的原因） ===' AS t;
INSERT INTO traffic_raw(provider_id, node_id, user_id, binding_id, session_id, occurred_at,
       period_start, period_end, upload_bytes, download_bytes, idempotency_key)
 VALUES (1, 1, 1, 1, 'sess-1', '2026-11-01 12:30:00', '2026-11-01 12:00:00', '2026-11-01 13:00:00',
         999, 0, 'k-1');
SELECT '--- 期望插入成功(2 行, k-1 出现两次) ⇒ uk_tr_idem 只在分区内唯一 ---' AS hint;
SELECT occurred_at, idempotency_key FROM traffic_raw WHERE idempotency_key='k-1';

SELECT '=== T21 单独验证唯一索引 uk_user_active_binding（临时停用重叠触发器） ===' AS t;
DROP TRIGGER IF EXISTS trg_upb_no_overlap_ins;
SELECT '--- 期望 ERROR 1062 Duplicate entry ... uk_user_active_binding ---' AS hint;
INSERT INTO user_provider_bindings(user_id, provider_id, external_user_id, auth_secret_encrypted,
       status, effective_from) VALUES (1, 1, 'ext-1e', X'00', 'active', '2030-01-01 00:00:00');
-- 立刻恢复触发器（与 07_triggers_optional.sql 中定义一致）
DELIMITER $$
CREATE TRIGGER trg_upb_no_overlap_ins
BEFORE INSERT ON user_provider_bindings
FOR EACH ROW
BEGIN
  DECLARE v_conflict INT DEFAULT 0;
  SELECT COUNT(*) INTO v_conflict
  FROM user_provider_bindings b
  WHERE b.user_id = NEW.user_id
    AND b.effective_from < COALESCE(NEW.effective_to, '9999-12-31 23:59:59.999999')
    AND COALESCE(b.effective_to, '9999-12-31 23:59:59.999999') > NEW.effective_from;
  IF v_conflict > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '绑定时间区间与已有记录重叠';
  END IF;
END$$
DELIMITER ;

SELECT '=== T22 最终态 ===' AS t;
SELECT (SELECT COUNT(*) FROM users)                       AS users,
       (SELECT COUNT(*) FROM user_provider_bindings)      AS bindings,
       (SELECT COUNT(*) FROM traffic_raw)                 AS traffic_raw,
       (SELECT COUNT(*) FROM traffic_usage_hourly)        AS hourly,
       (SELECT COUNT(*) FROM usage_ledger)                AS usage_ledger;
