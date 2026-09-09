-- NUSA Cloud — performance indexes (idempoten, aman dijalankan berulang).
-- Jalankan via:
--   wrangler d1 execute nusa-db --file=schema_indexes.sql --remote

CREATE INDEX IF NOT EXISTS idx_orders_store_created ON online_orders(store_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_store_status ON online_orders(store_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_store_phone ON online_orders(store_id, customer_phone, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_op_store_pub_cat ON online_products(store_id, is_published, category);
CREATE INDEX IF NOT EXISTS idx_op_store_pub ON online_products(store_id, is_published);
CREATE INDEX IF NOT EXISTS idx_promos_store_active ON promos(store_id, is_active, end_date);
CREATE INDEX IF NOT EXISTS idx_licenses_status ON licenses(status, expires_at);
CREATE INDEX IF NOT EXISTS idx_activations_license_created ON activations(license_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_branches_store ON branches(store_id, is_active);
CREATE INDEX IF NOT EXISTS idx_oc_store_phone ON online_customers(store_id, phone);
