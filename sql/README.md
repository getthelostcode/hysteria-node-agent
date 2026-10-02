# Hysteria VPN 聚合平台 · MySQL 8 数据库设计

> 平台只卖 **Hyper Points**，不直接卖流量套餐。服务商提供 Hysteria 节点并定义
> 「多少 Hyper Points = 1GB」（`points_per_gb`）。用户用法币买 points，按实际流量扣 points，
> 平台按配置的抽成比例给服务商记应得 points，服务商再按规则结算成法币。

**技术基线**

| 项目 | 取值 |
|---|---|
| 数据库 | MySQL **8.0.16+**（CHECK 约束自 8.0.16 起才真正生效） |
| 存储引擎 | InnoDB |
| 字符集 / 排序规则 | `utf8mb4` / `utf8mb4_0900_ai_ci` |
| 时间 | 统一 **UTC**，类型 `DATETIME(6)`，全库 `time_zone='+00:00'` |
| 字节 | `BIGINT UNSIGNED` |
| Points / 金额 | `DECIMAL(30,8)`，**禁止浮点数** |
| 主键 | `BIGINT UNSIGNED AUTO_INCREMENT` |
| 扩展字段 | `JSON`（带 `CHECK (JSON_VALID(col))`） |
| 命名 | 统一 `points`，不使用 `coin` |
| 单位换算 | **1 GB ≡ 1024³ = 1073741824 bytes**（全库唯一口径） |

---

## 1. 目录与建库方式

```
sql/
├── README.md                       ← 本文件（设计说明 + 运维手册）
├── 00_create_database.sql          建库 + 会话基线（手工执行版）
├── 01_users_points.sql             users / 钱包 / 套餐 / 订单 / 用户账本
├── 02_providers_and_nodes.sql      providers / nodes / 定价 / 绑定 / 切换日志
├── 03_provider_points.sql          服务商钱包 / 服务商账本
├── 04_traffic.sql                  traffic_raw(分区) / 全局幂等表 / 小时聚合
├── 05_billing.sql                  usage_ledger 计费明细
├── 06_settlement.sql               结算条款 / 结算单 / 结算明细
├── 07_triggers_optional.sql        (可选) 区间不重叠 + 定价只增不改 触发器
├── 08_partition_maintenance.sql    分区前滚 / 归档 / 幂等键清理
├── 09_reconciliation_queries.sql   关键查询 + 对账 SQL
├── 10_smoke_test.sql               冒烟测试（验证约束/触发器/唯一索引真的生效）
└── apply.sh                        一键建库脚本
```

**一键建库**

```bash
cd sql
./apply.sh                                    # 默认 127.0.0.1:3306 root 无密码，库名 hysteria
DB_HOST=10.0.0.5 DB_USER=app DB_PASS=xxx ./apply.sh
./apply.sh --with-triggers --verify           # 启用触发器并跑对账
```

手工执行时**必须按 `00 → 01 → 02 → 03 → 04 → 05 → 06` 的顺序**（外键依赖决定的，
`03` 必须先于 `05`，因为 `usage_ledger` 外键引用 `provider_points_ledger`）。

**冒烟测试**

```bash
mysql -h127.0.0.1 -P3306 -uroot hysteria --force --table < 10_smoke_test.sql
```

该文件**故意包含会失败的语句**，必须加 `--force`；出现 `1062 / 45000 / 3819` 才是正确结果。
已在真实 **MySQL 8.0.43** 上验证通过（22 组断言）：

| 断言 | 结果 |
|---|---|
| 同一用户插入第二条 `active` 绑定 | `ERROR 1062 ... uk_user_active_binding`（停用触发器后单独复测，证明是**唯一索引**在拦） |
| 历史绑定时间区间重叠 | `ERROR 1644 (45000)` 触发器拦截；不重叠区间可正常插入 |
| 改写历史定价 `points_per_gb` | `ERROR 1644 (45000)` 触发器拦截；只写 `effective_to` 的"关闭旧价"成功 |
| 节点价 vs 默认价解析 | node1 → 5.00000000（节点价），node2 → 10.00000000（回落默认价） |
| 上报重复 `idempotency_key` | `ERROR 1062 ... uk_tr_idem` |
| 跨月相同 `idempotency_key` | **可插入**（分区内唯一），实证需要 `traffic_ingest_idempotency` 全局闸门 |
| 小时聚合 UPSERT 跑两次 | 仍只有 1 行，字节不翻倍 |
| `usage_ledger` 生成 | 1GB × 5 points = `user 5.00000000 / platform 1.00000000 / provider 4.00000000` |
| 三方金额恒等式 | 0 行违规 |
| `points_orders` 金额不等 / 余额为负 / 三方不守恒 | 均 `ERROR 3819` CHECK 拦截 |
| 分区裁剪 | `EXPLAIN` 的 `partitions` 列只出现 `p202610` |
| 分区前滚存储过程 | `CALL sp_traffic_raw_roll_forward(6)` 自动展开到 2027-04 |

