/*
Changes compared with the logical model (diagram updated accordingly)
1. record_ts DATE NOT NULL DEFAULT current_date is added to every table. It is a
   technical audit column that depends only on its own row's key, so it is outside the 3NF analysis.
2. SERIAL/BIGSERIAL keys are implemented as INTEGER/BIGINT GENERATED ALWAYS AS IDENTITY.
   Same range and behaviour, but it is the SQL standard and rejects manual ids. With SERIAL an
   explicit id does not advance the sequence, so a later generated id fails with a duplicate key.
3. Every business date/timestamp column has CHECK (date > 2000-01-01).
No other tables, columns or relations were added.

Why the DDL order matters
A foreign key can only reference a table that already exists, so tables are created parents first:
  1) no foreign keys: service_pattern, line, station, train, ticket_type, maintenance_type
  2) line_station, track_segment, schedule_version, ticket_type_station, ticket_price
  3) trip, ticket, maintenance_work_order
  4) trip_stop, trip_run
  5) trip_run_status_history, work_order_status_history
A wrong order fails with: ERROR: relation "subway.trip" does not exist (inside one transaction the
whole script rolls back). DROP and DELETE use the reverse order, children first.

Why foreign keys matter
Without them, orphan rows appear (a ticket for an undefined price, a trip_stop for a deleted
line_station), parents can be deleted while still in use, joins silently lose rows, and reports and
price/timetable history become wrong. All 22 foreign keys use ON DELETE RESTRICT.

Data type choices and the risk of the alternatives
- price NUMERIC(10,2), not REAL/DOUBLE: floats cannot store 0.10 exactly, so sums drift.
- dates as DATE, not VARCHAR: text sorts wrongly ('10.01' < '9.01'), accepts '31/02/2026',
  and cannot be used with daterange() or EXCLUDE.
- events as TIMESTAMPTZ: TIME loses the day, and TIMESTAMP gives different moments per client
  time zone (daylight saving errors in maintenance windows).
- planned stop times as TIME: a daily template, trips do not cross midnight.
- ids INTEGER, but BIGINT for high-volume tables (ticket, trip_run, both history tables),
  because INTEGER overflows at about 2.1 billion rows.
- codes/names VARCHAR(n), not CHAR(n): CHAR pads with spaces, so 'M1' <> 'M1  ' in some
  comparisons. Too small an n rejects valid names, unlimited TEXT hides bad data.
- capacity, length_m, validity_hours INTEGER: whole numbers only, range CHECKs work.
- can_enter/can_exit BOOLEAN, not 'Y'/'N' or 0/1, which would accept 'yes', 'maybe' or 2.

Data loading
- No surrogate id is typed. Child rows come from INSERT ... SELECT joining the parent on its
  business key (line_code, station_name, train_number, type_name ...). A typo returns no row, so
  nothing is inserted instead of a wrong link. Text keys are compared with UPPER() on both sides,
  so 'm1' and 'M1' find the same parent.
- Reruns add nothing: ON CONFLICT DO NOTHING on UNIQUE business keys, or WHERE NOT EXISTS.
- Data is loaded parent first, in DDL order, one transaction per group.
- Triggers R1-R4 enforce cross-table rules during the load, so inconsistent rows (a stop from
  another line, a ticket sold under an expired price) are rejected.
- Trigger R3 writes status history whenever a trip_run or work order is inserted or its status
  changes, so history never disagrees with the current status.
- INSERT/UPDATE statements have no RETURNING: nothing in this script reads the returned rows.
  The result of the load is checked once, in section 5.
*/

-- 0. SCHEMA AND EXTENSION
-- CREATE SCHEMA creates a namespace inside the database we are connected to; it does NOT create
-- a database. The script assumes the target database already exists (CREATE DATABASE is done
-- beforehand, outside this script) and that we are connected to it.
-- Both objects are created in one transaction: the tables of section 1 need both, so either both
-- exist or neither. DDL is transactional in PostgreSQL, so a failure undoes both.
-- IF NOT EXISTS makes a rerun harmless (it does not check that an existing schema is the same).
BEGIN;

CREATE SCHEMA IF NOT EXISTS subway;

-- btree_gist is needed for EXCLUDE constraints that combine "=" on an integer with "&&" on a period.
CREATE EXTENSION IF NOT EXISTS btree_gist;

COMMIT;

-- 1. TABLES (parents first) WITH PK, FK, DEFAULT, CHECK, UNIQUE, NOT NULL, EXCLUDE
-- The 18 tables are created in one transaction because they form one logical model: a model with
-- missing tables cannot be used. If any statement fails, PostgreSQL rolls the whole block back and
-- no table of this block exists, so the script can simply be fixed and run again.
-- CREATE TABLE IF NOT EXISTS makes a rerun skip tables that exist (it does not alter them).
BEGIN;

-- ---- Level 1: tables without foreign keys ---------------------------------------------------

CREATE TABLE IF NOT EXISTS subway.service_pattern (
  service_pattern_id   INTEGER GENERATED ALWAYS AS IDENTITY,
  -- UNIQUE + NOT NULL (types 4 and 5): blocks two patterns with the same code ('WEEKDAY' twice);
  -- without it trips would be linked to an ambiguous pattern and lookups by code would return 2 rows.
  service_pattern_code VARCHAR(30)  NOT NULL,
  service_pattern_name VARCHAR(80)  NOT NULL,
  CONSTRAINT pk_service_pattern      PRIMARY KEY (service_pattern_id),
  CONSTRAINT uq_service_pattern_code UNIQUE (service_pattern_code)
);

CREATE TABLE IF NOT EXISTS subway.line (
  line_id             INTEGER GENERATED ALWAYS AS IDENTITY,
  line_code           VARCHAR(10)  NOT NULL,
  line_name           VARCHAR(100) NOT NULL,
  in_service_date     DATE         NOT NULL,
  out_of_service_date DATE,
  CONSTRAINT pk_line PRIMARY KEY (line_id),
  CONSTRAINT uq_line_code UNIQUE (line_code),
  CONSTRAINT uq_line_name UNIQUE (line_name),
  CONSTRAINT chk_line_in_service_2000 CHECK (in_service_date > DATE '2000-01-01'),
  CONSTRAINT chk_line_dates CHECK (out_of_service_date >= in_service_date)
);

CREATE TABLE IF NOT EXISTS subway.station (
  station_id          INTEGER GENERATED ALWAYS AS IDENTITY,
  station_name        VARCHAR(100) NOT NULL,
  in_service_date     DATE         NOT NULL,
  out_of_service_date DATE,
  CONSTRAINT pk_station         PRIMARY KEY (station_id),
  CONSTRAINT uq_station_name    UNIQUE (station_name),
  CONSTRAINT chk_station_in_service_2000 CHECK (in_service_date > DATE '2000-01-01'),
  CONSTRAINT chk_station_dates  CHECK (out_of_service_date >= in_service_date)
);

