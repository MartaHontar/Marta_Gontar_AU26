-- Task 1 (DML): add 3 favourite films with actors, put them in inventory, change an existing
-- customer into "me", delete that customer's old rental/payment history, then rent and pay for
-- the 3 films. Every step is a separate transaction and can be rerun.

-- 0. Choosing the customer (read-only, nothing is written).
-- The task needs a customer who has at least 43 rentals and 43 payments, because their old
-- history is deleted later and the customer must be a real, active one. This query lists the
-- first 5 such customers. The steps below always take the one with the LOWEST customer_id
-- (ORDER BY customer_id LIMIT 1), i.e. the first row of this list. Correlated COUNT subqueries
-- are used so rentals and payments are counted separately (a JOIN of both would multiply rows).
SELECT c.customer_id, c.first_name, c.last_name,
       (SELECT COUNT(*) FROM public.rental  r WHERE r.customer_id = c.customer_id) AS rentals,
       (SELECT COUNT(*) FROM public.payment p WHERE p.customer_id = c.customer_id) AS payments
FROM public.customer c
WHERE (SELECT COUNT(*) FROM public.rental  r WHERE r.customer_id = c.customer_id) >= 43
  AND (SELECT COUNT(*) FROM public.payment p WHERE p.customer_id = c.customer_id) >= 43
ORDER BY c.customer_id
LIMIT 5;

-- 1. Films and their categories
BEGIN;
-- Separate transaction: the 3 films are one logical unit. All are added or none.
-- If it fails: PostgreSQL aborts the transaction and nothing is written.
--   ROLLBACK is possible; only these uncommitted film rows are affected.
-- Referential integrity: language_id is looked up from public.language by name,
--   so the FK film.language_id -> language is always valid.
-- Uniqueness: WHERE NOT EXISTS on the title, so reruns insert 0 rows.
-- Why INSERT ... SELECT instead of VALUES: IDs are resolved from the data itself, so the
--   script works on any copy of the DB, and filters like NOT EXISTS can be applied to source rows.
INSERT INTO public.film
      (title, description, release_year, language_id, rental_duration,
       rental_rate, length, replacement_cost, rating, last_update)
SELECT v.title, v.description, v.release_year, l.language_id, v.rental_duration,
       v.rental_rate, v.length, v.replacement_cost, v.rating::public.mpaa_rating, current_date
FROM (VALUES
  ('THE ODYSSEY',
   'Christopher Nolan''s epic adaptation of Homer''s journey of Odysseus returning home from the Trojan War.',
   2026, 7,  4.99, 170, 19.99, 'PG-13'),
  ('CLICK',
   'An overworked architect finds a universal remote that lets him fast-forward through his own life.',
   2006, 14, 9.99, 107, 19.99, 'PG-13'),
  ('THE TRUMAN SHOW',
   'An insurance salesman slowly discovers that his whole life is a TV show watched by millions.',
   1998, 21, 19.99, 103, 19.99, 'PG')
) AS v(title, description, release_year, rental_duration, rental_rate, length, replacement_cost, rating)
CROSS JOIN (SELECT language_id FROM public.language WHERE name = 'English' LIMIT 1) l
WHERE NOT EXISTS (SELECT 1 FROM public.film f WHERE UPPER(f.title) = v.title)
RETURNING film_id, title, release_year, rental_duration, rental_rate;

-- Category of each film (film_category is the link table film <-> category).
-- ON CONFLICT on the primary key (film_id, category_id) makes the rerun insert nothing.
INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT f.film_id, c.category_id, current_date
FROM (VALUES ('THE ODYSSEY','Action'), ('CLICK','Comedy'), ('THE TRUMAN SHOW','Drama')) v(title, cat)
JOIN public.film f     ON UPPER(f.title) = v.title
JOIN public.category c ON c.name = v.cat
ON CONFLICT (film_id, category_id) DO NOTHING
RETURNING film_id, category_id;
COMMIT;

