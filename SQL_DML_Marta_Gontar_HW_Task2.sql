

-- 1. Create a test table with 10 million rows (rerunnable thanks to DROP IF EXISTS)
DROP TABLE IF EXISTS public.table_to_delete;
CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;

-- 2. Check the table size (re-run this query after every step below).
--    pg_relation_size = table data file only; pg_total_relation_size = table + indexes + TOAST
SELECT pg_size_pretty(pg_relation_size('public.table_to_delete'))       AS table_only,
       pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total,
       (SELECT count(*) FROM public.table_to_delete)                    AS row_count;
-- Result: 575 MB, 10 000 000 rows

-- 3a. DELETE every 3rd row (about 3.33 million rows).
--     The numeric part of the string is extracted with REPLACE and cast to int.
DELETE FROM public.table_to_delete
WHERE REPLACE(col,'veeeeeeery_long_string','')::int % 3 = 0;
-- Time: 23 s

-- 3b. Size right after DELETE.
--     Result: 575 MB, unchanged. DELETE only marks tuples as dead (MVCC),
--     the file does not shrink.

-- 3c. VACUUM FULL rewrites the table into a new file containing only live rows.
VACUUM FULL VERBOSE public.table_to_delete;

-- 3d. Size after VACUUM FULL.
--     Result: 383 MB (about 2/3 of the original, since 1/3 of the rows were deleted).

-- 3e. Recreate the table with the same data to start the TRUNCATE test from the same point.
DROP TABLE IF EXISTS public.table_to_delete;
CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;

-- Size after recreation .
-- Result: 575 MB (same as in step 2, as expected: the same data was loaded again)

-- Demo: TRUNCATE is transactional in PostgreSQL.
-- Inside the transaction the table is empty (count = 0); after ROLLBACK all
-- 10 000 000 rows are back. This works because TRUNCATE creates a new empty file
-- and keeps the old one until COMMIT; ROLLBACK simply discards the new file.
BEGIN;
  TRUNCATE public.table_to_delete;
  SELECT count(*) FROM public.table_to_delete;   -- 0
ROLLBACK;
SELECT count(*) FROM public.table_to_delete;     -- 10 000 000 again

-- 4a. TRUNCATE the whole table (this time committed).
TRUNCATE public.table_to_delete;
-- Time: 0.105 s

-- 4b. Comparison DELETE vs TRUNCATE
--   Time:      DELETE 23 s for only 1/3 of the rows (visits each row, writes WAL per row);
--              TRUNCATE 0.105 s for ALL rows (swaps the data file, no row-by-row work).
--   Space:     DELETE: table stays 575 MB until VACUUM FULL, which then gives 383 MB;
--              TRUNCATE: space is released immediately, no VACUUM needed.
--   Features:  DELETE supports WHERE and fires row-level triggers, takes row locks;
--              TRUNCATE removes everything, no WHERE, takes ACCESS EXCLUSIVE lock.

-- 4c. Size after TRUNCATE (re-run the size query from step 2).
--     Table part: 0 bytes. Total: 8 kB (the empty TOAST table / its index still occupy
--     pages, so the total is not exactly 0).

/* 5. CONCLUSIONS
   Time:        DELETE slow (row by row); TRUNCATE near-instant.
   Disk space:  DELETE frees nothing (dead tuples stay, MVCC); VACUUM FULL
                rewrites table with live rows only;
                TRUNCATE replaces the data file so the table part is 0 bytes immediately
                (8 kB total including auxiliary TOAST pages).
   Transaction: DELETE = row locks, supports WHERE, fires row triggers;
                TRUNCATE = ACCESS EXCLUSIVE lock, whole table only.
   Rollback:    possible for both inside an open transaction (PostgreSQL
                TRUNCATE is transactional, shown in the BEGIN/ROLLBACK demo);
                not after COMMIT/autocommit.
   Why DELETE doesn't free space: rows are only marked dead since
                other snapshots/rollback may need them; space is reusable
                after VACUUM but not returned to the OS.
   Why VACUUM FULL shrinks: copies live tuples to a new file, drops old one.
   Why TRUNCATE differs: works on the file, not on rows.
   Performance: bloat makes scans read dead rows; use DELETE for partial
                removal, TRUNCATE to empty a table. */