前置检查：

```sql
SELECT VERSION();                       -- 必须 >= 8.0.16
SHOW VARIABLES LIKE 'default_time_zone';-- 建议 '+00:00'
SELECT @@character_set_database, @@collation_database;
```

---

## 2. ER 关系说明

```
users 1──n points_orders n──1 points_packages
users 1──1 user_points_wallets        users 1──n user_points_ledger
users 1──n user_provider_bindings n──1 providers
                       │  (STORED 生成列 + 唯一索引 ⇒ 每用户最多 1 条 status='active')
                       └─1──n provider_switch_logs (from/to 双向引用)

providers 1──n provider_nodes
providers 1──n provider_pricing_rules   (node_id NULL ⇒ 服务商级默认价；非空 ⇒ 节点覆盖价)
providers 1──n provider_settlement_terms(版本化：佣金率 / points→法币汇率 / 冻结期)

providers 1──n traffic_raw ──(binding_id 归集)── user_provider_bindings
traffic_raw 1──n traffic_usage_hourly   (binding_id + node_id + 小时桶 聚合，UPSERT)
traffic_usage_hourly 1──1 usage_ledger  (一个桶生成一条计费明细，幂等)

usage_ledger n──1 provider_settlements  (经 provider_settlement_items 关联)
usage_ledger 1──1 user_points_ledger      (扣用户；红冲成对)
usage_ledger 1──1 provider_points_ledger  (记服务商应得；红冲成对)
providers 1──1 provider_points_wallets / 1──n provider_points_ledger
```

| 关系 | 基数 | 说明 |
|---|---|---|
| users ↔ providers | **时间段多对多** | 由 `user_provider_bindings` 的 `[effective_from, effective_to)` 版本化；同一用户同时只有 1 条 `active`，历史可多条 |
| providers ↔ provider_nodes | 1:n | `(provider_id, node_code)` 唯一 |
| provider_pricing_rules | 自版本化 | 同一 `(provider_id,node_id)` 在不同时间段多条；节点价与默认价并存且节点价优先 |
| traffic_raw → binding | n:1 | 上报时按 `occurred_at` 回溯解析，**存死 binding_id 快照** |
| usage_ledger → pricing_rule | n:1 | 存死命中规则 id 与当时 `points_per_gb` / 比率 / 佣金率，事后改价不影响历史账 |
| usage_ledger → settlement_item | 1:0..1 | `provider_settlement_items.usage_ledger_id` 唯一 ⇒ 一条流量只能被结算一次 |

**用户切换服务商后的归属**（版本化带来的关键性质）：

```
时间轴 ────────────────────────────────────────────────────────►
        [ 绑定A: 服务商P1 ][ 绑定B: 服务商P2 ][ 绑定C: 服务商P3 ]
                      ▲ switch_at            ▲ switch_at
      流量 occurred_at < switch_at ⇒ 归 P1    ≥ switch_at ⇒ 归 P2
      （计费按 occurred_at 回溯绑定与定价，永远不用"当前值"）
```

---

## 3. 表清单

| # | 表名 | 用途 | 分区 | 外键 |
|---|---|---|---|---|
| 1 | `users` | 用户（**不存 current_provider_id**） | 否 | — |
| 2 | `user_points_wallets` | 用户 points 余额缓存 | 否 | ✔ users |
| 3 | `user_points_ledger` | 用户 points 不可变账本 | 否 | ✔ users / 自引用红冲 |
| 4 | `points_packages` | 法币购买 points 的套餐 | 否 | — |
| 5 | `points_orders` | 法币订单 | 否 | ✔ users / points_packages |
| 6 | `providers` | Hysteria 服务商 | 否 | — |
| 7 | `provider_nodes` | 服务商节点 | 否 | ✔ providers |
| 8 | `provider_pricing_rules` | **版本化定价** | 否 | ✔ providers / provider_nodes |
| 9 | `user_provider_bindings` | **版本化绑定** + 生成列唯一 active | 否 | ✔ users / providers |
| 10 | `provider_switch_logs` | 切换审计 | 否 | ✔ users / bindings / providers |
| 11 | `traffic_raw` | 流量原始明细（幂等） | **月分区** | **✘ 禁止（分区表限制）** |
| 12 | `traffic_ingest_idempotency` | 上报全局幂等闸门（补充表） | 否 | — |
| 13 | `traffic_usage_hourly` | 小时聚合桶 | 否 | ✔（高写入可去掉） |
| 14 | `usage_ledger` | 计费明细（三方式账） | 否 | ✔ |
| 15 | `provider_points_wallets` | 服务商 points 余额缓存 | 否 | ✔ providers |
| 16 | `provider_points_ledger` | 服务商 points 账本 | 否 | ✔ providers |
| 17 | `provider_settlement_terms` | 版本化结算条款 | 否 | ✔ providers |
| 18 | `provider_settlements` | 结算单 | 否 | ✔ providers / terms |
| 19 | `provider_settlement_items` | 结算明细（usage 级） | 否 | ✔ settlements / usage_ledger |