-- 2. Actors and the film_actor links
BEGIN;
-- Separate transaction: actors and their film links belong together,
--   so no actor is left without a film.
-- If it fails: everything in this block is undone; films from step 1 stay intact.
--   ROLLBACK is possible and only affects actor/film_actor rows of this block.
-- Duplicate detection: "actor" has no natural unique key, so an actor already exists if
--   UPPER(first_name) + UPPER(last_name) match. Existing actors are reused, never duplicated.
-- Relationships: film_actor gets actor_id and film_id via JOINs on names/titles, so the FKs
--   are valid because the IDs come from the parent tables.
INSERT INTO public.actor (first_name, last_name, last_update)
SELECT v.fn, v.ln, current_date
FROM (VALUES
  ('MATT','DAMON'), ('TOM','HOLLAND'), ('ANNE','HATHAWAY'),
  ('ADAM','SANDLER'), ('KATE','BECKINSALE'), ('CHRISTOPHER','WALKEN'),
  ('JIM','CARREY'), ('LAURA','LINNEY'), ('ED','HARRIS')
) AS v(fn, ln)
WHERE NOT EXISTS (SELECT 1 FROM public.actor a
                  WHERE UPPER(a.first_name) = v.fn AND UPPER(a.last_name) = v.ln)
RETURNING actor_id, first_name, last_name;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT a.actor_id, f.film_id, current_date
FROM (VALUES
  ('THE ODYSSEY','MATT','DAMON'), ('THE ODYSSEY','TOM','HOLLAND'), ('THE ODYSSEY','ANNE','HATHAWAY'),
  ('CLICK','ADAM','SANDLER'), ('CLICK','KATE','BECKINSALE'), ('CLICK','CHRISTOPHER','WALKEN'),
  ('THE TRUMAN SHOW','JIM','CARREY'), ('THE TRUMAN SHOW','LAURA','LINNEY'), ('THE TRUMAN SHOW','ED','HARRIS')
) AS v(title, fn, ln)
JOIN public.film  f ON UPPER(f.title) = v.title
JOIN public.actor a ON UPPER(a.first_name) = v.fn AND UPPER(a.last_name) = v.ln
ON CONFLICT (actor_id, film_id) DO NOTHING
RETURNING actor_id, film_id;
COMMIT;