CREATE TABLE IF NOT EXISTS subway.train (
  train_id            INTEGER GENERATED ALWAYS AS IDENTITY,
  train_number        VARCHAR(20) NOT NULL,
  capacity            INTEGER     NOT NULL,
  in_service_date     DATE        NOT NULL,
  out_of_service_date DATE,
  CONSTRAINT pk_train           PRIMARY KEY (train_id),
  CONSTRAINT uq_train_number    UNIQUE (train_number),
  -- Type 2 (measured value cannot be negative): capacity must be positive. Without it a train with
  -- capacity -5 or 0 would be accepted and passenger-load calculations would be meaningless.
  CONSTRAINT chk_train_capacity CHECK (capacity > 0),
  CONSTRAINT chk_train_in_service_2000 CHECK (in_service_date > DATE '2000-01-01'),
  CONSTRAINT chk_train_dates    CHECK (out_of_service_date >= in_service_date)
);

CREATE TABLE IF NOT EXISTS subway.ticket_type (
  ticket_type_id INTEGER GENERATED ALWAYS AS IDENTITY,
  type_name      VARCHAR(50) NOT NULL,
  CONSTRAINT pk_ticket_type      PRIMARY KEY (ticket_type_id),
  CONSTRAINT uq_ticket_type_name UNIQUE (type_name)
);

CREATE TABLE IF NOT EXISTS subway.maintenance_type (
  maintenance_type_id INTEGER GENERATED ALWAYS AS IDENTITY,
  type_name           VARCHAR(50)  NOT NULL,
  description         VARCHAR(255),
  interval_days       INTEGER,
  CONSTRAINT pk_maintenance_type      PRIMARY KEY (maintenance_type_id),
  CONSTRAINT uq_maintenance_type_name UNIQUE (type_name),
  CONSTRAINT chk_maint_type_interval  CHECK (interval_days > 0)
);

-- ---- Level 2: tables that reference level 1 ------------------------------------------------

-- Design note for the EXCLUDE constraints used in this level (line_station, schedule_version,
-- ticket_type_station, ticket_price):
-- These tables store history: the same business object has several rows, each valid for a period
-- (valid_from .. valid_to). UNIQUE (object, valid_from) only stops two rows with the SAME start date;
-- it does not stop periods that overlap (2026-01-01..2026-12-31 and 2026-06-01..NULL). An EXCLUDE
-- constraint with the range overlap operator && forbids exactly that, inside the database, for
-- every client and in concurrent sessions. Alternatives and why they were not chosen:
--   - a trigger doing the overlap check: more code, and two parallel transactions can both pass
--     the check before either commits (race condition); EXCLUDE is checked atomically by the index;
--   - a check in the application: other clients (scripts, manual SQL) can bypass it.
-- Cost: the btree_gist extension and one GiST index per constraint, acceptable for small
-- reference tables that are rarely written.

