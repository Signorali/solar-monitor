-- ============================================================
-- Solar Monitor schema
-- ============================================================
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- ============== sensors: cihaz envanteri ==============
CREATE TABLE IF NOT EXISTS sensors (
    id              SERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,
    type            TEXT NOT NULL,              -- 'pzem-017' | 'jk-bms' | 'voltronic-pi30'
    display_name    TEXT NOT NULL,
    address         INTEGER,                    -- modbus addr (pzem only)
    port            TEXT,                       -- /dev/solar_pzem | /dev/solar_bms | /dev/solar_inverter
    config          JSONB NOT NULL DEFAULT '{}',
    serial_number   TEXT,
    installed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    removed_at      TIMESTAMPTZ,
    replaced_by_id  INTEGER REFERENCES sensors(id),
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    metadata        JSONB NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS ix_sensors_active ON sensors(id) WHERE enabled = TRUE AND removed_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sensors_type ON sensors(type) WHERE enabled = TRUE;

-- ============== pzem_readings ==============
CREATE TABLE IF NOT EXISTS pzem_readings (
    sensor_id   INTEGER NOT NULL REFERENCES sensors(id),
    ts          TIMESTAMPTZ NOT NULL,
    voltage_v   REAL,
    current_a   REAL,
    power_w     REAL,
    energy_wh   INTEGER,
    PRIMARY KEY (sensor_id, ts)
);
SELECT create_hypertable('pzem_readings', 'ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS ix_pzem_readings_ts ON pzem_readings(ts DESC);

-- ============== bms_readings ==============
CREATE TABLE IF NOT EXISTS bms_readings (
    sensor_id       INTEGER NOT NULL REFERENCES sensors(id),
    ts              TIMESTAMPTZ NOT NULL,
    pack_v          REAL,
    soc             SMALLINT,
    current_a       REAL,
    cycle           INTEGER,
    t_mos           SMALLINT,
    t_bat           SMALLINT,
    t_amb           SMALLINT,
    diff_v          REAL,
    cells           REAL[],
    balance_on      BOOLEAN,
    charge_mos      BOOLEAN,
    discharge_mos   BOOLEAN,
    PRIMARY KEY (sensor_id, ts)
);
SELECT create_hypertable('bms_readings', 'ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS ix_bms_readings_ts ON bms_readings(ts DESC);

-- ============== inverter_readings ==============
CREATE TABLE IF NOT EXISTS inverter_readings (
    sensor_id   INTEGER NOT NULL REFERENCES sensors(id),
    ts          TIMESTAMPTZ NOT NULL,
    grid_v      REAL,
    grid_hz     REAL,
    out_v       REAL,
    out_hz      REAL,
    out_va      INTEGER,
    out_w       INTEGER,
    load_pct    SMALLINT,
    bus_v       INTEGER,
    bat_v       REAL,
    bat_chg_a   SMALLINT,
    bat_dis_a   SMALLINT,
    bat_soc     SMALLINT,
    heat_t      SMALLINT,
    pv_v        REAL,
    pv_a        REAL,
    pv_w        INTEGER,
    mode        CHAR(1),
    status_bits TEXT,
    warnings    TEXT,
    fault_code  INTEGER,
    PRIMARY KEY (sensor_id, ts)
);
SELECT create_hypertable('inverter_readings', 'ts', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS ix_inverter_readings_ts ON inverter_readings(ts DESC);

-- ============== settings: tüm sistem ayarları ==============
CREATE TABLE IF NOT EXISTS settings (
    key             TEXT PRIMARY KEY,
    value           JSONB NOT NULL,
    description     TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============== tariff_versions: tarife versiyonu (eski veri eski fiyat) ==============
CREATE TABLE IF NOT EXISTS tariff_versions (
    id              SERIAL PRIMARY KEY,
    valid_from      TIMESTAMPTZ NOT NULL,         -- bu tarihten itibaren bu fiyat gecerli
    price_per_kwh   NUMERIC(10,4) NOT NULL,       -- TL/kWh
    currency        TEXT NOT NULL DEFAULT 'TRY',
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS ix_tariff_valid_from ON tariff_versions(valid_from DESC);

-- ============== events: olay/log ==============
CREATE TABLE IF NOT EXISTS events (
    id          SERIAL PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    severity    TEXT NOT NULL DEFAULT 'info',      -- info | warning | error
    source      TEXT NOT NULL,                     -- collector | inverter | bms | user | system
    sensor_id   INTEGER REFERENCES sensors(id),
    code        TEXT,
    message     TEXT NOT NULL,
    data        JSONB
);
CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts DESC);

-- ============== maintenance_log: cihaz kontrol komutları audit ==============
CREATE TABLE IF NOT EXISTS maintenance_log (
    id              SERIAL PRIMARY KEY,
    ts              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sensor_id       INTEGER REFERENCES sensors(id),
    action          TEXT NOT NULL,
    target          TEXT,
    before_state    JSONB,
    after_state     JSONB,
    success         BOOLEAN NOT NULL,
    duration_ms     INTEGER,
    actor           TEXT,
    error_message   TEXT
);
CREATE INDEX IF NOT EXISTS ix_maintenance_ts ON maintenance_log(ts DESC);

-- ============== Default settings ==============
INSERT INTO settings (key, value, description) VALUES
    ('app_timezone',       '"Europe/Istanbul"', 'Sistem saat dilimi'),
    ('app_locale',         '"tr-TR"',           'Dil/yerel'),
    ('pzem_poll_s',        '2',                 'PZEM bus okuma periyodu (saniye)'),
    ('bms_poll_s',         '2',                 'BMS okuma periyodu (saniye)'),
    ('inverter_poll_s',    '5',                 'Inverter okuma periyodu (saniye)'),
    ('ws_push_interval_ms','1000',              'WebSocket canli veri push hizi (ms)'),
    ('maintenance_mode',   'false',             'Bakim modu: collector durur, port erisilir'),
    ('setup_completed',    'false',             'Ilk kurulum tamamlandi mi'),
    ('default_currency',   '"TRY"',             'Birim para birimi'),
    ('battery_capacity_wh','5000',              'Batarya nominal kapasitesi (Wh) - cost icin')
ON CONFLICT (key) DO NOTHING;

-- ============== TimescaleDB sıkıştırma + retention (10 yıl) ==============
-- 1 günlük chunk'lar; 3 günden eski chunk'lar kolon-bazlı sıkıştırılır (~10x kazanç);
-- 10 yıl (3650 gün) sonra otomatik silinir. 10 yıllık veri sıkıştırmayla ~14 GB.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name='pzem_readings') THEN
        PERFORM set_chunk_time_interval('pzem_readings',     INTERVAL '1 day');
        PERFORM set_chunk_time_interval('bms_readings',      INTERVAL '1 day');
        PERFORM set_chunk_time_interval('inverter_readings', INTERVAL '1 day');

        ALTER TABLE pzem_readings     SET (timescaledb.compress, timescaledb.compress_segmentby='sensor_id', timescaledb.compress_orderby='ts DESC');
        ALTER TABLE bms_readings      SET (timescaledb.compress, timescaledb.compress_segmentby='sensor_id', timescaledb.compress_orderby='ts DESC');
        ALTER TABLE inverter_readings SET (timescaledb.compress, timescaledb.compress_segmentby='sensor_id', timescaledb.compress_orderby='ts DESC');

        PERFORM add_compression_policy('pzem_readings',     INTERVAL '3 days', if_not_exists => TRUE);
        PERFORM add_compression_policy('bms_readings',      INTERVAL '3 days', if_not_exists => TRUE);
        PERFORM add_compression_policy('inverter_readings', INTERVAL '3 days', if_not_exists => TRUE);

        PERFORM add_retention_policy('pzem_readings',     INTERVAL '3650 days', if_not_exists => TRUE);
        PERFORM add_retention_policy('bms_readings',      INTERVAL '3650 days', if_not_exists => TRUE);
        PERFORM add_retention_policy('inverter_readings', INTERVAL '3650 days', if_not_exists => TRUE);
    END IF;
END $$;