-- 3. Change the chosen customer into my data
BEGIN;
-- Separate transaction: the identity change must be atomic (name, email, address together).
-- If it fails: the customer keeps their old data. ROLLBACK is possible; only one customer row is affected.
-- Address: an existing address_id is reused; public.address is NOT modified.
--   The address is a REAL customer address: it is already used by a customer and is not the
--   address of a store or of a staff member (MIN(address_id) would give address 1,
--   "47 MySakila Drive", which is store 1's own address). Addresses in Ukraine are preferred
--   (ORDER BY country = 'Ukraine' DESC); if the database has none, the lowest customer
--   address_id is used, so the UPDATE never gets a NULL address.
-- Rerun safety: NOT EXISTS on my email skips the update once it has been done.
-- Integrity: address_id comes from address, and customer_id stays the same,
--   so all child rows (rental/payment) still point to the same customer.
-- Preview of the row that will change (check before COMMIT):
SELECT customer_id, first_name, last_name, email, address_id
FROM public.customer c
WHERE (SELECT COUNT(*) FROM public.rental  r WHERE r.customer_id = c.customer_id) >= 43
  AND (SELECT COUNT(*) FROM public.payment p WHERE p.customer_id = c.customer_id) >= 43
ORDER BY customer_id LIMIT 1;

UPDATE public.customer c
SET first_name  = 'MARTA',
    last_name   = 'GONTAR',
    email       = 'mhontar@kse.org.ua',
    address_id  = (SELECT a.address_id
                   FROM public.address a
                   JOIN public.city    ci ON ci.city_id    = a.city_id
                   JOIN public.country co ON co.country_id = ci.country_id
                   WHERE EXISTS (SELECT 1 FROM public.customer cu WHERE cu.address_id = a.address_id)
                     AND a.address_id NOT IN (SELECT s.address_id  FROM public.store s)
                     AND a.address_id NOT IN (SELECT st.address_id FROM public.staff st)
                   ORDER BY (co.country = 'Ukraine') DESC, a.address_id
                   LIMIT 1),
    last_update = current_date
WHERE c.customer_id = (
        SELECT c2.customer_id FROM public.customer c2
        WHERE (SELECT COUNT(*) FROM public.rental  r WHERE r.customer_id = c2.customer_id) >= 43
          AND (SELECT COUNT(*) FROM public.payment p WHERE p.customer_id = c2.customer_id) >= 43
        ORDER BY c2.customer_id LIMIT 1)
  AND NOT EXISTS (SELECT 1 FROM public.customer x WHERE x.email = 'mhontar@kse.org.ua')
RETURNING customer_id, first_name, last_name, email, address_id, store_id, last_update;
COMMIT;

-- 4. Inventory
BEGIN;
-- Separate transaction: inventory is a standalone unit of work (stock must exist before rentals).
-- If it fails: no stock is added, and step 6 inserts nothing because it finds no inventory.
--   ROLLBACK is possible; only these inventory rows are affected.
-- Store: resolved from customer.store_id (by email), not hardcoded.
-- Uniqueness: WHERE NOT EXISTS (film_id + store_id) means one copy per film per store.
-- Integrity: film_id and store_id come from the parent tables, so the FKs are valid.
INSERT INTO public.inventory (film_id, store_id, last_update)
SELECT f.film_id, c.store_id, current_date
FROM public.film f
CROSS JOIN public.customer c
WHERE c.email = 'mhontar@kse.org.ua'
  AND UPPER(f.title) IN ('THE ODYSSEY','CLICK','THE TRUMAN SHOW')
  AND NOT EXISTS (SELECT 1 FROM public.inventory i
                  WHERE i.film_id = f.film_id AND i.store_id = c.store_id)
RETURNING inventory_id, film_id, store_id;
COMMIT;

-- 5. Delete the old rental/payment history of my customer
BEGIN;
-- Separate transaction: a destructive operation is isolated so it can be rolled back on its own.
-- If it fails: nothing is deleted. Before COMMIT, ROLLBACK restores everything;
--   after COMMIT it cannot be undone, which is why the previews come first.
-- Why safe: only rows with customer_id = MY customer are touched (found by email, never by
--   hardcoded ID). Customer and Inventory rows are NOT deleted. Payments are deleted before
--   rentals (child before parent), so there are no FK violations.
-- No unintended loss: the WHERE excludes rentals of my 3 films, so a rerun does not wipe
--   the rentals created in step 6.
-- Preview (expect roughly 43+ each on the first run):
SELECT 'payment' AS tbl, COUNT(*) FROM public.payment p
 JOIN public.customer c ON c.customer_id = p.customer_id AND c.email = 'mhontar@kse.org.ua'
 WHERE p.rental_id IS NULL OR p.rental_id NOT IN (
        SELECT r.rental_id FROM public.rental r
        JOIN public.inventory i ON i.inventory_id = r.inventory_id
        JOIN public.film f ON f.film_id = i.film_id
        WHERE UPPER(f.title) IN ('THE ODYSSEY','CLICK','THE TRUMAN SHOW'))
UNION ALL
SELECT 'rental', COUNT(*) FROM public.rental r
 JOIN public.customer c ON c.customer_id = r.customer_id AND c.email = 'mhontar@kse.org.ua'
 WHERE r.inventory_id NOT IN (
        SELECT i.inventory_id FROM public.inventory i
        JOIN public.film f ON f.film_id = i.film_id
        WHERE UPPER(f.title) IN ('THE ODYSSEY','CLICK','THE TRUMAN SHOW'));

DELETE FROM public.payment p
USING public.customer c
WHERE c.customer_id = p.customer_id
  AND c.email = 'mhontar@kse.org.ua'
  AND (p.rental_id IS NULL OR p.rental_id NOT IN (
        SELECT r.rental_id FROM public.rental r
        JOIN public.inventory i ON i.inventory_id = r.inventory_id
        JOIN public.film f ON f.film_id = i.film_id
        WHERE UPPER(f.title) IN ('THE ODYSSEY','CLICK','THE TRUMAN SHOW')))
RETURNING p.payment_id, p.customer_id, p.rental_id;

DELETE FROM public.rental r
USING public.customer c
WHERE c.customer_id = r.customer_id
  AND c.email = 'mhontar@kse.org.ua'
  AND r.inventory_id NOT IN (
        SELECT i.inventory_id FROM public.inventory i
        JOIN public.film f ON f.film_id = i.film_id
        WHERE UPPER(f.title) IN ('THE ODYSSEY','CLICK','THE TRUMAN SHOW'))
RETURNING r.rental_id, r.customer_id, r.inventory_id;
COMMIT;

-- 6. Rent and pay for the 3 films
BEGIN;
-- Separate transaction: a rental and its payment must be created together,
--   otherwise there would be rentals without payment.
-- If it fails: both inserts are rolled back, leaving no half-finished state.
--   ROLLBACK is possible and only affects rental/payment rows of this block.
-- Relationships: inventory_id comes from inventory (film in my store), customer_id from customer,
--   staff_id from a staff member of the same store, payment.rental_id from the rental just created.
-- Uniqueness: rentals are guarded by NOT EXISTS (inventory + customer + rental_date),
--   which matches the table's unique index; payments by NOT EXISTS on rental_id.
-- Amount = the film's rental_rate (4.99 / 9.99 / 19.99). Dates are in H1 2017, which fits
--   the payment partitions. If one is missing, create it first, e.g.:
--   CREATE TABLE IF NOT EXISTS public.payment_p2017_02 PARTITION OF public.payment
--     FOR VALUES FROM ('2017-02-01') TO ('2017-03-01');   -- likewise for 03 and 04
INSERT INTO public.rental (rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT v.rental_date, i.inventory_id, c.customer_id,
       v.rental_date + f.rental_duration * INTERVAL '1 day',
       s.staff_id, current_date
FROM (VALUES
  ('THE TRUMAN SHOW', TIMESTAMP '2017-02-10 10:00:00'),
  ('CLICK',           TIMESTAMP '2017-03-12 15:30:00'),
  ('THE ODYSSEY',     TIMESTAMP '2017-04-05 19:45:00')
) AS v(title, rental_date)
JOIN public.film      f ON UPPER(f.title) = v.title
JOIN public.customer  c ON c.email = 'mhontar@kse.org.ua'
JOIN public.inventory i ON i.film_id = f.film_id AND i.store_id = c.store_id
JOIN LATERAL (SELECT st.staff_id FROM public.staff st
              WHERE st.store_id = i.store_id ORDER BY st.staff_id LIMIT 1) s ON TRUE
WHERE NOT EXISTS (SELECT 1 FROM public.rental r
                  WHERE r.inventory_id = i.inventory_id
                    AND r.customer_id  = c.customer_id
                    AND r.rental_date  = v.rental_date)
RETURNING rental_id, rental_date, inventory_id, customer_id, staff_id, return_date;

INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
SELECT r.customer_id, r.staff_id, r.rental_id, f.rental_rate, r.rental_date + INTERVAL '5 minutes'
FROM public.rental r
JOIN public.customer  c ON c.customer_id = r.customer_id AND c.email = 'mhontar@kse.org.ua'
JOIN public.inventory i ON i.inventory_id = r.inventory_id
JOIN public.film      f ON f.film_id = i.film_id
WHERE UPPER(f.title) IN ('THE ODYSSEY','CLICK','THE TRUMAN SHOW')
  AND NOT EXISTS (SELECT 1 FROM public.payment p WHERE p.rental_id = r.rental_id)
RETURNING payment_id, customer_id, rental_id, amount, payment_date;
COMMIT;

-- 7. Final check (read-only).
SELECT c.customer_id, c.first_name, c.last_name, c.email,
       (SELECT COUNT(*) FROM public.rental  r WHERE r.customer_id = c.customer_id) AS rentals,
       (SELECT COUNT(*) FROM public.payment p WHERE p.customer_id = c.customer_id) AS payments
FROM public.customer c
WHERE c.email = 'mhontar@kse.org.ua';
-- Expected: 3 rentals and 3 payments.
