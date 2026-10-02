-- =============================================================================
-- 09 · 关键查询与对账 SQL（运维日常）
-- =============================================================================

USE `hysteria`;

-- =============================================================================
-- 一、关键业务查询
-- =============================================================================

-- 1.1 查用户当前 active 绑定（走 uk_user_active_binding，最多 1 行）
--     :user_id 为参数
SELECT b.id            AS binding_id,
       b.user_id,
       b.provider_id,
       b.external_user_id,
       b.effective_from,
       b.effective_to,
       p.code          AS provider_code,
       p.name          AS provider_name
FROM user_provider_bindings b
JOIN providers p ON p.id = b.provider_id
WHERE b.active_binding_key = 1                        -- ← 换成 :user_id
  AND b.effective_from <= UTC_TIMESTAMP(6)
  AND (b.effective_to IS NULL OR b.effective_to > UTC_TIMESTAMP(6));

-- 1.2 按"流量发生时间"回溯绑定（计费必须用这个，不能用当前绑定）
SELECT b.id AS binding_id, b.provider_id, b.external_user_id
FROM user_provider_bindings b
WHERE b.user_id = 1                                   -- ← :user_id
  AND b.effective_from <= '2026-10-01 12:00:00'       -- ← :occurred_at
  AND (b.effective_to IS NULL OR b.effective_to > '2026-10-01 12:00:00')
ORDER BY b.effective_from DESC
LIMIT 1;

-- 1.3 查"某服务商 + 某节点 + 某时刻"生效的定价
--     优先级：①节点价(node_id 非空) > 默认价 ②priority 大 ③effective_from 新 ④id 大兜底
--     区间：[effective_from, effective_to)
SELECT r.id                AS pricing_rule_id,
       r.provider_id,
       r.node_id,
       r.points_per_gb,
       r.upload_ratio,
       r.download_ratio,
       r.min_charge_points,
       r.priority,
       r.effective_from,
       r.effective_to
FROM provider_pricing_rules r
WHERE r.provider_id = 1                               -- ← :provider_id
  AND (r.node_id = 1 OR r.node_id IS NULL)            -- ← :node_id
  AND r.status = 'active'
  AND r.effective_from <= '2026-10-01 12:00:00'       -- ← :occurred_at
  AND (r.effective_to IS NULL OR r.effective_to > '2026-10-01 12:00:00')
ORDER BY (r.node_id IS NOT NULL) DESC,                -- TRUE=1 排前 ⇒ 节点价优先
         r.priority DESC,
         r.effective_from DESC,
         r.id DESC
LIMIT 1;

-- 1.4 按小时聚合流量（幂等 UPSERT，可重跑）
INSERT INTO traffic_usage_hourly
  (user_id, provider_id, node_id, binding_id,
   period_start, period_end, upload_bytes, download_bytes, raw_record_count)
SELECT t.user_id,
       t.provider_id,
       t.node_id,
       t.binding_id,
       t.bucket_start,                                -- 小时桶起点
       TIMESTAMPADD(HOUR, 1, t.bucket_start)          AS period_end,
       t.upload_bytes,
       t.download_bytes,
       t.cnt
FROM (
  SELECT r.user_id,
         r.provider_id,
         r.node_id,
         r.binding_id,
         TIMESTAMPADD(HOUR, TIMESTAMPDIFF(HOUR, '1970-01-01 00:00:00', r.occurred_at),
                      '1970-01-01 00:00:00')          AS bucket_start,     -- 整点对齐(UTC)
         SUM(r.upload_bytes)                          AS upload_bytes,
         SUM(r.download_bytes)                        AS download_bytes,
         COUNT(*)                                     AS cnt
  FROM traffic_raw r
  WHERE r.occurred_at >= '2026-10-01 00:00:00'        -- ← :bucket_from（必须直接比较分区列）
    AND r.occurred_at <  '2026-10-01 01:00:00'        -- ← :bucket_to
  -- 注意:别名不要叫 period_start —— traffic_raw 里已有同名列，
  --       GROUP BY 会优先绑定到真实列，触发 only_full_group_by 报错(1055)
  GROUP BY r.user_id, r.provider_id, r.node_id, r.binding_id, bucket_start
) t
ON DUPLICATE KEY UPDATE                                -- 命中 uk_tuh_bucket
  upload_bytes     = VALUES(upload_bytes),             -- MySQL 8.0.19+ 可用行别名: SET upload_bytes = t.upload_bytes
  download_bytes   = VALUES(download_bytes),
  raw_record_count = VALUES(raw_record_count);

