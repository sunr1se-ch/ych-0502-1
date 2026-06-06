CREATE TABLE cocoon_batches (
    id SERIAL PRIMARY KEY,
    cocoon_type VARCHAR(100) NOT NULL,
    target_reeling_kg DECIMAL(10,2) NOT NULL,
    target_temp DECIMAL(5,2) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    is_suspect BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE boil_curves (
    id SERIAL PRIMARY KEY,
    batch_id INTEGER NOT NULL REFERENCES cocoon_batches(id) ON DELETE CASCADE,
    temp_c DECIMAL(5,2) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_boil_curves_batch_time ON boil_curves(batch_id, recorded_at);

CREATE TABLE float_events (
    id SERIAL PRIMARY KEY,
    batch_id INTEGER NOT NULL REFERENCES cocoon_batches(id) ON DELETE CASCADE,
    float_ratio_pct DECIMAL(5,2) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_float_events_batch_time ON float_events(batch_id, recorded_at);
