-- Synthetic seed data for the CI full cycle run. Nothing here is real.
CREATE TABLE customers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  email text NOT NULL UNIQUE,
  phone text NOT NULL
);

CREATE TABLE jobs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  title text NOT NULL,
  status text NOT NULL DEFAULT 'scheduled',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobs_customer_idx ON jobs (customer_id);

CREATE TABLE invoices (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id bigint NOT NULL REFERENCES jobs (id),
  amount_cents integer NOT NULL CHECK (amount_cents >= 0),
  paid boolean NOT NULL DEFAULT false
);

CREATE TABLE empty_table (
  id bigint PRIMARY KEY
);

INSERT INTO customers (name, email, phone)
SELECT 'Sample Customer ' || n,
       'customer' || n || '@example.com',
       '555-01' || lpad((n % 100)::text, 2, '0')
FROM generate_series(1, 250) AS n;

INSERT INTO jobs (customer_id, title)
SELECT (n % 250) + 1, 'Sample job ' || n
FROM generate_series(1, 1200) AS n;

INSERT INTO invoices (job_id, amount_cents)
SELECT n, 1000 + n
FROM generate_series(1, 900) AS n;

-- A second schema that the default BACKUP_SCHEMAS=public must leave out.
CREATE SCHEMA private;
CREATE TABLE private.audit_log (id bigint PRIMARY KEY, note text);
INSERT INTO private.audit_log VALUES (1, 'not part of the public schema dump');