字段级说明见各 `.sql` 文件（每个字段都带中文注释）。关键字段概览：

- **`provider_pricing_rules`**：`provider_id`、`node_id`、`points_per_gb`、`upload_ratio`、
  `download_ratio`、`min_charge_points`、`effective_from`、`effective_to`、`priority`、`status`
- **`user_provider_bindings`**：`user_id`、`provider_id`、`external_user_id`、
  `auth_secret_encrypted`、`status`、`effective_from`、`effective_to`、`active_binding_key`（生成列）
- **`usage_ledger`**：`user_id`、`provider_id`、`node_id`、`binding_id`、`pricing_rule_id`、
  `period_start`、`period_end`、`upload_bytes`、`download_bytes`、`billable_bytes`、`billable_gb`、
  `points_per_gb`、`user_points_amount`、`provider_points_amount`、`platform_points_amount`、`status`
- **`traffic_raw`**：`provider_id`、`node_id`、`user_id`、`binding_id`、`session_id`、`occurred_at`、
  `upload_bytes`、`download_bytes`、`idempotency_key`
- **`traffic_usage_hourly`**：`user_id`、`provider_id`、`node_id`、`binding_id`、`period_start`、
  `upload_bytes`、`download_bytes`、`total_bytes`（生成列）

---

## 4. 七条核心规则的落库位置

| # | 规则 | 落库实现 |
|---|---|---|
| 1 | 用户表不存 `current_provider_id` | `users` 无该列；当前服务商 = `user_provider_bindings.status='active'` 的那条 |
| 2 | 「一个用户同时只有一个 active 绑定」 | `active_binding_key BIGINT GENERATED ALWAYS AS (CASE WHEN status='active' THEN user_id ELSE NULL END) STORED` + `UNIQUE KEY uk_user_active_binding` |
| 3 | 定价版本化，改价只增不改 | `provider_pricing_rules` 的 `[effective_from, effective_to)`；触发器禁止改动价格字段（`07`） |
| 4 | 所有 points 变动走账本 | `user_points_ledger` / `provider_points_ledger`；钱包只是缓存，且有对账 SQL（`09`） |
| 5 | 原始明细 / 小时聚合 / 计费账本分离 | `traffic_raw` → `traffic_usage_hourly` → `usage_ledger` 三层各司其职 |
| 6 | 上报幂等 | `traffic_raw.idempotency_key` + `traffic_ingest_idempotency` 全局闸门 |
| 7 | 账本不可变，修正用红冲 | `reversal_of_id` / `is_reversal`；账本表建议只授 `SELECT, INSERT`（见 §8.13） |
| 8 | 计费按发生时间取绑定与定价 | `09_reconciliation_queries.sql` §1.2 / §1.3 / §1.5 的 `LATERAL` 写法 |
| 9 | 切换服务商在事务内关旧建新 | 见 §7.2 伪代码；顺序必须是「先关旧（生成列变 NULL）→ 再插新」 |

---

## 5. `traffic_raw` 分区与 MySQL 限制

```sql
PARTITION BY RANGE COLUMNS(occurred_at) (
  PARTITION p202601 VALUES LESS THAN ('2026-02-01 00:00:00'),
  ...
  PARTITION pmax    VALUES LESS THAN (MAXVALUE)   -- 兜底，每月 REORGANIZE 前滚
);
```

**必须知道的 8 件事**

1. **分区表不能建外键**，别的表也不能外键引用分区表。`traffic_raw` 的
   `provider_id / node_id / user_id / binding_id` **全部由应用层保证**，
   配合 `09_reconciliation_queries.sql` §2.1 的孤儿巡检兜底。