CREATE TABLE IF NOT EXISTS subway.line_station (
  line_station_id INTEGER GENERATED ALWAYS AS IDENTITY,
  line_id         INTEGER NOT NULL,
  station_id      INTEGER NOT NULL,
  stop_sequence   INTEGER NOT NULL,
  valid_from      DATE    NOT NULL DEFAULT current_date,
  valid_to        DATE,
  CONSTRAINT pk_line_station PRIMARY KEY (line_station_id),
  -- Without these FKs a stop could point to a line or station that does not exist (orphan stop).
  CONSTRAINT fk_line_station_line    FOREIGN KEY (line_id)    REFERENCES subway.line (line_id)       ON DELETE RESTRICT,
  CONSTRAINT fk_line_station_station FOREIGN KEY (station_id) REFERENCES subway.station (station_id) ON DELETE RESTRICT,
  CONSTRAINT uq_line_station_seq     UNIQUE (line_id, stop_sequence, valid_from),
  CONSTRAINT uq_line_station_stn     UNIQUE (line_id, station_id, valid_from),
  CONSTRAINT chk_line_station_seq    CHECK (stop_sequence > 0),
  CONSTRAINT chk_line_station_from_2000 CHECK (valid_from > DATE '2000-01-01'),
  CONSTRAINT chk_line_station_period CHECK (valid_to >= valid_from),
  -- The same station is never on the same line twice in the same period; same for the position.
  CONSTRAINT ex_line_station_station EXCLUDE USING gist (
    line_id WITH =, station_id WITH =, daterange(valid_from, valid_to, '[]') WITH &&),
  CONSTRAINT ex_line_station_seq EXCLUDE USING gist (
    line_id WITH =, stop_sequence WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);

CREATE TABLE IF NOT EXISTS subway.track_segment (
  track_segment_id    INTEGER GENERATED ALWAYS AS IDENTITY,
  from_station_id     INTEGER NOT NULL,
  to_station_id       INTEGER NOT NULL,
  length_m            INTEGER NOT NULL,
  in_service_date     DATE    NOT NULL,
  out_of_service_date DATE,
  CONSTRAINT pk_track_segment PRIMARY KEY (track_segment_id),
  CONSTRAINT fk_track_segment_from FOREIGN KEY (from_station_id) REFERENCES subway.station (station_id) ON DELETE RESTRICT,
  CONSTRAINT fk_track_segment_to   FOREIGN KEY (to_station_id)   REFERENCES subway.station (station_id) ON DELETE RESTRICT,
  CONSTRAINT uq_track_segment      UNIQUE (from_station_id, to_station_id, in_service_date),
  -- Type 2 (non-negative measured value): a segment has a positive length in metres.
  -- Without it a length of -100 m would corrupt every distance sum.
  CONSTRAINT chk_track_segment_length   CHECK (length_m > 0),
  CONSTRAINT chk_track_segment_stations CHECK (from_station_id <> to_station_id),
  CONSTRAINT chk_track_segment_in_service_2000 CHECK (in_service_date > DATE '2000-01-01'),
  CONSTRAINT chk_track_segment_dates    CHECK (out_of_service_date >= in_service_date)
);

CREATE TABLE IF NOT EXISTS subway.schedule_version (
  schedule_version_id      INTEGER GENERATED ALWAYS AS IDENTITY,
  line_id                  INTEGER NOT NULL,
  valid_from               DATE    NOT NULL,
  valid_to                 DATE,
  superseded_by_version_id INTEGER,
  CONSTRAINT pk_schedule_version PRIMARY KEY (schedule_version_id),
  CONSTRAINT fk_schedule_version_line FOREIGN KEY (line_id) REFERENCES subway.line (line_id) ON DELETE RESTRICT,
  -- Self-reference: a parent table that is its own parent (the row must exist before it is referenced).
  CONSTRAINT fk_schedule_version_next FOREIGN KEY (superseded_by_version_id)
    REFERENCES subway.schedule_version (schedule_version_id) ON DELETE RESTRICT,
  CONSTRAINT uq_schedule_version        UNIQUE (line_id, valid_from),
  CONSTRAINT chk_schedule_version_from_2000 CHECK (valid_from > DATE '2000-01-01'),
  CONSTRAINT chk_schedule_version_period CHECK (valid_to >= valid_from),
  CONSTRAINT chk_schedule_version_self   CHECK (superseded_by_version_id <> schedule_version_id),
  -- One line has only one timetable edition in force on any day.
  CONSTRAINT ex_schedule_version_period  EXCLUDE USING gist (
    line_id WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);

CREATE TABLE IF NOT EXISTS subway.ticket_type_station (
  ticket_type_station_id INTEGER GENERATED ALWAYS AS IDENTITY,
  ticket_type_id         INTEGER NOT NULL,
  station_id             INTEGER NOT NULL,
  can_enter              BOOLEAN NOT NULL DEFAULT TRUE,
  can_exit               BOOLEAN NOT NULL DEFAULT TRUE,
  valid_from             DATE    NOT NULL DEFAULT current_date,
  valid_to               DATE,
  CONSTRAINT pk_ticket_type_station PRIMARY KEY (ticket_type_station_id),
  CONSTRAINT fk_tts_ticket_type FOREIGN KEY (ticket_type_id) REFERENCES subway.ticket_type (ticket_type_id) ON DELETE RESTRICT,
  CONSTRAINT fk_tts_station     FOREIGN KEY (station_id)     REFERENCES subway.station (station_id)         ON DELETE RESTRICT,
  CONSTRAINT uq_tts             UNIQUE (ticket_type_id, station_id, valid_from),
  CONSTRAINT chk_tts_from_2000  CHECK (valid_from > DATE '2000-01-01'),
  CONSTRAINT chk_tts_period     CHECK (valid_to >= valid_from),
  -- One ticket type has only one entry/exit rule per station on any day.
  CONSTRAINT ex_tts_period      EXCLUDE USING gist (
    ticket_type_id WITH =, station_id WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);

CREATE TABLE IF NOT EXISTS subway.ticket_price (
  ticket_price_id INTEGER GENERATED ALWAYS AS IDENTITY,
  ticket_type_id  INTEGER        NOT NULL,
  price           NUMERIC(10, 2) NOT NULL,
  validity_hours  INTEGER        NOT NULL,
  valid_from      DATE           NOT NULL,
  valid_to        DATE,
  CONSTRAINT pk_ticket_price PRIMARY KEY (ticket_price_id),
  CONSTRAINT fk_ticket_price_type FOREIGN KEY (ticket_type_id) REFERENCES subway.ticket_type (ticket_type_id) ON DELETE RESTRICT,
  CONSTRAINT uq_ticket_price      UNIQUE (ticket_type_id, valid_from),
  -- Type 2 (non-negative measured value): a price cannot be negative (0 is allowed for free tickets).
  -- Without it a price of -20.00 would pay the passenger and distort revenue totals.
  CONSTRAINT chk_ticket_price_amount CHECK (price >= 0),
  CONSTRAINT chk_ticket_price_hours  CHECK (validity_hours > 0),
  CONSTRAINT chk_ticket_price_from_2000 CHECK (valid_from > DATE '2000-01-01'),
  CONSTRAINT chk_ticket_price_period CHECK (valid_to >= valid_from),
  -- Why EXCLUDE here: prices are versioned (a new row when the price changes). UNIQUE
  -- (ticket_type_id, valid_from) cannot stop two prices of one ticket type from overlapping, e.g.
  -- 20.00 valid 2024-01-01..2026-06-30 and 25.00 valid from 2026-01-01. A ticket bought in the
  -- overlap would match two prices: the sale has no single correct price, revenue reports and the
  -- price lookup used in the ticket INSERT would return two rows (a duplicated ticket).
  -- daterange(valid_from, valid_to, '[]') turns the two columns into one closed period (an open
  -- valid_to means "until further notice"), and && is the "periods overlap" operator.
  -- A simpler UNIQUE or CHECK cannot compare one row with other rows, so EXCLUDE (backed by a GiST
  -- index and the btree_gist extension) is the declarative way to do it; see the design note above.
  CONSTRAINT ex_ticket_price_period  EXCLUDE USING gist (
    ticket_type_id WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);

-- ---- Level 3 ---------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS subway.trip (
  trip_id             INTEGER GENERATED ALWAYS AS IDENTITY,
  schedule_version_id INTEGER     NOT NULL,
  service_pattern_id  INTEGER     NOT NULL,
  direction           VARCHAR(10) NOT NULL,
  CONSTRAINT pk_trip PRIMARY KEY (trip_id),
  CONSTRAINT fk_trip_schedule_version FOREIGN KEY (schedule_version_id)
    REFERENCES subway.schedule_version (schedule_version_id) ON DELETE RESTRICT,
  CONSTRAINT fk_trip_service_pattern  FOREIGN KEY (service_pattern_id)
    REFERENCES subway.service_pattern (service_pattern_id) ON DELETE RESTRICT,
  -- Type 3 (only specific values, like gender): direction can only be OUTBOUND or INBOUND.
  -- Without it 'outbound', 'Left' or a typo would be stored and direction filters would miss rows.
  CONSTRAINT chk_trip_direction CHECK (direction IN ('OUTBOUND', 'INBOUND'))
);

CREATE TABLE IF NOT EXISTS subway.ticket (
  -- BIGINT GENERATED ALWAYS AS IDENTITY: the highest-volume table; the id is always generated by
  -- the database and a manually typed id is rejected.
  ticket_id       BIGINT GENERATED ALWAYS AS IDENTITY,
  ticket_price_id INTEGER     NOT NULL,
  purchased_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT pk_ticket PRIMARY KEY (ticket_id),
  CONSTRAINT fk_ticket_price FOREIGN KEY (ticket_price_id)
    REFERENCES subway.ticket_price (ticket_price_id) ON DELETE RESTRICT,
  CONSTRAINT chk_ticket_purchased_2000 CHECK (purchased_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

CREATE TABLE IF NOT EXISTS subway.maintenance_work_order (
  work_order_id       INTEGER GENERATED ALWAYS AS IDENTITY,
  maintenance_type_id INTEGER     NOT NULL,
  train_id            INTEGER,
  station_id          INTEGER,
  track_segment_id    INTEGER,
  planned_start       TIMESTAMPTZ NOT NULL,
  planned_end         TIMESTAMPTZ NOT NULL,
  actual_start        TIMESTAMPTZ,
  actual_end          TIMESTAMPTZ,
  order_status        VARCHAR(20) NOT NULL DEFAULT 'PLANNED',
  note                VARCHAR(255),
  CONSTRAINT pk_maintenance_work_order PRIMARY KEY (work_order_id),
  CONSTRAINT fk_wo_type    FOREIGN KEY (maintenance_type_id) REFERENCES subway.maintenance_type (maintenance_type_id) ON DELETE RESTRICT,
  CONSTRAINT fk_wo_train   FOREIGN KEY (train_id)            REFERENCES subway.train (train_id)                       ON DELETE RESTRICT,
  CONSTRAINT fk_wo_station FOREIGN KEY (station_id)          REFERENCES subway.station (station_id)                   ON DELETE RESTRICT,
  CONSTRAINT fk_wo_segment FOREIGN KEY (track_segment_id)    REFERENCES subway.track_segment (track_segment_id)       ON DELETE RESTRICT,
  -- A work order targets exactly one asset: never two, never none.
  CONSTRAINT chk_wo_one_asset  CHECK (num_nonnulls(train_id, station_id, track_segment_id) = 1),
  CONSTRAINT chk_wo_planned_2000 CHECK (planned_start > TIMESTAMPTZ '2000-01-01 00:00:00+00'),
  CONSTRAINT chk_wo_planned    CHECK (planned_end >= planned_start),
  CONSTRAINT chk_wo_actual     CHECK (actual_end >= actual_start),
  CONSTRAINT chk_wo_actual_order CHECK (actual_end IS NULL OR actual_start IS NOT NULL),
  CONSTRAINT chk_wo_status     CHECK (order_status IN ('PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  CONSTRAINT chk_wo_status_times CHECK (
    (order_status NOT IN ('IN_PROGRESS', 'COMPLETED') OR actual_start IS NOT NULL)
    AND (order_status <> 'COMPLETED' OR actual_end IS NOT NULL))
);

-- ---- Level 4 ---------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS subway.trip_stop (
  trip_stop_id        INTEGER GENERATED ALWAYS AS IDENTITY,
  trip_id             INTEGER NOT NULL,
  line_station_id     INTEGER NOT NULL,
  scheduled_arrival   TIME    NOT NULL,
  scheduled_departure TIME    NOT NULL,
  CONSTRAINT pk_trip_stop PRIMARY KEY (trip_stop_id),
  CONSTRAINT fk_trip_stop_trip         FOREIGN KEY (trip_id)         REFERENCES subway.trip (trip_id)                 ON DELETE RESTRICT,
  CONSTRAINT fk_trip_stop_line_station FOREIGN KEY (line_station_id) REFERENCES subway.line_station (line_station_id) ON DELETE RESTRICT,
  CONSTRAINT uq_trip_stop              UNIQUE (trip_id, line_station_id),
  CONSTRAINT chk_trip_stop_times       CHECK (scheduled_departure >= scheduled_arrival)
);

CREATE TABLE IF NOT EXISTS subway.trip_run (
  trip_run_id  BIGINT GENERATED ALWAYS AS IDENTITY,
  trip_id      INTEGER     NOT NULL,
  train_id     INTEGER     NOT NULL,
  service_date DATE        NOT NULL,
  run_status   VARCHAR(20) NOT NULL DEFAULT 'PLANNED',
  CONSTRAINT pk_trip_run PRIMARY KEY (trip_run_id),
  CONSTRAINT fk_trip_run_trip  FOREIGN KEY (trip_id)  REFERENCES subway.trip (trip_id)   ON DELETE RESTRICT,
  CONSTRAINT fk_trip_run_train FOREIGN KEY (train_id) REFERENCES subway.train (train_id) ON DELETE RESTRICT,
  -- Type 4 (UNIQUE): one trip is run once per date. Without it the same trip could be registered
  -- twice on one day (double scheduling) and passenger counts would be doubled.
  CONSTRAINT uq_trip_run         UNIQUE (trip_id, service_date),
  CONSTRAINT chk_trip_run_service_2000 CHECK (service_date > DATE '2000-01-01'),
  -- Type 3 (only specific values): the status must come from the fixed list.
  CONSTRAINT chk_trip_run_status CHECK (run_status IN ('PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'))
);

-- ---- Level 5: history tables -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS subway.trip_run_status_history (
  trip_run_status_history_id BIGINT GENERATED ALWAYS AS IDENTITY,
  trip_run_id                BIGINT      NOT NULL,
  run_status                 VARCHAR(20) NOT NULL,
  changed_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT pk_trip_run_status_history PRIMARY KEY (trip_run_status_history_id),
  CONSTRAINT fk_trip_run_hist_run FOREIGN KEY (trip_run_id) REFERENCES subway.trip_run (trip_run_id) ON DELETE RESTRICT,
  CONSTRAINT uq_trip_run_hist     UNIQUE (trip_run_id, changed_at),
  CONSTRAINT chk_trip_run_hist_changed_2000 CHECK (changed_at > TIMESTAMPTZ '2000-01-01 00:00:00+00'),
  CONSTRAINT chk_trip_run_hist_status CHECK (run_status IN ('PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'))
);

CREATE TABLE IF NOT EXISTS subway.work_order_status_history (
  work_order_status_history_id BIGINT GENERATED ALWAYS AS IDENTITY,
  work_order_id                INTEGER     NOT NULL,
  order_status                 VARCHAR(20) NOT NULL,
  changed_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT pk_work_order_status_history PRIMARY KEY (work_order_status_history_id),
  CONSTRAINT fk_wo_hist_work_order FOREIGN KEY (work_order_id)
    REFERENCES subway.maintenance_work_order (work_order_id) ON DELETE RESTRICT,
  CONSTRAINT uq_wo_hist            UNIQUE (work_order_id, changed_at),
  CONSTRAINT chk_wo_hist_changed_2000 CHECK (changed_at > TIMESTAMPTZ '2000-01-01 00:00:00+00'),
  CONSTRAINT chk_wo_hist_status    CHECK (order_status IN ('PLANNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'))
);

COMMIT;

-- 2. TRIGGER RULES R1-R4 (cross-table checks that a CHECK or FK cannot express)
--
-- Why triggers at all (design decision):
--   - A CHECK constraint sees only the columns of the row being written.
--   - A FOREIGN KEY only proves that the referenced row exists, not that it is the RIGHT one.
--   So rules that compare data of different tables cannot be written declaratively:
--     R1  a trip_stop must use a line_station of the SAME line as its trip;
--     R2  a ticket must use a price that was valid on the purchase day;
--     R4  a schedule version may only be superseded by a version of the same line.
--   Alternative for R1/R4: composite foreign keys (copy line_id into trip, trip_stop and
--   schedule_version). It would work without code, but stores the same fact in several tables
--   (a 3NF violation) and was rejected. Alternative: checks in the application, which any other
--   client or manual SQL can bypass. A trigger runs inside the database for every writer.
--   R3  (status history) is needed so the history table always agrees with the current status,
--       whichever client changes it; see the comment at R3.
--   Trade-offs: a trigger costs one extra query per written row, is not fired by TRUNCATE, and
--   R2 is not re-checked if a ticket_price period is edited later. This is accepted because tickets
--   are inserted, not edited, and prices are versioned by adding rows.
--
-- The functions and triggers form one unit, so they are installed in one transaction: if one
-- statement fails, no rule is half-installed. Tables and data are not touched.
-- Rerunnable: CREATE OR REPLACE FUNCTION and DROP TRIGGER IF EXISTS + CREATE TRIGGER.
BEGIN;

-- R1: the line of the chosen line_station must equal the line of the trip.
CREATE OR REPLACE FUNCTION subway.fn_trip_stop_same_line()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM subway.trip t
    JOIN subway.schedule_version sv ON sv.schedule_version_id = t.schedule_version_id
    JOIN subway.line_station ls     ON ls.line_id = sv.line_id
    WHERE t.trip_id = NEW.trip_id
      AND ls.line_station_id = NEW.line_station_id
  ) THEN
    RAISE EXCEPTION 'R1: line_station % does not belong to the line of trip %',
      NEW.line_station_id, NEW.trip_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_trip_stop_same_line ON subway.trip_stop;
CREATE TRIGGER trg_trip_stop_same_line
  BEFORE INSERT OR UPDATE OF trip_id, line_station_id ON subway.trip_stop
  FOR EACH ROW EXECUTE FUNCTION subway.fn_trip_stop_same_line();

-- R2: a ticket can only be sold under a price that was valid on the purchase day (UTC).
CREATE OR REPLACE FUNCTION subway.fn_ticket_price_valid()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM subway.ticket_price tp
    WHERE tp.ticket_price_id = NEW.ticket_price_id
      AND (NEW.purchased_at AT TIME ZONE 'UTC')::date >= tp.valid_from
      AND (tp.valid_to IS NULL OR (NEW.purchased_at AT TIME ZONE 'UTC')::date <= tp.valid_to)
  ) THEN
    RAISE EXCEPTION 'R2: ticket_price % was not valid on %', NEW.ticket_price_id, NEW.purchased_at;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ticket_price_valid ON subway.ticket;
CREATE TRIGGER trg_ticket_price_valid
  BEFORE INSERT OR UPDATE OF ticket_price_id, purchased_at ON subway.ticket
  FOR EACH ROW EXECUTE FUNCTION subway.fn_ticket_price_valid();

-- R3: every insert and every status change is written to the status history table.
-- Why a trigger and not application code: the history must never disagree with the current status.
-- If every client had to write the history row itself, one forgotten statement (or a manual
-- UPDATE in psql) would silently change the status without a trace. The trigger makes it impossible
-- to change the status without leaving a history row.
-- Design choices:
--   - AFTER triggers: the status row is already written and valid (all CHECKs passed) when the
--     history row is created, so a rejected change never produces history.
--   - Two triggers per table: one AFTER INSERT (the first status) and one AFTER UPDATE OF status
--     with WHEN (OLD IS DISTINCT FROM NEW), so an UPDATE that does not change the status writes nothing.
--   - clock_timestamp() (not now()) gives each change its own moment even inside one transaction,
--     because now() is frozen at transaction start and two quick changes would violate
--     UNIQUE (id, changed_at).
--   - RETURN NULL: the return value of an AFTER row trigger is ignored.
CREATE OR REPLACE FUNCTION subway.fn_trip_run_status_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO subway.trip_run_status_history (trip_run_id, run_status, changed_at)
  VALUES (NEW.trip_run_id, NEW.run_status, clock_timestamp());
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_trip_run_hist_ins ON subway.trip_run;
CREATE TRIGGER trg_trip_run_hist_ins
  AFTER INSERT ON subway.trip_run
  FOR EACH ROW EXECUTE FUNCTION subway.fn_trip_run_status_history();

DROP TRIGGER IF EXISTS trg_trip_run_hist_upd ON subway.trip_run;
CREATE TRIGGER trg_trip_run_hist_upd
  AFTER UPDATE OF run_status ON subway.trip_run
  FOR EACH ROW
  WHEN (OLD.run_status IS DISTINCT FROM NEW.run_status)
  EXECUTE FUNCTION subway.fn_trip_run_status_history();

-- R3 (second table): the same design for work orders.
CREATE OR REPLACE FUNCTION subway.fn_work_order_status_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO subway.work_order_status_history (work_order_id, order_status, changed_at)
  VALUES (NEW.work_order_id, NEW.order_status, clock_timestamp());
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_wo_hist_ins ON subway.maintenance_work_order;
CREATE TRIGGER trg_wo_hist_ins
  AFTER INSERT ON subway.maintenance_work_order
  FOR EACH ROW EXECUTE FUNCTION subway.fn_work_order_status_history();

DROP TRIGGER IF EXISTS trg_wo_hist_upd ON subway.maintenance_work_order;
CREATE TRIGGER trg_wo_hist_upd
  AFTER UPDATE OF order_status ON subway.maintenance_work_order
  FOR EACH ROW
  WHEN (OLD.order_status IS DISTINCT FROM NEW.order_status)
  EXECUTE FUNCTION subway.fn_work_order_status_history();

-- R4: a schedule version can only be superseded by a version of the same line.
CREATE OR REPLACE FUNCTION subway.fn_schedule_version_same_line()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.superseded_by_version_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM subway.schedule_version sv
    WHERE sv.schedule_version_id = NEW.superseded_by_version_id
      AND sv.line_id = NEW.line_id
  ) THEN
    RAISE EXCEPTION 'R4: superseding version % belongs to another line', NEW.superseded_by_version_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_schedule_version_same_line ON subway.schedule_version;
CREATE TRIGGER trg_schedule_version_same_line
  BEFORE INSERT OR UPDATE OF line_id, superseded_by_version_id ON subway.schedule_version
  FOR EACH ROW EXECUTE FUNCTION subway.fn_schedule_version_same_line();

COMMIT;

-- 3. SAMPLE DATA (parents first; no surrogate id is typed - ids are looked up by business key)
-- Why INSERT ... SELECT instead of INSERT ... VALUES: foreign key ids are resolved by joining the
-- parent tables, so the script works on any copy of the database and a wrong business key inserts
-- nothing rather than a wrong link. Existence filters (NOT EXISTS) can also be applied to the source rows.
-- Why UPPER() on both sides of text joins: the match must not depend on the letter case of the
-- typed value ('m1' = 'M1'). Trade-off: UPPER(column) cannot use the plain unique index on that
-- column; this is accepted because the lookup tables have only a few rows. For big tables a
-- unique index on UPPER(column) or the citext type would be used instead.
-- Why no RETURNING: no later statement uses the returned ids (children are found by business key),
-- so RETURNING would only print result sets nobody reads. Row counts are checked in section 5.
-- Each block below is its own transaction: a parent and the children that depend on it are loaded
-- together; if one statement fails, that block is rolled back (nothing half-loaded) and blocks that
-- were already committed stay valid because they never depend on later blocks.

-- ---- 3.1 Level 1 reference data ---------------------------------------------------------------
BEGIN;

INSERT INTO subway.service_pattern (service_pattern_code, service_pattern_name)
SELECT v.code, v.name
FROM (VALUES
  ('WEEKDAY', 'Weekday service'),
  ('WEEKEND', 'Weekend service'),
  ('HOLIDAY', 'Public holiday service')
) AS v (code, name)
ON CONFLICT (service_pattern_code) DO NOTHING;

INSERT INTO subway.line (line_code, line_name, in_service_date)
SELECT v.code, v.name, v.in_service
FROM (VALUES
  ('M1', 'Red Line',   DATE '2020-05-01'),
  ('M2', 'Blue Line',  DATE '2022-09-01'),
  ('M3', 'Green Line', DATE '2024-06-01')
) AS v (code, name, in_service)
ON CONFLICT (line_code) DO NOTHING;

INSERT INTO subway.station (station_name, in_service_date)
SELECT v.name, v.in_service
FROM (VALUES
  ('University',     DATE '2020-05-01'),
  ('Central Square', DATE '2020-05-01'),
  ('Airport',        DATE '2020-05-01'),
  ('Old Town',       DATE '2022-09-01')
) AS v (name, in_service)
ON CONFLICT (station_name) DO NOTHING;

INSERT INTO subway.train (train_number, capacity, in_service_date)
SELECT v.number, v.capacity, v.in_service
FROM (VALUES
  ('T-101',  900, DATE '2020-04-01'),
  ('T-102',  900, DATE '2020-04-01'),
  ('T-201', 1100, DATE '2022-08-01')
) AS v (number, capacity, in_service)
ON CONFLICT (train_number) DO NOTHING;

INSERT INTO subway.ticket_type (type_name)
SELECT v.name
FROM (VALUES ('Single ride'), ('Day pass'), ('Monthly pass')) AS v (name)
ON CONFLICT (type_name) DO NOTHING;

INSERT INTO subway.maintenance_type (type_name, description, interval_days)
SELECT v.name, v.description, v.interval_days
FROM (VALUES
  ('Daily inspection',  'Visual check of doors and brakes', 1),
  ('Track inspection',  'Rail geometry and wear check',     90),
  ('Escalator service', NULL,                               NULL)
) AS v (name, description, interval_days)
ON CONFLICT (type_name) DO NOTHING;

COMMIT;

-- ---- 3.2 Network structure: line_station, track_segment ---------------------------------------
BEGIN;

INSERT INTO subway.line_station (line_id, station_id, stop_sequence, valid_from)
SELECT l.line_id, s.station_id, v.stop_sequence, v.valid_from
FROM (VALUES
  ('M1', 'University',     1, DATE '2020-05-01'),
  ('M1', 'Central Square', 2, DATE '2020-05-01'),
  ('M1', 'Airport',        3, DATE '2020-05-01'),
  ('M2', 'Central Square', 1, DATE '2022-09-01'),
  ('M2', 'Old Town',       2, DATE '2022-09-01')
) AS v (line_code, station_name, stop_sequence, valid_from)
JOIN subway.line    l ON UPPER(l.line_code)    = UPPER(v.line_code)
JOIN subway.station s ON UPPER(s.station_name) = UPPER(v.station_name)
ON CONFLICT DO NOTHING;   -- also covers the second UNIQUE and the EXCLUDE constraints

INSERT INTO subway.track_segment (from_station_id, to_station_id, length_m, in_service_date)
SELECT sf.station_id, st.station_id, v.length_m, v.in_service
FROM (VALUES
  ('University',     'Central Square', 1850, DATE '2020-05-01'),
  ('Central Square', 'University',     1850, DATE '2020-05-01'),
  ('Central Square', 'Airport',        2400, DATE '2020-05-01'),
  ('Airport',        'Central Square', 2400, DATE '2020-05-01'),
  ('Central Square', 'Old Town',       1600, DATE '2022-09-01')
) AS v (from_name, to_name, length_m, in_service)
JOIN subway.station sf ON UPPER(sf.station_name) = UPPER(v.from_name)
JOIN subway.station st ON UPPER(st.station_name) = UPPER(v.to_name)
ON CONFLICT (from_station_id, to_station_id, in_service_date) DO NOTHING;

COMMIT;

-- ---- 3.3 Timetables: schedule_version, trip, trip_stop, trip_run ------------------------------
BEGIN;

-- Self-reference: the current editions are inserted first (superseded_by = NULL), then the old
-- edition that points to them. The FK would reject a pointer to a row that does not exist yet.
INSERT INTO subway.schedule_version (line_id, valid_from, valid_to, superseded_by_version_id)
SELECT l.line_id, v.valid_from, NULL, NULL
FROM (VALUES
  ('M1', DATE '2026-03-01'),
  ('M2', DATE '2022-09-01')
) AS v (line_code, valid_from)
JOIN subway.line l ON UPPER(l.line_code) = UPPER(v.line_code)
ON CONFLICT DO NOTHING;

INSERT INTO subway.schedule_version (line_id, valid_from, valid_to, superseded_by_version_id)
SELECT l.line_id, DATE '2020-05-01', DATE '2026-02-28', nxt.schedule_version_id
FROM subway.line l
JOIN subway.schedule_version nxt ON nxt.line_id = l.line_id AND nxt.valid_from = DATE '2026-03-01'
WHERE UPPER(l.line_code) = UPPER('M1')
ON CONFLICT DO NOTHING;

-- trip has no UNIQUE key in the logical model, so duplicates are blocked with WHERE NOT EXISTS.
-- direction is stored in upper case (CHECK chk_trip_direction), so the source value is upper-cased.
INSERT INTO subway.trip (schedule_version_id, service_pattern_id, direction)
SELECT sv.schedule_version_id, sp.service_pattern_id, UPPER(v.direction)
FROM (VALUES
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'OUTBOUND'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'INBOUND'),
  ('M1', DATE '2026-03-01', 'WEEKEND', 'OUTBOUND'),
  ('M2', DATE '2022-09-01', 'WEEKDAY', 'OUTBOUND')
) AS v (line_code, version_from, pattern_code, direction)
JOIN subway.line             l  ON UPPER(l.line_code) = UPPER(v.line_code)
JOIN subway.schedule_version sv ON sv.line_id = l.line_id AND sv.valid_from = v.version_from
JOIN subway.service_pattern  sp ON UPPER(sp.service_pattern_code) = UPPER(v.pattern_code)
WHERE NOT EXISTS (
  SELECT 1
  FROM subway.trip t
  WHERE t.schedule_version_id = sv.schedule_version_id
    AND t.service_pattern_id  = sp.service_pattern_id
    AND t.direction           = UPPER(v.direction)
);

-- The stop is found through the CURRENT position of the station on the line (valid_to IS NULL);
-- trigger R1 additionally checks that the stop belongs to the line of the trip.
INSERT INTO subway.trip_stop (trip_id, line_station_id, scheduled_arrival, scheduled_departure)
SELECT t.trip_id, ls.line_station_id, v.arrival, v.departure
FROM (VALUES
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'OUTBOUND', 'University',     TIME '06:00', TIME '06:00'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'OUTBOUND', 'Central Square', TIME '06:04', TIME '06:05'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'OUTBOUND', 'Airport',        TIME '06:11', TIME '06:11'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'INBOUND',  'Airport',        TIME '07:00', TIME '07:00'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'INBOUND',  'Central Square', TIME '07:06', TIME '07:07'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'INBOUND',  'University',     TIME '07:12', TIME '07:12'),
  ('M2', DATE '2022-09-01', 'WEEKDAY', 'OUTBOUND', 'Central Square', TIME '06:30', TIME '06:30'),
  ('M2', DATE '2022-09-01', 'WEEKDAY', 'OUTBOUND', 'Old Town',       TIME '06:35', TIME '06:35')
) AS v (line_code, version_from, pattern_code, direction, station_name, arrival, departure)
JOIN subway.line             l  ON UPPER(l.line_code) = UPPER(v.line_code)
JOIN subway.schedule_version sv ON sv.line_id = l.line_id AND sv.valid_from = v.version_from
JOIN subway.service_pattern  sp ON UPPER(sp.service_pattern_code) = UPPER(v.pattern_code)
JOIN subway.trip             t  ON t.schedule_version_id = sv.schedule_version_id
                               AND t.service_pattern_id  = sp.service_pattern_id
                               AND UPPER(t.direction)    = UPPER(v.direction)
JOIN subway.station          s  ON UPPER(s.station_name) = UPPER(v.station_name)
JOIN subway.line_station     ls ON ls.line_id = l.line_id AND ls.station_id = s.station_id AND ls.valid_to IS NULL
ON CONFLICT (trip_id, line_station_id) DO NOTHING;

-- Runs are inserted with the DEFAULT status PLANNED (trigger R3 writes the first history row).
INSERT INTO subway.trip_run (trip_id, train_id, service_date)
SELECT t.trip_id, tr.train_id, v.service_date
FROM (VALUES
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'OUTBOUND', 'T-101', DATE '2026-11-13'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'INBOUND',  'T-102', DATE '2026-11-13'),
  ('M1', DATE '2026-03-01', 'WEEKDAY', 'OUTBOUND', 'T-101', DATE '2026-11-16')
) AS v (line_code, version_from, pattern_code, direction, train_number, service_date)
JOIN subway.line             l  ON UPPER(l.line_code) = UPPER(v.line_code)
JOIN subway.schedule_version sv ON sv.line_id = l.line_id AND sv.valid_from = v.version_from
JOIN subway.service_pattern  sp ON UPPER(sp.service_pattern_code) = UPPER(v.pattern_code)
JOIN subway.trip             t  ON t.schedule_version_id = sv.schedule_version_id
                               AND t.service_pattern_id  = sp.service_pattern_id
                               AND UPPER(t.direction)    = UPPER(v.direction)
JOIN subway.train            tr ON UPPER(tr.train_number) = UPPER(v.train_number)
ON CONFLICT (trip_id, service_date) DO NOTHING;

-- The two runs of 2026-11-13 are executed: PLANNED -> IN_PROGRESS -> COMPLETED. The status guards
-- make a rerun update 0 rows, so no duplicate history rows are produced.
UPDATE subway.trip_run
SET run_status = 'IN_PROGRESS'
WHERE service_date = DATE '2026-11-13'
  AND run_status = 'PLANNED';

UPDATE subway.trip_run
SET run_status = 'COMPLETED'
WHERE service_date = DATE '2026-11-13'
  AND run_status = 'IN_PROGRESS';

COMMIT;

-- ---- 3.4 Ticketing: ticket_type_station, ticket_price, ticket ----------------------------------
BEGIN;

INSERT INTO subway.ticket_type_station (ticket_type_id, station_id, can_enter, can_exit, valid_from)
SELECT tt.ticket_type_id, s.station_id, v.can_enter, v.can_exit, v.valid_from
FROM (VALUES
  ('Single ride', 'University',     TRUE, TRUE,  DATE '2020-05-01'),
  ('Single ride', 'Central Square', TRUE, TRUE,  DATE '2020-05-01'),
  ('Single ride', 'Airport',        TRUE, TRUE,  DATE '2020-05-01'),
  ('Day pass',    'Central Square', TRUE, TRUE,  DATE '2020-05-01'),
  ('Day pass',    'Airport',        TRUE, FALSE, DATE '2020-05-01')
) AS v (type_name, station_name, can_enter, can_exit, valid_from)
JOIN subway.ticket_type tt ON UPPER(tt.type_name)   = UPPER(v.type_name)
JOIN subway.station     s  ON UPPER(s.station_name) = UPPER(v.station_name)
ON CONFLICT DO NOTHING;

-- Prices are versions: the old single-ride price is closed (valid_to), the new one starts next day.
INSERT INTO subway.ticket_price (ticket_type_id, price, validity_hours, valid_from, valid_to)
SELECT tt.ticket_type_id, v.price, v.validity_hours, v.valid_from, v.valid_to
FROM (VALUES
  ('Single ride',  20.00,   2, DATE '2024-01-01', DATE '2025-12-31'),
  ('Single ride',  25.00,   2, DATE '2026-01-01', NULL::date),
  ('Day pass',     80.00,  24, DATE '2026-01-01', NULL::date),
  ('Monthly pass', 900.00, 720, DATE '2026-01-01', NULL::date)
) AS v (type_name, price, validity_hours, valid_from, valid_to)
JOIN subway.ticket_type tt ON UPPER(tt.type_name) = UPPER(v.type_name)
ON CONFLICT DO NOTHING;

-- The price row is found by the purchase date, so a ticket always gets the price valid that day
-- (trigger R2 double-checks it). The 2025 ticket keeps the old price after the increase.
INSERT INTO subway.ticket (ticket_price_id, purchased_at)
SELECT tp.ticket_price_id, v.purchased_at
FROM (VALUES
  ('Single ride', TIMESTAMPTZ '2025-06-10 12:00:00+00'),
  ('Single ride', TIMESTAMPTZ '2026-11-13 08:15:30+00'),
  ('Single ride', TIMESTAMPTZ '2026-11-13 08:17:02+00'),
  ('Day pass',    TIMESTAMPTZ '2026-11-13 09:40:11+00')
) AS v (type_name, purchased_at)
JOIN subway.ticket_type  tt ON UPPER(tt.type_name) = UPPER(v.type_name)
JOIN subway.ticket_price tp ON tp.ticket_type_id = tt.ticket_type_id
                           AND (v.purchased_at AT TIME ZONE 'UTC')::date
                               BETWEEN tp.valid_from AND COALESCE(tp.valid_to, DATE 'infinity')
WHERE NOT EXISTS (
  SELECT 1
  FROM subway.ticket t
  WHERE t.ticket_price_id = tp.ticket_price_id
    AND t.purchased_at    = v.purchased_at
);

COMMIT;

-- ---- 3.5 Maintenance: maintenance_work_order (+ history by trigger R3) --------------------------
BEGIN;

-- One statement for the three asset kinds: LEFT JOINs leave the two unused asset columns NULL,
-- and CHECK chk_wo_one_asset guarantees exactly one is filled.
INSERT INTO subway.maintenance_work_order
  (maintenance_type_id, train_id, station_id, track_segment_id, planned_start, planned_end, note)
SELECT mt.maintenance_type_id, tr.train_id, st.station_id, sg.track_segment_id,
       v.planned_start, v.planned_end, v.note
FROM (VALUES
  ('Daily inspection',  'T-101',        NULL::varchar,    NULL::varchar,    NULL::varchar,
     TIMESTAMPTZ '2026-11-14 01:00:00+00', TIMESTAMPTZ '2026-11-14 03:00:00+00', 'No faults found'),
  ('Track inspection',  NULL::varchar,  NULL::varchar,    'Central Square', 'Airport',
     TIMESTAMPTZ '2026-11-18 00:30:00+00', TIMESTAMPTZ '2026-11-18 04:30:00+00', NULL::varchar),
  ('Escalator service', NULL::varchar,  'Central Square', NULL::varchar,    NULL::varchar,
     TIMESTAMPTZ '2026-11-15 02:00:00+00', TIMESTAMPTZ '2026-11-15 05:00:00+00', NULL::varchar)
) AS v (type_name, train_number, station_name, seg_from, seg_to, planned_start, planned_end, note)
JOIN subway.maintenance_type mt ON UPPER(mt.type_name) = UPPER(v.type_name)
LEFT JOIN subway.train       tr  ON UPPER(tr.train_number)  = UPPER(v.train_number)
LEFT JOIN subway.station     st  ON UPPER(st.station_name)  = UPPER(v.station_name)
LEFT JOIN subway.station     sf  ON UPPER(sf.station_name)  = UPPER(v.seg_from)
LEFT JOIN subway.station     sto ON UPPER(sto.station_name) = UPPER(v.seg_to)
LEFT JOIN subway.track_segment sg ON sg.from_station_id = sf.station_id AND sg.to_station_id = sto.station_id
WHERE NOT EXISTS (
  SELECT 1
  FROM subway.maintenance_work_order w
  WHERE w.maintenance_type_id = mt.maintenance_type_id
    AND w.planned_start       = v.planned_start
    AND w.train_id            IS NOT DISTINCT FROM tr.train_id
    AND w.station_id          IS NOT DISTINCT FROM st.station_id
    AND w.track_segment_id    IS NOT DISTINCT FROM sg.track_segment_id
);

-- Status flow (status and the actual times must change together because of chk_wo_status_times).
-- The WHERE guards make reruns update 0 rows.
UPDATE subway.maintenance_work_order w
SET order_status = 'IN_PROGRESS',
    actual_start = w.planned_start + INTERVAL '5 minutes'
FROM subway.maintenance_type mt
WHERE mt.maintenance_type_id = w.maintenance_type_id
  AND UPPER(mt.type_name) IN (UPPER('Daily inspection'), UPPER('Escalator service'))
  AND w.order_status = 'PLANNED';

UPDATE subway.maintenance_work_order w
SET order_status = 'COMPLETED',
    actual_end   = w.planned_end - INTERVAL '10 minutes'
FROM subway.maintenance_type mt
WHERE mt.maintenance_type_id = w.maintenance_type_id
  AND UPPER(mt.type_name) = UPPER('Daily inspection')
  AND w.order_status = 'IN_PROGRESS';

COMMIT;

-- 4. record_ts: NOT NULL, DEFAULT current_date, added to every table with ALTER TABLE
-- Separate transaction: all 18 tables get the column together, so the model is never half-audited.
-- If it fails: no column is added and the data is unchanged. ROLLBACK is possible before COMMIT.
-- How it works: ADD COLUMN ... NOT NULL DEFAULT current_date fills every EXISTING row with the
-- default at the moment of the ALTER, so NOT NULL is satisfied. IF NOT EXISTS makes a rerun a no-op.
BEGIN;

ALTER TABLE subway.service_pattern            ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.line                       ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.station                    ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.line_station               ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.track_segment              ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.train                      ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.schedule_version           ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.trip                       ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.trip_stop                  ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.trip_run                   ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.trip_run_status_history    ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.ticket_type                ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.ticket_type_station        ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.ticket_price               ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.ticket                     ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.maintenance_type           ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.maintenance_work_order     ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;
ALTER TABLE subway.work_order_status_history  ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT current_date;

COMMIT;

-- 5. CHECKS
-- 5.1 record_ts is set for every existing row: null_record_ts must be 0 in every line,
--     and total_rows must be >= 2 per table (20+ in total).
SELECT 'service_pattern' AS table_name, COUNT(*) AS total_rows, COUNT(*) FILTER (WHERE record_ts IS NULL) AS null_record_ts FROM subway.service_pattern
UNION ALL SELECT 'line',                       COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.line
UNION ALL SELECT 'station',                    COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.station
UNION ALL SELECT 'line_station',               COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.line_station
UNION ALL SELECT 'track_segment',              COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.track_segment
UNION ALL SELECT 'train',                      COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.train
UNION ALL SELECT 'schedule_version',           COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.schedule_version
UNION ALL SELECT 'trip',                       COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.trip
UNION ALL SELECT 'trip_stop',                  COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.trip_stop
UNION ALL SELECT 'trip_run',                   COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.trip_run
UNION ALL SELECT 'trip_run_status_history',    COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.trip_run_status_history
UNION ALL SELECT 'ticket_type',                COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.ticket_type
UNION ALL SELECT 'ticket_type_station',        COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.ticket_type_station
UNION ALL SELECT 'ticket_price',               COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.ticket_price
UNION ALL SELECT 'ticket',                     COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.ticket
UNION ALL SELECT 'maintenance_type',           COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.maintenance_type
UNION ALL SELECT 'maintenance_work_order',     COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.maintenance_work_order
UNION ALL SELECT 'work_order_status_history',  COUNT(*), COUNT(*) FILTER (WHERE record_ts IS NULL) FROM subway.work_order_status_history;

-- 5.2 Relationship check: every trip_run shows its line, pattern, direction, train and status.
SELECT l.line_code, sp.service_pattern_code, t.direction, tr.service_date, trn.train_number, tr.run_status
FROM subway.trip_run tr
JOIN subway.trip             t   ON t.trip_id = tr.trip_id
JOIN subway.schedule_version sv  ON sv.schedule_version_id = t.schedule_version_id
JOIN subway.line             l   ON l.line_id = sv.line_id
JOIN subway.service_pattern  sp  ON sp.service_pattern_id = t.service_pattern_id
JOIN subway.train            trn ON trn.train_id = tr.train_id
ORDER BY tr.service_date, l.line_code, t.direction;
