-- =============================================================================
-- 07 · 可选触发器
-- MySQL 没有 PostgreSQL 的 EXCLUDE 排他约束。唯一 active 绑定已由生成列 +
-- 唯一索引在库层硬保证；但"历史绑定时间区间不重叠"与"定价只增不改"
-- 只能靠应用层事务（SELECT ... FOR UPDATE）保证，本文件提供库层兜底方案。
--
-- 使用前请确认：这些触发器会在每次写入时多一次 SELECT，
-- 若绑定/定价写入 QPS 很高，可只用应用层事务而不启用本文件。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 7.1 绑定：禁止修改 effective_from（版本化记录不可改写）
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_upb_no_change_from;
DELIMITER $$
CREATE TRIGGER trg_upb_no_change_from
BEFORE UPDATE ON user_provider_bindings
FOR EACH ROW
BEGIN
  IF NEW.effective_from <> OLD.effective_from
     OR NEW.provider_id    <> OLD.provider_id
     OR NEW.user_id        <> OLD.user_id THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = '绑定属于版本化记录:只允许关闭(effective_to/status),不允许改写起始时间或归属';
  END IF;
END$$
DELIMITER ;

-- -----------------------------------------------------------------------------
-- 7.2 绑定：保证同一用户的历史时间区间不重叠
--     判定：两区间 [a1,a2) 与 [b1,b2) 重叠 ⇔ a1 < b2 AND b1 < a2
--     区间终点 NULL 视为 +∞
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_upb_no_overlap_ins;
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

CREATE TRIGGER trg_upb_no_overlap_upd
BEFORE UPDATE ON user_provider_bindings
FOR EACH ROW
BEGIN
  DECLARE v_conflict INT DEFAULT 0;
  SELECT COUNT(*) INTO v_conflict
  FROM user_provider_bindings b
  WHERE b.user_id = NEW.user_id
    AND b.id <> NEW.id
    AND b.effective_from < COALESCE(NEW.effective_to, '9999-12-31 23:59:59.999999')
    AND COALESCE(b.effective_to, '9999-12-31 23:59:59.999999') > NEW.effective_from;
  IF v_conflict > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '绑定时间区间与其它记录重叠';
  END IF;
END$$
DELIMITER ;

-- -----------------------------------------------------------------------------
-- 7.3 定价：只允许"关闭"（写 effective_to / status），禁止改动价格与生效起点
--     这条把"改价必须新增记录"落到库级别，杜绝静默改历史价。
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_ppr_immutable_fields;
DELIMITER $$
CREATE TRIGGER trg_ppr_immutable_fields
BEFORE UPDATE ON provider_pricing_rules
FOR EACH ROW
BEGIN
  IF NEW.points_per_gb     <> OLD.points_per_gb
     OR NEW.upload_ratio      <> OLD.upload_ratio
     OR NEW.download_ratio    <> OLD.download_ratio
     OR NEW.min_charge_points <> OLD.min_charge_points
     OR NEW.provider_id       <> OLD.provider_id
     OR NEW.effective_from    <> OLD.effective_from
     OR NOT (NEW.node_id <=> OLD.node_id) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = '定价记录不可修改:改价请新增版本,仅允许写 effective_to/status/priority';
  END IF;
END$$
DELIMITER ;

-- -----------------------------------------------------------------------------
-- 7.4 定价：同一 (provider_id, node_id) 的时间区间不允许重叠
--     注意：允许"节点价"与"默认价"同时存在（node_id 不同视为不同序列）
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_ppr_no_overlap_ins;
DELIMITER $$
CREATE TRIGGER trg_ppr_no_overlap_ins
BEFORE INSERT ON provider_pricing_rules
FOR EACH ROW
BEGIN
  DECLARE v_conflict INT DEFAULT 0;
  SELECT COUNT(*) INTO v_conflict
  FROM provider_pricing_rules r
  WHERE r.provider_id = NEW.provider_id
    AND (r.node_id <=> NEW.node_id)
    AND r.effective_from < COALESCE(NEW.effective_to, '9999-12-31 23:59:59.999999')
    AND COALESCE(r.effective_to, '9999-12-31 23:59:59.999999') > NEW.effective_from;
  IF v_conflict > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '定价时间区间与已有记录重叠';
  END IF;
END$$
DELIMITER ;

-- -----------------------------------------------------------------------------
-- 7.5 结算条款同样不可改写（只允许写 effective_to / status）
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_pst_immutable_fields;
DELIMITER $$
CREATE TRIGGER trg_pst_immutable_fields
BEFORE UPDATE ON provider_settlement_terms
FOR EACH ROW
BEGIN
  IF NEW.points_to_fiat_rate <> OLD.points_to_fiat_rate
     OR NEW.commission_rate   <> OLD.commission_rate
     OR NEW.currency          <> OLD.currency
     OR NEW.effective_from    <> OLD.effective_from
     OR NEW.provider_id       <> OLD.provider_id THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = '结算条款不可修改:请新增版本,仅允许写 effective_to/status';
  END IF;
END$$
DELIMITER ;