2. **所有唯一键（含主键）必须包含分区列** ⇒ `PRIMARY KEY (id, occurred_at)`、
   `UNIQUE KEY (idempotency_key, occurred_at)`。
3. 因此 `uk_tr_idem` **只在分区内唯一**：跨月重放的上报理论上可重复插入 ⇒ 用
   `traffic_ingest_idempotency`（非分区、主键唯一）做**全局**幂等闸门，
   流程是「先 `INSERT IGNORE` 闸门表，受影响行数=0 即判定重复」。
4. `AUTO_INCREMENT` 列必须是某个索引首列 ⇒ 主键 `(id, occurred_at)` 满足。
5. **分区裁剪**要求 `WHERE` 直接比较分区列：`occurred_at >= ? AND occurred_at < ?`；
   写成 `WHERE DATE(occurred_at) = ?` 会退化成全分区扫描。
6. 单表分区数建议 < 100；`pmax` 必须每月前滚，否则新数据全挤在 `pmax` 里。
7. 分区表上的 `ALTER` 大多是 `ALGORITHM=COPY`，大表变更要走 `pt-online-schema-change` / `gh-ost`。
8. `ALTER TABLE ... DROP PARTITION` 秒级完成，是归档的正确姿势（`08` 有导出+校验+删除三步）。

前滚 / 归档 / 清理示例（`08_partition_maintenance.sql` 里是可直接执行的存储过程 + 事件）：

```sql
-- 前滚一个月
ALTER TABLE traffic_raw REORGANIZE PARTITION pmax INTO (
  PARTITION p202701 VALUES LESS THAN ('2027-02-01 00:00:00'),
  PARTITION pmax    VALUES LESS THAN (MAXVALUE)
);
-- 归档（先确认该分区已全部聚合与计费）
ALTER TABLE traffic_raw DROP PARTITION p202601;
-- 分区交换归档（目标表需同结构且无外键）
ALTER TABLE traffic_raw EXCHANGE PARTITION p202601 WITH TABLE traffic_raw_archive_202601;
```

---

## 6. 关键查询

### 6.1 用户当前 active 绑定

```sql
SELECT b.id AS binding_id, b.user_id, b.provider_id, b.external_user_id, b.effective_from
FROM user_provider_bindings b
WHERE b.active_binding_key = :user_id          -- 命中唯一索引，最多 1 行
  AND b.effective_from <= UTC_TIMESTAMP(6)
  AND (b.effective_to IS NULL OR b.effective_to > UTC_TIMESTAMP(6));
```

### 6.2 某服务商某节点某时刻生效的定价

匹配逻辑：`provider_id` 匹配 → `node_id` 具体节点优先于 `node_id IS NULL` 的默认价 →
`priority` 高优先 → `effective_from` 最新优先 → 时间落在 `[effective_from, effective_to)`。

```sql
SELECT r.id AS pricing_rule_id, r.points_per_gb, r.upload_ratio, r.download_ratio,
       r.min_charge_points, r.priority, r.effective_from, r.effective_to
FROM provider_pricing_rules r
WHERE r.provider_id = :provider_id
  AND (r.node_id = :node_id OR r.node_id IS NULL)
  AND r.status = 'active'
  AND r.effective_from <= :occurred_at
  AND (r.effective_to IS NULL OR r.effective_to > :occurred_at)
ORDER BY (r.node_id IS NOT NULL) DESC,      -- TRUE=1 排前 ⇒ 节点价优先
         r.priority DESC,
         r.effective_from DESC,
         r.id DESC                          -- 确定性兜底，避免同权重时结果不稳定
LIMIT 1;
```

### 6.3 按小时聚合流量

