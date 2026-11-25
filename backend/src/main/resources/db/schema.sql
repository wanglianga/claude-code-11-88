-- ============================================================
-- 科研影像湖仓存储治理平台 - 数据库结构
-- PostgreSQL 18
-- ============================================================

-- ---------- 应用用户（演示用，非生产配置） ----------
CREATE TABLE IF NOT EXISTS app_user (
    id              BIGSERIAL PRIMARY KEY,
    username        VARCHAR(64) NOT NULL UNIQUE,
    password_hash   VARCHAR(128) NOT NULL,
    display_name    VARCHAR(128) NOT NULL,
    role            VARCHAR(32)  NOT NULL CHECK (role IN ('ADMIN','REVIEWER')),
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- 项目 ----------
CREATE TABLE IF NOT EXISTS project (
    id              BIGSERIAL PRIMARY KEY,
    code            VARCHAR(32) NOT NULL UNIQUE,
    name            VARCHAR(256) NOT NULL,
    status          VARCHAR(32) NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','WITHDRAWN')),
    withdrawn_at    TIMESTAMP,
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- 存储层与费率版本 ----------
CREATE TABLE IF NOT EXISTS storage_tier (
    code                    VARCHAR(32) PRIMARY KEY,
    name                    VARCHAR(64) NOT NULL,
    gb_month_rate           NUMERIC(12,6) NOT NULL,   -- 元 / GB·月
    retrieval_gb_rate       NUMERIC(12,6) NOT NULL,   -- 取回费 元/GB
    restore_compute_gb_rate NUMERIC(12,6) NOT NULL,   -- 恢复计算费 元/GB
    retrieval_hours         NUMERIC(8,2)  NOT NULL,   -- 该层取回耗时（小时）
    rto_four_hour_capable   BOOLEAN NOT NULL DEFAULT false, -- 是否满足4h恢复目标
    rate_version            VARCHAR(32) NOT NULL DEFAULT 'RV-2026Q4',
    description             VARCHAR(256)
);

-- ---------- 对象目录 ----------
CREATE TABLE IF NOT EXISTS data_object (
    id                      BIGSERIAL PRIMARY KEY,
    object_uid              VARCHAR(64) NOT NULL UNIQUE,
    name                    VARCHAR(256) NOT NULL,
    category                VARCHAR(48) NOT NULL,
    byte_size               BIGINT NOT NULL CHECK (byte_size >= 0),
    checksum                VARCHAR(128) NOT NULL,      -- sha256
    checksum_status         VARCHAR(16) NOT NULL DEFAULT 'OK'
                            CHECK (checksum_status IN ('OK','FAILED','UNVERIFIED')),
    tier_code               VARCHAR(32) NOT NULL REFERENCES storage_tier(code),
    owning_project_id       BIGINT NOT NULL REFERENCES project(id),
    created_at              TIMESTAMP NOT NULL,
    last_accessed_at        TIMESTAMP NOT NULL,
    base_retention_deadline DATE,                       -- 策略基础保留截止日
    retention_deadline      DATE,                       -- 经血缘/冻结传播后的有效截止日
    litigation_hold         BOOLEAN NOT NULL DEFAULT false,
    software_version        VARCHAR(64),                -- 算法包/派生处理的软件版本
    recipe                  TEXT,                       -- 处理配方
    directory_available     BOOLEAN NOT NULL DEFAULT true,
    is_restore_package      BOOLEAN NOT NULL DEFAULT false,
    package_target_uid      VARCHAR(64),                -- 恢复包对应的复现目标
    withdrawn               BOOLEAN NOT NULL DEFAULT false,
    note                    VARCHAR(512)
);
CREATE INDEX IF NOT EXISTS idx_object_project ON data_object(owning_project_id);
CREATE INDEX IF NOT EXISTS idx_object_category ON data_object(category);
CREATE INDEX IF NOT EXISTS idx_object_tier ON data_object(tier_code);

-- ---------- 血缘 DAG ----------
CREATE TABLE IF NOT EXISTS lineage_edge (
    id                  BIGSERIAL PRIMARY KEY,
    from_object_id      BIGINT NOT NULL REFERENCES data_object(id), -- 输入
    to_object_id        BIGINT NOT NULL REFERENCES data_object(id), -- 输出
    direction           VARCHAR(32) NOT NULL DEFAULT 'INPUT_TO_OUTPUT',
    edge_version        VARCHAR(32) NOT NULL DEFAULT 'v1',
    recipe              TEXT,
    software_version    VARCHAR(64),
    shared_reference    BOOLEAN NOT NULL DEFAULT false, -- 是否为跨项目共享引用
    created_at          TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (from_object_id, to_object_id),
    CHECK (from_object_id <> to_object_id)
);
CREATE INDEX IF NOT EXISTS idx_edge_from ON lineage_edge(from_object_id);
CREATE INDEX IF NOT EXISTS idx_edge_to ON lineage_edge(to_object_id);

-- ---------- 共享引用份额（冻结） ----------
CREATE TABLE IF NOT EXISTS object_share (
    id              BIGSERIAL PRIMARY KEY,
    object_id       BIGINT NOT NULL REFERENCES data_object(id),
    project_id      BIGINT NOT NULL REFERENCES project(id),
    frozen_share    NUMERIC(7,6) NOT NULL CHECK (frozen_share BETWEEN 0 AND 1),
    share_basis     VARCHAR(16) NOT NULL CHECK (share_basis IN ('REFERENCE','USAGE')),
    frozen_at       TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (object_id, project_id)
);

-- ---------- 保留策略（按对象类别 × 研究协议） ----------
CREATE TABLE IF NOT EXISTS retention_policy (
    id                  BIGSERIAL PRIMARY KEY,
    category            VARCHAR(48) NOT NULL,
    protocol_code       VARCHAR(32) NOT NULL,
    retention_years     NUMERIC(6,2) NOT NULL,
    rule_text           VARCHAR(512) NOT NULL,
    UNIQUE (category, protocol_code)
);

-- ---------- 成本日账（字节时长 × 层费率） ----------
CREATE TABLE IF NOT EXISTS cost_daily (
    id                  BIGSERIAL PRIMARY KEY,
    object_id           BIGINT NOT NULL REFERENCES data_object(id),
    day                 DATE NOT NULL,
    byte_hours          NUMERIC(20,3) NOT NULL,  -- 当日字节×24
    tier_code           VARCHAR(32) NOT NULL,
    gb_month_rate       NUMERIC(12,6) NOT NULL,  -- 费率版本快照
    storage_charge      NUMERIC(14,6) NOT NULL,  -- (GB) × 月费率/30
    UNIQUE (object_id, day)
);

-- ---------- 取回 / 恢复计算事件 ----------
CREATE TABLE IF NOT EXISTS retrieval_event (
    id                  BIGSERIAL PRIMARY KEY,
    object_id           BIGINT NOT NULL REFERENCES data_object(id),
    project_id          BIGINT NOT NULL REFERENCES project(id),
    plan_id             BIGINT,
    bytes               BIGINT NOT NULL,
    tier_code           VARCHAR(32) NOT NULL,
    retrieval_fee       NUMERIC(14,6) NOT NULL,
    restore_compute_fee NUMERIC(14,6) NOT NULL,
    event_time          TIMESTAMP NOT NULL DEFAULT now(),
    reason              VARCHAR(256)
);

-- ---------- 恢复计划 ----------
CREATE TABLE IF NOT EXISTS restore_plan (
    id                      BIGSERIAL PRIMARY KEY,
    target_object_id        BIGINT NOT NULL REFERENCES data_object(id),
    project_id              BIGINT NOT NULL REFERENCES project(id),
    strategy                VARCHAR(32) NOT NULL
                            CHECK (strategy IN ('SCHEDULED_TIERING','RESTORE_PACKAGE')),
    scheduled_at            TIMESTAMP,
    rto_hours               NUMERIC(6,2) NOT NULL DEFAULT 4,
    lead_hours              NUMERIC(6,2) NOT NULL DEFAULT 72,
    frequency_per_year      NUMERIC(6,2) NOT NULL DEFAULT 1,
    status                  VARCHAR(32) NOT NULL DEFAULT 'DRAFT'
                            CHECK (status IN ('DRAFT','SATISFIABLE','UNSATISFIABLE','EXECUTED','BLOCKED')),
    estimated_hours         NUMERIC(8,2),
    closure_count           INT,
    missing_items           JSONB,
    per_run_retrieval_fee   NUMERIC(14,6),
    per_run_compute_fee     NUMERIC(14,6),
    package_monthly_fee     NUMERIC(14,6),
    created_at              TIMESTAMP NOT NULL DEFAULT now(),
    note                    VARCHAR(512)
);

-- ---------- 恢复包 ----------
CREATE TABLE IF NOT EXISTS restore_package (
    id                  BIGSERIAL PRIMARY KEY,
    target_object_id    BIGINT NOT NULL REFERENCES data_object(id),
    package_object_id   BIGINT NOT NULL REFERENCES data_object(id),
    project_id          BIGINT NOT NULL REFERENCES project(id),
    validated           BOOLEAN NOT NULL DEFAULT false,
    validation_detail   JSONB,
    created_at          TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- 月账单与项目分摊 ----------
CREATE TABLE IF NOT EXISTS monthly_bill (
    id                  BIGSERIAL PRIMARY KEY,
    project_id          BIGINT NOT NULL REFERENCES project(id),
    billing_month       CHAR(7) NOT NULL,           -- 'YYYY-MM'
    storage_fee         NUMERIC(14,6) NOT NULL,
    retrieval_fee       NUMERIC(14,6) NOT NULL,
    restore_compute_fee NUMERIC(14,6) NOT NULL,
    total_fee           NUMERIC(14,6) NOT NULL,
    allocation_json     JSONB NOT NULL,
    allocation_check    BOOLEAN NOT NULL,
    UNIQUE (project_id, billing_month)
);

-- ---------- 归档快照（目录水位 + 依赖 + 费率版本 + 决定） ----------
CREATE TABLE IF NOT EXISTS archive_snapshot (
    id              BIGSERIAL PRIMARY KEY,
    snapshot_date   DATE NOT NULL,
    rate_version    VARCHAR(32) NOT NULL,
    catalog_json    JSONB NOT NULL,   -- 目录水位
    lineage_json    JSONB NOT NULL,   -- 依赖
    billing_json    JSONB NOT NULL,   -- 账单与分摊
    decisions_json  JSONB NOT NULL,   -- 迁移/保留/计费理由（可回放）
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- 治理事件（校验失败/规则变化/冻结，需传播） ----------
CREATE TABLE IF NOT EXISTS governance_event (
    id              BIGSERIAL PRIMARY KEY,
    event_type      VARCHAR(48) NOT NULL
                    CHECK (event_type IN (
                        'CHECKSUM_FAILED','RETENTION_RULE_CHANGED','LITIGATION_HOLD',
                        'LITIGATION_HOLD_RELEASED','PROJECT_WITHDRAWN','RESTORE_BLOCKED',
                        'TIER_MIGRATION','SHARE_FROZEN')),
    object_id       BIGINT REFERENCES data_object(id),
    project_id      BIGINT REFERENCES project(id),
    payload         JSONB,
    propagated      BOOLEAN NOT NULL DEFAULT false,
    affected_uids   JSONB,
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);
