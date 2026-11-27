-- Task 2: how DELETE, VACUUM FULL and TRUNCATE affect time and table size.
-- Plan: create a big table -> delete 1/3 of the rows -> shrink it with VACUUM FULL ->
-- recreate it -> TRUNCATE it -> compare. The size query below is re-run after every step.

-- Reusable size query (run after steps 2, 3a, 3c, 3e and 4a):
--   pg_relation_size       = table data file only
--   pg_total_relation_size = table + indexes + TOAST
--   SELECT pg_size_pretty(pg_relation_size('public.table_to_delete'))       AS table_only,
--          pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total,
--          (SELECT count(*) FROM public.table_to_delete)                    AS row_count;

-- 1. Create a test table with 10 million rows (rerunnable thanks to DROP IF EXISTS).
--    Each row is a long text value, so the table is big enough (hundreds of MB) to see size changes.
DROP TABLE IF EXISTS public.table_to_delete;
CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;

-- 2. Size of the new table (starting point).
SELECT pg_size_pretty(pg_relation_size('public.table_to_delete'))       AS table_only,
       pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total,
       (SELECT count(*) FROM public.table_to_delete)                    AS row_count;
-- Result: 575 MB, 10 000 000 rows

-- 3a. DELETE every 3rd row (about 3.33 million rows).
--     The numeric part of the string is extracted with REPLACE and cast to int.
--     DELETE visits every row, marks the matching ones as dead and writes each change to WAL.
DELETE FROM public.table_to_delete
WHERE REPLACE(col,'veeeeeeery_long_string','')::int % 3 = 0;
-- Time: 23 s

-- 3b. Size right after DELETE (run the size query again).
SELECT pg_size_pretty(pg_relation_size('public.table_to_delete'))       AS table_only,
       pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total,
       (SELECT count(*) FROM public.table_to_delete)                    AS row_count;
-- Result: 575 MB, unchanged; row_count is about 6 666 667.
-- DELETE only marks tuples as dead (MVCC), because other transactions may still need to see them,
-- so the file does not shrink.

-- 3c. VACUUM FULL rewrites the table into a new file containing only live rows.
--     It takes an ACCESS EXCLUSIVE lock (nobody can read the table meanwhile) and needs free disk
--     space for the new copy, so it is a maintenance command, not a normal cleanup.
VACUUM FULL VERBOSE public.table_to_delete;

-- 3d. Size after VACUUM FULL (run the size query again).
SELECT pg_size_pretty(pg_relation_size('public.table_to_delete'))       AS table_only,
       pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total,
       (SELECT count(*) FROM public.table_to_delete)                    AS row_count;
-- Result: 383 MB (about 2/3 of the original, since 1/3 of the rows were deleted).

-- 3e. Recreate the table with the same data, so the TRUNCATE test starts from the same point
--     as the DELETE test (same size, same row count).
DROP TABLE IF EXISTS public.table_to_delete;
CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;

-- Size after recreation (run the size query again).
SELECT pg_size_pretty(pg_relation_size('public.table_to_delete'))       AS table_only,
       pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total,
       (SELECT count(*) FROM public.table_to_delete)                    AS row_count;
-- Result: 575 MB, 10 000 000 rows (same as in step 2, as expected: the same data was loaded again).

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

-- 4b. Comparison DELETE vs TRUNCATE (numbers are the ones measured above).
--   What it does:  DELETE removes the rows that match WHERE, one by one.
--                  TRUNCATE removes ALL rows at once by replacing the table's data file.
--   Time:          DELETE: 23 s for only 1/3 of the rows (checks each row, writes WAL per row).
--                  TRUNCATE: 0.105 s for ALL rows (no row-by-row work); about 200 times faster
--                  even though it removed three times more rows.
--   Space:         DELETE: the table stays 575 MB (dead tuples remain) until VACUUM FULL, which
--                  then gives 383 MB for the remaining 2/3 of the rows.
--                  TRUNCATE: space is released immediately, table part 0 bytes, no VACUUM needed.
--   WHERE:         DELETE can remove only some rows; TRUNCATE cannot, it is all or nothing.
--   Triggers:      DELETE fires row-level triggers; TRUNCATE does not fire them (only
--                  TRUNCATE triggers).
--   Locks:         DELETE takes row locks and other sessions can still read the table;
--                  TRUNCATE takes an ACCESS EXCLUSIVE lock for the whole table.
--   Rollback:      both can be rolled back inside an open transaction; after COMMIT neither can.
--   Use:           DELETE for removing part of the data; TRUNCATE to empty a table completely.

-- 4c. Size after TRUNCATE (run the size query again).
SELECT pg_size_pretty(pg_relation_size('public.table_to_delete'))       AS table_only,
       pg_size_pretty(pg_total_relation_size('public.table_to_delete')) AS total,
       (SELECT count(*) FROM public.table_to_delete)                    AS row_count;
-- Result: table part 0 bytes, total 8 kB (the empty TOAST table / its index still occupy
-- pages, so the total is not exactly 0), 0 rows.

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