```sql
-- 注意:别名不要叫 period_start —— traffic_raw 里已有同名列，
--       GROUP BY 会优先绑定到真实列，触发 only_full_group_by 报错(1055)
INSERT INTO traffic_usage_hourly
  (user_id, provider_id, node_id, binding_id,
   period_start, period_end, upload_bytes, download_bytes, raw_record_count)
SELECT t.user_id, t.provider_id, t.node_id, t.binding_id,
       t.bucket_start, TIMESTAMPADD(HOUR, 1, t.bucket_start),
       t.upload_bytes, t.download_bytes, t.cnt
FROM (
  SELECT r.user_id, r.provider_id, r.node_id, r.binding_id,
         TIMESTAMPADD(HOUR, TIMESTAMPDIFF(HOUR, '1970-01-01 00:00:00', r.occurred_at),
                      '1970-01-01 00:00:00') AS bucket_start,   -- 整点对齐(UTC)
         SUM(r.upload_bytes) AS upload_bytes,
         SUM(r.download_bytes) AS download_bytes,
         COUNT(*) AS cnt
  FROM traffic_raw r
  WHERE r.occurred_at >= :bucket_from AND r.occurred_at < :bucket_to   -- 必须直接比分区列
  GROUP BY r.user_id, r.provider_id, r.node_id, r.binding_id, bucket_start
) t
ON DUPLICATE KEY UPDATE                       -- 命中 uk_tuh_bucket，可重跑
  upload_bytes     = VALUES(upload_bytes),
  download_bytes   = VALUES(download_bytes),
  raw_record_count = VALUES(raw_record_count);
```

### 6.4 生成 `usage_ledger`

完整可执行版本见 `09_reconciliation_queries.sql` §1.5，核心是 `JOIN LATERAL ... LIMIT 1`
按「流量发生时间」各取一条定价与条款（MySQL 8.0.14+ 支持）。关键表达式：

```sql
billable_bytes   = CAST(ROUND(up * upload_ratio + down * download_ratio) AS UNSIGNED)
billable_gb      = ROUND(CAST(... AS DECIMAL(40,8)) / 1073741824, 8)     -- 1024^3
raw_points       = ROUND(billable_gb * points_per_gb, 8)
user_points      = GREATEST(raw_points, min_charge_points)
platform_points  = ROUND(user_points * commission_rate, 8)
provider_points  = user_points - platform_points                        -- 恒等式，有 CHECK 兜底
```

> 注意 `DECIMAL(30,8) * DECIMAL(30,8)` 的中间结果精度远大于 30 位，务必
> `ROUND(..., 8)` 并用 `CAST(... AS DECIMAL(40,8))` 控制中间精度，避免 `Out of range value`。

---

## 7. 关键流程伪代码

### 7.1 用户充值 Points（法币 → points）

```
FUNCTION recharge(user_id, package_id, fiat_amount, currency, channel, req_id):
  BEGIN TX
    /* 1. 下单（幂等：idempotency_key / payment_ref 唯一） */
    INSERT INTO points_orders(order_no, user_id, package_id, base_points, bonus_points,
        points_amount = base+bonus, fiat_amount, fiat_currency=currency,
        payment_method, payment_channel, status='pending',
        idempotency_key='recharge:'+req_id, expire_at=now()+30min)
    ON DUPLICATE KEY → 直接返回已存在订单
  COMMIT → 返回支付链接

  FUNCTION on_payment_callback(channel, payment_ref, paid_amount):   /* 可重放，必须幂等 */
    BEGIN TX
      order = SELECT * FROM points_orders
              WHERE (payment_channel=:channel AND payment_ref=:payment_ref) OR order_no=:no
              FOR UPDATE                                  -- 行锁，防并发重复入账
      IF order IS NULL → 进人工对账队列
      IF order.status='paid' → RETURN 'ok'                 -- 幂等短路
      IF paid_amount < order.fiat_amount → mark failed

      wallet = SELECT * FROM user_points_wallets WHERE user_id=order.user_id FOR UPDATE
      new_bal = wallet.balance + order.points_amount

      ledger_id = INSERT INTO user_points_ledger(user_id, biz_type='recharge', direction='credit',
                    amount=order.points_amount, balance_after=new_bal,
                    biz_ref_type='points_orders', biz_ref_id=order.id,
                    idempotency_key='recharge-paid:'+channel+':'+payment_ref)
      /* 命中 uk_upl_idem ⇒ 已入账，直接提交 */

      UPDATE user_points_wallets SET balance=new_bal, total_recharged=total_recharged+amount,
             last_ledger_id=ledger_id, version=version+1 WHERE user_id=order.user_id
      UPDATE points_orders SET status='paid', paid_at=now(), ledger_id=ledger_id
       WHERE id=order.id AND status='pending'               -- CAS，防并发重复
    COMMIT
  /* 每分钟对账：通道成功但订单 pending / 订单 paid 但无 ledger ⇒ 告警或补账 */
```

### 7.2 用户切换服务商（事务内关旧建新）