-- 1.5 生成 usage_ledger（小时桶 → 计费明细）
--     LATERAL(8.0.14+) 按"流量发生时间"各取一条定价/条款，绝不使用"当前值"
INSERT INTO usage_ledger
  (ledger_no, user_id, provider_id, node_id, binding_id, pricing_rule_id,
   period_start, period_end, upload_bytes, download_bytes,
   billable_bytes, billable_gb, points_per_gb, upload_ratio, download_ratio,
   raw_points_amount, user_points_amount,
   platform_commission_rate, platform_points_amount, provider_points_amount,
   status, idempotency_key, billed_at)
SELECT CONCAT('UL', DATE_FORMAT(h.period_start, '%Y%m%d%H'), '-', h.binding_id, '-', h.node_id),
       h.user_id, h.provider_id, h.node_id, h.binding_id,
       r.id,
       h.period_start, h.period_end,
       h.upload_bytes, h.download_bytes,
       /* 计费字节 = 上行*上行系数 + 下行*下行系数，四舍五入到整数字节 */
       CAST(ROUND(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio) AS UNSIGNED),
       /* 计费 GB：1GB = 1024^3 = 1073741824 bytes */
       ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
             / 1073741824, 8),
       r.points_per_gb, r.upload_ratio, r.download_ratio,
       ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
             / 1073741824 * r.points_per_gb, 8),
       GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                      / 1073741824 * r.points_per_gb, 8), r.min_charge_points),
       t.commission_rate,
       ROUND(GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                            / 1073741824 * r.points_per_gb, 8), r.min_charge_points) * t.commission_rate, 8),
       GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                      / 1073741824 * r.points_per_gb, 8), r.min_charge_points)
       - ROUND(GREATEST(ROUND(CAST(h.upload_bytes * r.upload_ratio + h.download_bytes * r.download_ratio AS DECIMAL(40,8))
                              / 1073741824 * r.points_per_gb, 8), r.min_charge_points) * t.commission_rate, 8),
       'pending',
       SHA2(CONCAT_WS('|', h.binding_id, h.node_id, h.period_start, h.period_end), 256),
       UTC_TIMESTAMP(6)
FROM traffic_usage_hourly h
JOIN LATERAL (
  SELECT rr.id, rr.points_per_gb, rr.upload_ratio, rr.download_ratio, rr.min_charge_points
  FROM provider_pricing_rules rr
  WHERE rr.provider_id = h.provider_id
    AND (rr.node_id = h.node_id OR rr.node_id IS NULL)
    AND rr.status = 'active'
    AND rr.effective_from <= h.period_start
    AND (rr.effective_to IS NULL OR rr.effective_to > h.period_start)
  ORDER BY (rr.node_id IS NOT NULL) DESC, rr.priority DESC, rr.effective_from DESC, rr.id DESC
  LIMIT 1
) r ON TRUE
JOIN LATERAL (
  SELECT tt.commission_rate
  FROM provider_settlement_terms tt
  WHERE tt.provider_id = h.provider_id
    AND tt.status = 'active'
    AND tt.effective_from <= h.period_start
    AND (tt.effective_to IS NULL OR tt.effective_to > h.period_start)
  ORDER BY tt.priority DESC, tt.effective_from DESC, tt.id DESC
  LIMIT 1
) t ON TRUE
WHERE h.billed_status = 'pending'
  AND h.period_end <= UTC_TIMESTAMP(6) - INTERVAL 5 MINUTE   -- 桶已封口
  AND h.period_start >= '2026-10-01 00:00:00'
  AND h.period_start <  '2026-10-02 00:00:00';

-- =============================================================================
-- 二、对账（因为 traffic_raw 是分区表不能建外键，这些必须常态化跑）
-- =============================================================================

-- 2.1 孤儿流量：绑定/节点不存在，或跨服务商、跨用户、时间落在绑定区间之外
SELECT r.id, r.provider_id, r.node_id, r.user_id, r.binding_id, r.occurred_at
FROM traffic_raw r
LEFT JOIN user_provider_bindings b ON b.id = r.binding_id
LEFT JOIN provider_nodes         n ON n.id = r.node_id
WHERE b.id IS NULL
   OR n.id IS NULL
   OR b.provider_id <> r.provider_id
   OR n.provider_id <> r.provider_id
   OR b.user_id     <> r.user_id
   OR r.occurred_at <  b.effective_from
   OR (b.effective_to IS NOT NULL AND r.occurred_at >= b.effective_to)
