

DROP TABLE IF EXISTS public.table_to_delete;
CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;


SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS index,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS table
FROM ( SELECT *, total_bytes-index_bytes-COALESCE(toast_bytes,0) AS table_bytes
       FROM (SELECT c.oid, nspname AS table_schema, relname AS table_name,
                    c.reltuples AS row_estimate,
                    pg_total_relation_size(c.oid) AS total_bytes,
                    pg_indexes_size(c.oid) AS index_bytes,
                    pg_total_relation_size(reltoastrelid) AS toast_bytes
             FROM pg_class c
             LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE relkind = 'r') a ) a
WHERE table_name LIKE '%table_to_delete%';
-- 575 MB

-- 3a. 
DELETE FROM public.table_to_delete
WHERE REPLACE(col,'veeeeeeery_long_string','')::int % 3 = 0;
-- 23 s

-- 3b.
-- 575 MB 

-- 3c. 
VACUUM FULL VERBOSE public.table_to_delete;

-- 3d. 
--383 MB

-- 3e.
DROP TABLE IF EXISTS public.table_to_delete;
CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;

-- 4a. 
TRUNCATE public.table_to_delete;
-- 0.105 s

-- 4c.
--  0 bytes

/* 5. CONCLUSIONS
   Time:        DELETE slow (row by row); TRUNCATE near-instant.
   Disk space:  DELETE frees nothing (dead tuples stay, MVCC); VACUUM FULL
                rewrites table with live rows only;
                TRUNCATE replaces the data file so it has 0 bytes immediately.
   Transaction: DELETE = row locks, supports WHERE, fires row triggers;
                TRUNCATE = ACCESS EXCLUSIVE lock, whole table only.
   Rollback:    possible for both inside an open transaction (PostgreSQL
                TRUNCATE is transactional); not after COMMIT/autocommit.
   Why DELETE doesn't free space: rows are only marked dead since
                other snapshots/rollback may need them; space is reusable
                after VACUUM but not returned to the OS.
   Why VACUUM FULL shrinks: copies live tuples to a new file, drops old one.
   Why TRUNCATE differs: works on the file, not on rows.
   Performance: bloat makes scans read dead rows; use DELETE for partial
                removal, TRUNCATE to empty a table. */


BEGIN;
  TRUNCATE public.table_to_delete;
ROLLBACK;