```
FUNCTION switch_provider(user_id, new_provider_id, external_user_id, auth_secret, switch_at=now()):
  ASSERT provider(new_provider_id).status='active'
  BEGIN TX
    SELECT * FROM user_provider_bindings WHERE user_id=:user_id
      ORDER BY effective_from FOR UPDATE          -- 用户级加锁，串行化同一用户的切换
    old = 其中 status='active' 的那条

    /* 关键顺序：先关旧（生成列变 NULL），再插新，否则撞 uk_user_active_binding */
    IF old IS NOT NULL:
        UPDATE user_provider_bindings
           SET status='closed', effective_to=:switch_at
         WHERE id=old.id AND status='active' AND effective_to IS NULL   -- CAS
        ASSERT rowcount = 1

    new_id = INSERT INTO user_provider_bindings(user_id, provider_id=new_provider_id,
        external_user_id, auth_secret_encrypted=encrypt(auth_secret), status='active',
        effective_from=:switch_at, effective_to=NULL, switch_from_binding_id=old.id)
      /* 抛 1062 duplicate on uk_user_active_binding ⇒ 并发切换，回滚重试(最多3次退避) */

    INSERT INTO provider_switch_logs(user_id, from_binding_id=old.id, to_binding_id=new_id,
        from_provider_id=old.provider_id, to_provider_id=new_provider_id,
        effective_at=:switch_at, operator_type='user', status='success')
  COMMIT
  /* 性质：旧流量(occurred_at<switch_at)仍归旧服务商；新流量归新服务商；
     事务期间无窗口期，库层唯一索引保证不可能出现 0 条或 2 条 active */
  /* 若服务商侧 RPC（踢人/改密）失败：不回滚 DB（DB 是账务真相），
     把 switch_logs.status 标 failed 并投递补偿任务重试 */
```

### 7.3 服务商定价（改价只增不改）

```
FUNCTION set_pricing(provider_id, node_id, points_per_gb, upload_ratio, download_ratio,
                     min_charge_points, priority, effective_from, operator_id):
  BEGIN TX
    cur = SELECT * FROM provider_pricing_rules
          WHERE provider_id=:provider_id AND (node_id <=> :node_id) AND status='active'
            AND effective_from <= :effective_from
            AND (effective_to IS NULL OR effective_to > :effective_from)
          ORDER BY priority DESC, effective_from DESC LIMIT 1 FOR UPDATE

    IF cur IS NOT NULL AND NOT same_price(cur, 新值):
        UPDATE provider_pricing_rules SET effective_to=:effective_from WHERE id=cur.id
        /* 只允许改这一个字段；触发器 07 会拦住其它字段的改写 */

    IF cur IS NOT NULL AND same_price(cur, 新值) AND cur.effective_from=:effective_from:
        COMMIT; RETURN cur.id                       /* 幂等 */

    new_id = INSERT INTO provider_pricing_rules(..., effective_from=:effective_from,
                 effective_to=NULL, created_by=:operator_id)
  COMMIT
  /* 失效缓存 pricing:{provider_id}:{node_id} */
  /* "删除"= 逻辑失效：UPDATE ... SET effective_to=now(), status='inactive'，永不物理删除 */

### 7.4 流量计费（上报 → 聚合 → 扣费）

```
阶段A 上报入库（幂等，单语句事务）
  ASSERT node.provider_id == provider_id
  BEGIN TX
    affected = INSERT IGNORE INTO traffic_ingest_idempotency(idempotency_key, provider_id, node_id, occurred_at)
    IF affected = 0 → COMMIT; RETURN 'duplicate'          -- 重放直接丢弃

    binding = SELECT b.id FROM user_provider_bindings b JOIN providers p ON p.id=b.provider_id
              WHERE p.id=:provider_id AND b.external_user_id=:ext_uid
                AND b.effective_from <= :occurred_at
                AND (b.effective_to IS NULL OR b.effective_to > :occurred_at)
              ORDER BY b.effective_from DESC LIMIT 1      -- 按发生时间回溯，不是"当前绑定"
    IF binding IS NULL → 死信队列

    INSERT INTO traffic_raw(...)                          -- 无外键，id 由应用保证
    UPDATE traffic_ingest_idempotency SET traffic_raw_id=LAST_INSERT_ID() WHERE idempotency_key=:id
  COMMIT

阶段B 小时聚合（可重跑，见 §6.3）