LIMIT 1000;

-- 2.2 钱包缓存 vs 账本权威余额（两个查询都必须返回 0 行）
SELECT w.user_id, w.balance AS wallet_balance, COALESCE(l.bal, 0) AS ledger_balance,
       w.balance - COALESCE(l.bal, 0) AS diff
FROM user_points_wallets w
LEFT JOIN (SELECT user_id, SUM(signed_amount) AS bal FROM user_points_ledger GROUP BY user_id) l
       ON l.user_id = w.user_id
WHERE w.balance <> COALESCE(l.bal, 0);

SELECT w.provider_id, w.balance AS wallet_balance, COALESCE(l.bal, 0) AS ledger_balance,
       w.balance - COALESCE(l.bal, 0) AS diff
FROM provider_points_wallets w
LEFT JOIN (SELECT provider_id, SUM(signed_amount) AS bal FROM provider_points_ledger GROUP BY provider_id) l
       ON l.provider_id = w.provider_id
WHERE w.balance <> COALESCE(l.bal, 0);

-- 2.3 usage_ledger 三方金额恒等式（必须 0 行）
SELECT id, user_points_amount, platform_points_amount, provider_points_amount
FROM usage_ledger
WHERE is_reversal = 0
  AND user_points_amount <> platform_points_amount + provider_points_amount;

-- 2.4 小时桶聚合量 vs 原始明细量（同一窗口必须完全相等）
SELECT h.id, h.binding_id, h.node_id, h.period_start,
       h.upload_bytes AS hourly_up, r.up_sum,
       h.download_bytes AS hourly_down, r.down_sum
FROM traffic_usage_hourly h
JOIN (
  SELECT binding_id, node_id,
         TIMESTAMPADD(HOUR, TIMESTAMPDIFF(HOUR, '1970-01-01 00:00:00', occurred_at), '1970-01-01 00:00:00') AS bucket_start,
         SUM(upload_bytes) AS up_sum, SUM(download_bytes) AS down_sum
  FROM traffic_raw
  WHERE occurred_at >= '2026-10-01 00:00:00' AND occurred_at < '2026-10-02 00:00:00'
  GROUP BY binding_id, node_id, bucket_start
) r
  ON  r.binding_id   = h.binding_id
  AND r.node_id      = h.node_id
  AND r.bucket_start = h.period_start
WHERE h.upload_bytes <> r.up_sum OR h.download_bytes <> r.down_sum
LIMIT 100;

-- 2.5 积压与异常监控（三个关键指标）
SELECT '未封口/待计费桶' AS metric, COUNT(*) AS cnt,
       MIN(period_start) AS oldest, MAX(period_end) AS newest
FROM traffic_usage_hourly WHERE billed_status = 'pending'
UNION ALL
SELECT '计费失败明细', COUNT(*), MIN(period_start), MAX(period_end)
FROM usage_ledger WHERE status = 'failed'
UNION ALL
SELECT '结算单待处理', COUNT(*), MIN(period_start), MAX(period_end)
FROM provider_settlements WHERE status IN ('draft','pending','approved')
UNION ALL
SELECT '绑定异常(0条active)', COUNT(*), NULL, NULL
FROM (
  SELECT user_id FROM user_provider_bindings GROUP BY user_id HAVING SUM(status='active') <> 1
) x;

-- 2.6 幂等重复命中率（上报重放水位，正常应长期接近 0）
SELECT DATE(created_at) AS d,
       SUM(source = 'node_push') AS raw_rows,
       (SELECT COUNT(*) FROM traffic_ingest_idempotency WHERE DATE(created_at) = d) AS idem_rows
FROM traffic_raw
WHERE created_at >= UTC_TIMESTAMP(6) - INTERVAL 7 DAY
GROUP BY DATE(created_at)
ORDER BY d DESC;

-- 2.7 一条 usage 是否被结算两次（结构上已由 uk_psi_usage 阻止，这里做兜底确认）
SELECT usage_ledger_id, COUNT(*) AS c
FROM provider_settlement_items
GROUP BY usage_ledger_id
HAVING c > 1;
