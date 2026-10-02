-- =============================================================================
-- 08 · traffic_raw 分区维护（前滚 / 归档 / 巡检）
-- 分区按 occurred_at 月切分；pmax 为兜底分区，必须每月前滚，否则新数据全挤在
-- pmax 里，分区裁剪失效，且单分区无限增长。
-- =============================================================================

USE `hysteria`;

-- -----------------------------------------------------------------------------
-- 8.1 分区巡检：查看每个分区的边界与数据量
-- -----------------------------------------------------------------------------
SELECT PARTITION_NAME,
       PARTITION_DESCRIPTION                          AS less_than,
       TABLE_ROWS                                     AS approx_rows,
       ROUND(DATA_LENGTH / 1024 / 1024, 2)            AS data_mb,
       ROUND(INDEX_LENGTH / 1024 / 1024, 2)           AS index_mb
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'traffic_raw'
ORDER BY PARTITION_ORDINAL_POSITION;

-- -----------------------------------------------------------------------------
-- 8.2 前滚存储过程：保证未来 N 个月的分区已存在
--     原理：读 pmax 之前最后一个分区的边界，逐月 REORGANIZE pmax 展开一个月。
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_traffic_raw_roll_forward;
DELIMITER $$
CREATE PROCEDURE sp_traffic_raw_roll_forward(IN p_months_ahead INT)
BEGIN
  DECLARE v_guard     INT DEFAULT 0;
  DECLARE v_prev      DATETIME;
  DECLARE v_next      DATETIME;
  DECLARE v_name      VARCHAR(16);
  DECLARE v_target    DATETIME;
  -- 注意:PREPARE 的来源只能是字面量或**用户变量**(@v_sql)，
  --       不能用 DECLARE 出来的局部变量，否则报 1064。

  -- 目标边界：当前月 + p_months_ahead 个月后的 1 号
  SET v_target = DATE_FORMAT(DATE_ADD(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL p_months_ahead MONTH),
                             '%Y-%m-%d 00:00:00');

  loop_label: LOOP
    SET v_guard = v_guard + 1;
    IF v_guard > 120 THEN LEAVE loop_label; END IF;
    IF p_months_ahead < 1 THEN LEAVE loop_label; END IF;

    -- 取 pmax 之前最大的分区边界（PARTITION_DESCRIPTION 形如 '2027-02-01 00:00:00'）
    SELECT MAX(STR_TO_DATE(REPLACE(PARTITION_DESCRIPTION, '''', ''), '%Y-%m-%d %H:%i:%s'))
      INTO v_prev
    FROM information_schema.PARTITIONS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'traffic_raw'
      AND PARTITION_NAME <> 'pmax';

    IF v_prev IS NULL THEN LEAVE loop_label; END IF;
    IF v_prev >= v_target THEN LEAVE loop_label; END IF;   -- 已满足

    SET v_next = DATE_ADD(v_prev, INTERVAL 1 MONTH);
    SET v_name = CONCAT('p', DATE_FORMAT(v_next, '%Y%m'));

    SET @v_sql = CONCAT(
      'ALTER TABLE traffic_raw REORGANIZE PARTITION pmax INTO (',
      'PARTITION ', v_name, ' VALUES LESS THAN (''', DATE_FORMAT(v_next, '%Y-%m-%d %H:%i:%s'), '''),',
      'PARTITION pmax VALUES LESS THAN (MAXVALUE))');

    PREPARE stmt FROM @v_sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  END LOOP;

  SELECT CONCAT('roll_forward done, guard=', v_guard) AS result;
END$$
DELIMITER ;

-- 建表后先补 3 个月
CALL sp_traffic_raw_roll_forward(3);

-- -----------------------------------------------------------------------------
-- 8.3 每月自动前滚（需 event_scheduler=ON；否则用 crontab 调 mysql）
-- -----------------------------------------------------------------------------
-- SET GLOBAL event_scheduler = ON;
DROP EVENT IF EXISTS ev_traffic_raw_roll_forward;
DELIMITER $$
CREATE EVENT IF NOT EXISTS ev_traffic_raw_roll_forward
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 3 HOUR)   -- 每天 03:00(服务器本地时间)
DO
BEGIN
  CALL sp_traffic_raw_roll_forward(3);
END$$
DELIMITER ;

-- -----------------------------------------------------------------------------
-- 8.4 归档：热数据保留 N 个月，更早的分区导出后 DROP（秒级，不产生大事务）
-- -----------------------------------------------------------------------------
-- 步骤 1：导出（在 shell 里做，避免 DETACH 之类的 MySQL 不支持的语法）
--   mysqldump -h127.0.0.1 -uroot hysteria traffic_raw \
--     --where="occurred_at >= '2026-01-01' AND occurred_at < '2026-02-01'" \
--     --no-create-info --single-transaction | xz -9 > traffic_raw_202601.sql.xz
-- 步骤 2：删除分区
-- ALTER TABLE traffic_raw DROP PARTITION p202601;

-- 可选：分区交换归档（目标表必须结构一致、且**没有外键**）
-- ALTER TABLE traffic_raw EXCHANGE PARTITION p202601
--   WITH TABLE traffic_raw_archive_202601;

-- 归档前校验：该分区是否已全部聚合与计费，未处理完不能删
SELECT COUNT(*) AS not_billed_rows
FROM traffic_raw r
WHERE r.occurred_at >= '2026-01-01 00:00:00'
  AND r.occurred_at <  '2026-02-01 00:00:00'
  AND NOT EXISTS (
    SELECT 1 FROM traffic_usage_hourly h
    WHERE h.binding_id   = r.binding_id
      AND h.node_id      = r.node_id
      AND h.period_start = TIMESTAMPADD(HOUR, TIMESTAMPDIFF(HOUR, '1970-01-01 00:00:00', r.occurred_at),
                                       '1970-01-01 00:00:00')
  );

-- -----------------------------------------------------------------------------
-- 8.5 幂等键清理（保留 90 天，避免小表无限膨胀）
-- -----------------------------------------------------------------------------
DELETE FROM traffic_ingest_idempotency
WHERE created_at < UTC_TIMESTAMP(6) - INTERVAL 90 DAY
LIMIT 10000;   -- 分批删，避免大事务