阶段C 计费（逐桶幂等，一个批次一个事务）
  buckets = SELECT * FROM traffic_usage_hourly
            WHERE billed_status='pending' AND period_end <= now()-INTERVAL 5 MINUTE
            ORDER BY period_start, id LIMIT :batch FOR UPDATE SKIP LOCKED   -- 多 worker 安全
  FOR h IN buckets:
    binding = pick_binding_at(h.user_id, h.period_start)      -- 复核，必须等于 h.binding_id
    rule    = pick_pricing_rule_at(h.provider_id, h.node_id, h.period_start)   -- §6.2
    term    = pick_settlement_term_at(h.provider_id, h.period_start)           -- 抽成快照
    bytes_billable = ROUND(up*rule.upload_ratio + down*rule.download_ratio)
    gb             = ROUND(bytes_billable / 1073741824, 8)
    raw_points     = ROUND(gb * rule.points_per_gb, 8)
    user_points    = GREATEST(raw_points, rule.min_charge_points)
    platform_points= ROUND(user_points * term.commission_rate, 8)
    provider_points= user_points - platform_points

    扣用户：balance >= user_points ? INSERT user_points_ledger(debit) + UPDATE wallet : 失败处理
    记服务商：INSERT provider_points_ledger(usage_earning, credit) + UPDATE wallet
    落明细：INSERT usage_ledger(... 全部费率快照 ..., status='charged',
              idempotency_key=SHA2(binding|node|period_start|period_end))
    回写：UPDATE traffic_usage_hourly SET billed_status='billed', usage_ledger_id=ul_id

红冲 reverse_usage(usage_ledger_id)：
  绝不 UPDATE 金额。用户回补一份 reversal(credit)、服务商扣回一份 reversal(debit)，
  再插入一条 is_reversal=1 的 usage_ledger 红冲行，原行置 status='reversed'，
  并把小时桶 billed_status 重置为 'pending'（允许重算）。
```

### 7.5 服务商结算

```
FUNCTION generate_settlement(provider_id, period_start, period_end):
  BEGIN TX
    term = pick_settlement_term_at(provider_id, period_end)      -- 条款快照
    cutoff = now() - INTERVAL term.hold_days DAY                 -- 冻结期，防红冲穿透

    rows = SELECT ... FROM usage_ledger
           WHERE provider_id=:provider_id AND settlement_id IS NULL AND status='charged'
             AND is_reversal=0
             AND period_end > :period_start AND period_end <= :period_end AND period_end <= :cutoff
           ORDER BY period_end, id FOR UPDATE SKIP LOCKED        -- 多服务商并行安全

    gross = SUM(rows.provider_points_amount)
    IF gross < term.min_payout_points → 跳过本轮

    net_points = ROUND(gross*(1-term.payout_fee_rate)*(1-term.tax_rate), 8)
    fiat       = ROUND(net_points*term.points_to_fiat_rate, 8)

    sid = INSERT provider_settlements(... uk_ps_provider_period 防同区间重复结算 ...)
    INSERT provider_settlement_items(...)          -- uk_psi_usage 防同一条 usage 双结
    UPDATE usage_ledger SET settlement_id=sid WHERE id IN (rows.id)

    /* 服务商账本：应得转出（debit），余额减少、total_settled 增加 */
    INSERT provider_points_ledger(biz_type='settlement', direction='debit', amount=gross,
           biz_ref_type='provider_settlements', biz_ref_id=sid, idempotency_key='settle:'+sid)
    UPDATE provider_points_wallets SET balance=balance-gross, total_settled=total_settled+gross
  COMMIT

FUNCTION approve_and_payout(settlement_id):
  TX1: status 'pending' → 'approved'
  外部打款（事务外）
  TX2: 成功 → CAS 置 'paid' + payout_ref；失败 → 置 'failed' 并写红冲把 points 退回余额
```

---

## 8. MySQL 注意事项

1. **分区表无外键** ⇒ `traffic_raw` 的所有 id 靠应用层，务必部署 §2.1 孤儿巡检日报。
2. **分区表唯一键必须含分区列** ⇒ `(idempotency_key, occurred_at)` 仅分区内唯一，
   全局幂等必须靠 `traffic_ingest_idempotency`。
3. **`INSERT IGNORE` 会吞掉所有错误**（不只唯一冲突）；生产建议用
   `INSERT ... ON DUPLICATE KEY UPDATE` 或捕获 1062 精确判断。`VALUES()` 在 8.0.20 起废弃，
   可改用行别名 `INSERT ... AS t ... ON DUPLICATE KEY UPDATE col = t.col`。
4. **生成列不可显式写入**：`active_binding_key` / `signed_amount` / `total_bytes` 在
   INSERT/UPDATE 时必须省略，否则 `ERROR 3105`。
5. **关闭旧绑定必须先于插入新绑定**：`status='closed'` 让生成列变 NULL，唯一索引才不拦。
6. **`FOR UPDATE` 要有索引条件**，否则退化为大范围锁/表锁；切换绑定必须锁用户维度。
7. **默认时区**：`DEFAULT CURRENT_TIMESTAMP(6)` 取会话时区 → 必须在 `my.cnf` 设
   `default-time-zone='+00:00'`，否则不同连接写入的时间互相污染。
8. **DECIMAL 中间精度**：乘法结果精度会放大，务必 `ROUND(...,8)` + `CAST` 回目标精度。
9. **`ROUND` 是 half-up**（非银行家舍入）。计费方向（偏向平台/服务商/用户）要统一口径并写进对账。
10. **JSON 列不能直接建索引**：用 STORED 生成列 + 索引，或 8.0.13+ 函数索引
    `((CAST(metadata->>'$.channel' AS CHAR(32))))`。
11. **CHECK 约束 8.0.16 起才生效**，低版本静默忽略；JSON 列要显式 `CHECK (JSON_VALID(col))`。
12. **热点行**：`traffic_usage_hourly` 的 UPSERT 在「单 binding + 单节点 + 单小时」上会争锁，
    必要时按 binding 哈希分片或改为离线批量聚合。
13. **账本不可变建议在权限层兜底**：
    ```sql
    GRANT SELECT, INSERT ON hysteria.user_points_ledger     TO 'app'@'%';
    GRANT SELECT, INSERT ON hysteria.provider_points_ledger TO 'app'@'%';
    -- 不授 UPDATE/DELETE，“不可变”就不依赖业务代码自觉
    ```
14. **大事务禁忌**：批量计费/结算用 `LIMIT + FOR UPDATE SKIP LOCKED` 分批；禁止一条 SQL 更新百万行。
15. **分区前滚**：`08` 里的存储过程 + 事件，或 crontab 调 `mysql -e "CALL sp_traffic_raw_roll_forward(3);"`。

---

## 9. 扩展建议

- **预扣/冻结**：实时性要求高时，在 `user_points_wallets.frozen` 上做「预扣 → 账单确认 → 解冻」两阶段；
  Redis 只做限流与热点缓存，不做账务真相。
- **明细外置**：`traffic_raw` 热数据留 3 个月分区表，冷数据导出 Parquet 进 ClickHouse/对象存储，
  MySQL 只保留聚合与账务。
- **对账体系**：每日跑 `09` 的 §2.1–2.7，把差异写入 `reconciliation_reports` 并告警；
  四条链路必须闭环：原始 SUM = 小时桶 SUM = usage_ledger SUM = 结算明细 SUM。
- **可观测性三指标**：`usage_ledger.status='failed'` 数量、幂等重复命中率、
  `billed_status='pending'` 积压时长（见 §2.5）。
- **分库分表**：单表超 10 亿时按 `provider_id` 分库（服务商天然隔离），
  C 端查询通过 active 绑定路由到对应分片。
- **多币种**：`provider_settlement_terms` 已按币种 + 时间版本化；若同一条款要多币种，
  拆子表而不是塞 JSON。
- **审计**：后台改价、手工调账、红冲统一写 `admin_audit_logs`（含 before/after JSON），与账本分离。
- **软删除**：统一用 `status` 枚举，账本类表禁用物理删除与 `ON DELETE CASCADE`。

---

## 10. 与节点上报侧（hysteria-node-agent）的对接

本仓库的 agent 负责从 Hysteria 2 节点采集 `GET /traffic` 的 `{uid: {tx, rx}}` 并上报。
落到本 schema 时的映射关系：

| agent 上报字段 | 落库位置 | 注意 |
|---|---|---|
| `node_id`（节点标识） | `provider_nodes.node_code` → 解析出 `provider_nodes.id` | `(provider_id, node_code)` 唯一 |
| Hysteria `uid` | `user_provider_bindings.external_user_id` | 需先建绑定 |
| `tx`（上行字节） | `traffic_raw.upload_bytes` | |
| `rx`（下行字节） | `traffic_raw.download_bytes` | |
| 采集时间 | `traffic_raw.occurred_at`（UTC）+ `period_start/period_end` | 分区键，决定归属月份 |
| — | `traffic_raw.idempotency_key` | = `SHA2(CONCAT_WS('|', provider_id, node_id, binding_id, session_id, period_start, period_end), 256)` |

上报接口的入库顺序（对应 §7.4 阶段 A）：
**校验节点归属 → 全局幂等闸门 → 按 `occurred_at` 回溯绑定 → 写 `traffic_raw`**。
绑定不存在时不要让整批失败，应把该条投递到死信队列并告警。
