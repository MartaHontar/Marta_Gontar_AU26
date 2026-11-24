-- 1.1 Animation films released 2017-2019 with rental_rate > 1, sorted by title.
-- Assumptions: rate = rental_rate; BETWEEN includes both years.

-- CTE
-- INNER JOINs act as a filter: only animation films remain.
WITH animation_films AS (
    SELECT fc.film_id
    FROM public.film_category AS fc
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name = 'Animation'
)
SELECT f.title, f.release_year, f.rental_rate
FROM public.film AS f
INNER JOIN animation_films AS af
    ON af.film_id = f.film_id
WHERE f.release_year BETWEEN 2017 AND 2019
    AND f.rental_rate > 1
ORDER BY f.title;

-- Subquery
-- No joins: IN works as the filter.
SELECT f.title, f.release_year, f.rental_rate
FROM public.film AS f
WHERE f.release_year BETWEEN 2017 AND 2019
    AND f.rental_rate > 1
    AND f.film_id IN (
        SELECT fc.film_id
        FROM public.film_category AS fc
        WHERE fc.category_id IN (
            SELECT c.category_id
            FROM public.category AS c
            WHERE c.name = 'Animation'
        )
    )
ORDER BY f.title;

-- JOIN
-- INNER JOINs act as a filter: only animation films remain.
SELECT f.title, f.release_year, f.rental_rate
FROM public.film AS f
INNER JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE c.name = 'Animation'
    AND f.release_year BETWEEN 2017 AND 2019
    AND f.rental_rate > 1
ORDER BY f.title;

-- Pros / cons:
--   CTE: the category filter is named and reusable; - longer, extra step for a simple filter.
--   Subquery: no duplicates possible, no join logic; - three nesting levels are harder to read,
--             and the data of the inner tables cannot be selected.
--   JOIN: shortest, one flat query, planner optimizes it well; - would duplicate rows
--         if a film had several categories (not the case here, the filter is a single category).
-- Production: JOIN (simplest, same result, easiest for the planner).


-- 1.2 Revenue of each store since April 2017 (address + address2 as one column).
-- Assumptions: a payment belongs to the store of the rented inventory item;
-- address2 is empty/NULL, so NULLIF + CONCAT_WS avoids NULL and trailing space.

-- CTE
-- INNER JOINs inside the CTE keep payments that have a rental and inventory.
-- LEFT JOIN keeps a store without sales, COALESCE makes its revenue 0.
WITH store_revenue AS (
    SELECT i.store_id, SUM(p.amount) AS revenue
    FROM public.payment AS p
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    WHERE p.payment_date >= DATE '2017-04-01'
    GROUP BY i.store_id
)
SELECT
    NULLIF(CONCAT_WS(' ', a.address, NULLIF(TRIM(a.address2), '')), '') AS address,
    COALESCE(sr.revenue, 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN store_revenue AS sr
    ON sr.store_id = s.store_id
ORDER BY revenue DESC;

-- Subquery
-- No joins: every store stays, COALESCE gives 0 when there are no sales.
SELECT
    (
        SELECT NULLIF(CONCAT_WS(' ', a.address, NULLIF(TRIM(a.address2), '')), '')
        FROM public.address AS a
        WHERE a.address_id = s.address_id
    ) AS address,
    COALESCE((
        SELECT SUM(p.amount)
        FROM public.payment AS p
        WHERE p.payment_date >= DATE '2017-04-01'
            AND p.rental_id IN (
                SELECT r.rental_id
                FROM public.rental AS r
                WHERE r.inventory_id IN (
                    SELECT i.inventory_id
                    FROM public.inventory AS i
                    WHERE i.store_id = s.store_id
                )
            )
    ), 0) AS revenue
FROM public.store AS s
ORDER BY revenue DESC;

-- JOIN
-- LEFT JOINs keep a store without sales. The date filter is in ON:
-- in WHERE it would turn the LEFT JOIN into an INNER JOIN.
SELECT
    NULLIF(CONCAT_WS(' ', a.address, NULLIF(TRIM(a.address2), '')), '') AS address,
    COALESCE(SUM(p.amount), 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN public.inventory AS i
    ON i.store_id = s.store_id
LEFT JOIN public.rental AS r
    ON r.inventory_id = i.inventory_id
LEFT JOIN public.payment AS p
    ON p.rental_id = r.rental_id
    AND p.payment_date >= DATE '2017-04-01'
GROUP BY s.store_id, a.address, a.address2
ORDER BY revenue DESC;

-- Pros / cons:
--   CTE: aggregates the big payment table first, joins the 2 stores afterwards; - longer.
--   Subquery: no join logic, correlated per store; - nested 3 levels, rerun per store row,
--             address and revenue are separate subqueries.
--   JOIN: one query; - the join of store/inventory/rental/payment is built before
--         grouping (large intermediate result), and the ON-vs-WHERE trap.
-- Production: CTE (aggregation before joining the small tables).


-- 1.3 Top-5 actors by number of films released since 2015.
-- Assumptions: 2015 is included; group by actor_id (names can repeat);
-- WITH TIES keeps actors tied for 5th place.

-- CTE
-- INNER JOINs drop actors without films since 2015 (they cannot be in the top-5).
WITH recent_films AS (
    SELECT f.film_id
    FROM public.film AS f
    WHERE f.release_year >= 2015
),
actor_counts AS (
    SELECT fa.actor_id, COUNT(*) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN recent_films AS rf
        ON rf.film_id = fa.film_id
    GROUP BY fa.actor_id
)
SELECT a.first_name, a.last_name, ac.number_of_movies
FROM actor_counts AS ac
INNER JOIN public.actor AS a
    ON a.actor_id = ac.actor_id
ORDER BY ac.number_of_movies DESC
FETCH FIRST 5 ROWS WITH TIES;

-- Subquery
-- No joins: the count is calculated for every actor (also with 0 films), then the top is cut.
SELECT
    a.first_name,
    a.last_name,
    (
        SELECT COUNT(*)
        FROM public.film_actor AS fa
        WHERE fa.actor_id = a.actor_id
            AND fa.film_id IN (
                SELECT f.film_id
                FROM public.film AS f
                WHERE f.release_year >= 2015
            )
    ) AS number_of_movies
FROM public.actor AS a
ORDER BY number_of_movies DESC
FETCH FIRST 5 ROWS WITH TIES;

-- JOIN
-- INNER JOINs drop actors without films since 2015 (they cannot be in the top-5).
SELECT a.first_name, a.last_name, COUNT(f.film_id) AS number_of_movies
FROM public.actor AS a
INNER JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
INNER JOIN public.film AS f
    ON f.film_id = fa.film_id
WHERE f.release_year >= 2015
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY number_of_movies DESC
FETCH FIRST 5 ROWS WITH TIES;

-- Pros / cons:
--   CTE: each step is named and testable; - longest.
--   Subquery: simple idea; - correlated subquery runs once per actor (200 times), slowest on big data.
--   JOIN: shortest, one pass over the data; - all joined rows are grouped at once.
-- Production: JOIN (one pass, easy to read).


-- 1.4 Number of Drama, Travel and Documentary films per release year, newest year first.
-- Assumptions: every release_year from film is shown, missing genre count = 0.

-- CTE
-- INNER JOINs in genre_films keep only the 3 genres.
-- LEFT JOIN keeps years without such films, COALESCE turns NULL into 0.
WITH genre_films AS (
    SELECT f.release_year, c.name
    FROM public.film AS f
    INNER JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name IN ('Drama', 'Travel', 'Documentary')
),
genre_counts AS (
    SELECT
        gf.release_year,
        COUNT(*) FILTER (WHERE gf.name = 'Drama') AS number_of_drama_movies,
        COUNT(*) FILTER (WHERE gf.name = 'Travel') AS number_of_travel_movies,
        COUNT(*) FILTER (WHERE gf.name = 'Documentary') AS number_of_documentary_movies
    FROM genre_films AS gf
    GROUP BY gf.release_year
),
all_years AS (
    SELECT DISTINCT f.release_year
    FROM public.film AS f
)
SELECT
    ay.release_year,
    COALESCE(gc.number_of_drama_movies, 0) AS number_of_drama_movies,
    COALESCE(gc.number_of_travel_movies, 0) AS number_of_travel_movies,
    COALESCE(gc.number_of_documentary_movies, 0) AS number_of_documentary_movies
FROM all_years AS ay
LEFT JOIN genre_counts AS gc
    ON gc.release_year = ay.release_year
ORDER BY ay.release_year DESC;

-- Subquery
-- No joins: every year stays, COUNT gives 0 when there are no films.
SELECT
    y.release_year,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        WHERE f.release_year = y.release_year
            AND f.film_id IN (
                SELECT fc.film_id
                FROM public.film_category AS fc
                WHERE fc.category_id IN (
                    SELECT c.category_id
                    FROM public.category AS c
                    WHERE c.name = 'Drama'
                )
            )
    ) AS number_of_drama_movies,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        WHERE f.release_year = y.release_year
            AND f.film_id IN (
                SELECT fc.film_id
                FROM public.film_category AS fc
                WHERE fc.category_id IN (
                    SELECT c.category_id
                    FROM public.category AS c
                    WHERE c.name = 'Travel'
                )
            )
    ) AS number_of_travel_movies,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        WHERE f.release_year = y.release_year
            AND f.film_id IN (
                SELECT fc.film_id
                FROM public.film_category AS fc
                WHERE fc.category_id IN (
                    SELECT c.category_id
                    FROM public.category AS c
                    WHERE c.name = 'Documentary'
                )
            )
    ) AS number_of_documentary_movies
FROM (
    SELECT DISTINCT f.release_year
    FROM public.film AS f
) AS y
ORDER BY y.release_year DESC;

-- JOIN
-- LEFT JOINs start from film, so every year stays even if a film has no category
-- or another genre. COUNT ignores NULLs, so such years show 0.
SELECT
    f.release_year,
    COUNT(CASE WHEN c.name = 'Drama' THEN f.film_id END) AS number_of_drama_movies,
    COUNT(CASE WHEN c.name = 'Travel' THEN f.film_id END) AS number_of_travel_movies,
    COUNT(CASE WHEN c.name = 'Documentary' THEN f.film_id END) AS number_of_documentary_movies
FROM public.film AS f
LEFT JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
LEFT JOIN public.category AS c
    ON c.category_id = fc.category_id
GROUP BY f.release_year
ORDER BY f.release_year DESC;

-- Pros / cons:
--   CTE: explicit steps, easy to debug; - 3 CTEs for a simple pivot.
--   Subquery: no join logic; - 3 big copy-pasted subqueries, 3 scans of film per year,
--             a new genre means a new block.
--   JOIN: shortest, tables are read once; - conditional aggregation is less obvious,
--         a film with several categories is counted in each of them (correct here).
-- Production: JOIN (one pass, no repeated blocks).


-- 2.1 Top-3 employees by revenue in 2017, with the store of their last payment.
-- Assumptions: last payment = latest payment_date in 2017 (ties broken by the biggest payment_id);
-- last store = store of the inventory item of that payment;
-- revenue counts all 2017 payments, LEFT JOINs keep payments without rental;
-- WITH TIES keeps staff tied for 3rd place.
-- No window functions are used.

-- CTE
-- INNER JOINs between the CTEs and staff keep only staff with payments in 2017.
-- LEFT JOINs in last_store keep the last payment even if it has no rental (store is NULL).
WITH revenue AS (
    SELECT p.staff_id, SUM(p.amount) AS total_revenue
    FROM public.payment AS p
    WHERE p.payment_date >= DATE '2017-01-01'
        AND p.payment_date < DATE '2018-01-01'
    GROUP BY p.staff_id
),
last_date AS (
    SELECT p.staff_id, MAX(p.payment_date) AS last_payment_date
    FROM public.payment AS p
    WHERE p.payment_date >= DATE '2017-01-01'
        AND p.payment_date < DATE '2018-01-01'
    GROUP BY p.staff_id
),
last_payment AS (
    SELECT p.staff_id, MAX(p.payment_id) AS last_payment_id
    FROM public.payment AS p
    INNER JOIN last_date AS ld
        ON ld.staff_id = p.staff_id
        AND ld.last_payment_date = p.payment_date
    GROUP BY p.staff_id
),
last_store AS (
    SELECT lp.staff_id, i.store_id
    FROM last_payment AS lp
    INNER JOIN public.payment AS p
        ON p.payment_id = lp.last_payment_id
    LEFT JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    LEFT JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
)
SELECT
    s.staff_id,
    s.first_name,
    s.last_name,
    ls.store_id AS last_store_id,
    rv.total_revenue
FROM revenue AS rv
INNER JOIN public.staff AS s
    ON s.staff_id = rv.staff_id
INNER JOIN last_store AS ls
    ON ls.staff_id = rv.staff_id
ORDER BY rv.total_revenue DESC
FETCH FIRST 3 ROWS WITH TIES;

-- Subquery
-- No joins: scalar subqueries; staff without 2017 payments get NULL revenue and sort last.
-- If the last payment has no rental, last_store_id is NULL.
SELECT
    s.staff_id,
    s.first_name,
    s.last_name,
    (
        SELECT i.store_id
        FROM public.inventory AS i
        WHERE i.inventory_id = (
            SELECT r.inventory_id
            FROM public.rental AS r
            WHERE r.rental_id = (
                SELECT p.rental_id
                FROM public.payment AS p
                WHERE p.staff_id = s.staff_id
                    AND p.payment_date >= DATE '2017-01-01'
                    AND p.payment_date < DATE '2018-01-01'
                ORDER BY p.payment_date DESC, p.payment_id DESC
                LIMIT 1
            )
        )
    ) AS last_store_id,
    (
        SELECT SUM(p.amount)
        FROM public.payment AS p
        WHERE p.staff_id = s.staff_id
            AND p.payment_date >= DATE '2017-01-01'
            AND p.payment_date < DATE '2018-01-01'
    ) AS total_revenue
FROM public.staff AS s
ORDER BY total_revenue DESC NULLS LAST
FETCH FIRST 3 ROWS WITH TIES;

-- JOIN
-- INNER JOINs keep staff with 2017 payments; LEFT JOINs keep a last payment without rental.
-- The total is a normal GROUP BY; the last payment is found by joining payment again
-- on the latest date (and the biggest payment_id if several payments have the same date).
SELECT
    s.staff_id,
    s.first_name,
    s.last_name,
    i.store_id AS last_store_id,
    rv.total_revenue
FROM public.staff AS s
INNER JOIN (
    SELECT
        p.staff_id,
        SUM(p.amount) AS total_revenue,
        MAX(p.payment_date) AS last_payment_date
    FROM public.payment AS p
    WHERE p.payment_date >= DATE '2017-01-01'
        AND p.payment_date < DATE '2018-01-01'
    GROUP BY p.staff_id
) AS rv
    ON rv.staff_id = s.staff_id
INNER JOIN public.payment AS lp
    ON lp.staff_id = rv.staff_id
    AND lp.payment_date = rv.last_payment_date
    AND lp.payment_id = (
        SELECT MAX(p2.payment_id)
        FROM public.payment AS p2
        WHERE p2.staff_id = rv.staff_id
            AND p2.payment_date = rv.last_payment_date
    )
LEFT JOIN public.rental AS r
    ON r.rental_id = lp.rental_id
LEFT JOIN public.inventory AS i
    ON i.inventory_id = r.inventory_id
ORDER BY rv.total_revenue DESC
FETCH FIRST 3 ROWS WITH TIES;

-- Pros / cons:
--   CTE: revenue and last store are separate, simple steps; - payment is scanned several times, 4 CTEs.
--   Subquery: no joins, no window functions; - the same payment filter is repeated, 2 subqueries per staff.
--   JOIN: one query; - a derived table plus a correlated tie-break, harder to read.
-- Production: CTE (clear steps, small result of each step).


-- 2.2 Top-5 films by number of rentals with the expected audience age of the rating.
-- Assumptions: films without rentals are not in the top; WITH TIES keeps films tied for 5th place.

-- CTE
-- INNER JOINs inside the CTE keep only rented inventory items.
WITH film_rentals AS (
    SELECT i.film_id, COUNT(r.rental_id) AS rental_count
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
)
SELECT
    f.film_id,
    f.title,
    f.rating,
    fr.rental_count,
    CASE f.rating
        WHEN 'G' THEN 'All ages'
        WHEN 'PG' THEN '8+ (parental guidance suggested)'
        WHEN 'PG-13' THEN '13+'
        WHEN 'R' THEN '17+ (under 17 only with an adult)'
        WHEN 'NC-17' THEN '18+'
    END AS expected_audience_age
FROM film_rentals AS fr
INNER JOIN public.film AS f
    ON f.film_id = fr.film_id
ORDER BY fr.rental_count DESC
FETCH FIRST 5 ROWS WITH TIES;

-- Subquery
-- No joins: the count is calculated for every film (0 for never rented films).
SELECT
    f.film_id,
    f.title,
    f.rating,
    (
        SELECT COUNT(*)
        FROM public.rental AS r
        WHERE r.inventory_id IN (
            SELECT i.inventory_id
            FROM public.inventory AS i
            WHERE i.film_id = f.film_id
        )
    ) AS rental_count,
    CASE f.rating
        WHEN 'G' THEN 'All ages'
        WHEN 'PG' THEN '8+ (parental guidance suggested)'
        WHEN 'PG-13' THEN '13+'
        WHEN 'R' THEN '17+ (under 17 only with an adult)'
        WHEN 'NC-17' THEN '18+'
    END AS expected_audience_age
FROM public.film AS f
ORDER BY rental_count DESC
FETCH FIRST 5 ROWS WITH TIES;

-- JOIN
-- INNER JOINs drop films without inventory or rentals (they cannot be in the top-5).
SELECT
    f.film_id,
    f.title,
    f.rating,
    COUNT(r.rental_id) AS rental_count,
    CASE f.rating
        WHEN 'G' THEN 'All ages'
        WHEN 'PG' THEN '8+ (parental guidance suggested)'
        WHEN 'PG-13' THEN '13+'
        WHEN 'R' THEN '17+ (under 17 only with an adult)'
        WHEN 'NC-17' THEN '18+'
    END AS expected_audience_age
FROM public.film AS f
INNER JOIN public.inventory AS i
    ON i.film_id = f.film_id
INNER JOIN public.rental AS r
    ON r.inventory_id = i.inventory_id
GROUP BY f.film_id, f.title, f.rating
ORDER BY rental_count DESC
FETCH FIRST 5 ROWS WITH TIES;

-- Pros / cons:
--   CTE: counts on the id only, film columns are added after the aggregation; - extra step.
--   Subquery: no joins; - correlated count per film, slowest.
--   JOIN: shortest; - GROUP BY on all film columns, wider rows are grouped.
-- Production: CTE (narrow aggregation, then a join to film).


-- 3.1 Actors and the years since their last film.
-- Assumptions: years_inactive = current year - latest release_year;
-- actors without films are not shown.

-- CTE
-- INNER JOIN drops actors without films.
WITH last_year AS (
    SELECT fa.actor_id, MAX(f.release_year) AS last_release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    GROUP BY fa.actor_id
)
SELECT
    a.actor_id,
    a.first_name,
    a.last_name,
    ly.last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE) - ly.last_release_year AS years_inactive
FROM last_year AS ly
INNER JOIN public.actor AS a
    ON a.actor_id = ly.actor_id
ORDER BY years_inactive DESC, a.last_name, a.first_name;

-- Subquery
-- No joins: the outer IN removes actors without films.
SELECT
    t.actor_id,
    t.first_name,
    t.last_name,
    t.last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE) - t.last_release_year AS years_inactive
FROM (
    SELECT
        a.actor_id,
        a.first_name,
        a.last_name,
        (
            SELECT MAX(f.release_year)
            FROM public.film AS f
            WHERE f.film_id IN (
                SELECT fa.film_id
                FROM public.film_actor AS fa
                WHERE fa.actor_id = a.actor_id
            )
        ) AS last_release_year
    FROM public.actor AS a
    WHERE a.actor_id IN (
        SELECT fa.actor_id
        FROM public.film_actor AS fa
    )
) AS t
ORDER BY years_inactive DESC, t.last_name, t.first_name;

-- JOIN
-- INNER JOINs drop actors without films.
SELECT
    a.actor_id,
    a.first_name,
    a.last_name,
    MAX(f.release_year) AS last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE) - MAX(f.release_year) AS years_inactive
FROM public.actor AS a
INNER JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
INNER JOIN public.film AS f
    ON f.film_id = fa.film_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY years_inactive DESC, a.last_name, a.first_name;

-- Pros / cons:
--   CTE: aggregates the link table first, joins the names after; - extra step.
--   Subquery: no joins; - nested, a correlated subquery per actor.
--   JOIN: shortest, easiest to read; - groups wider rows (name columns).
-- Production: JOIN (simple and readable, the data is small).


-- 3.2 Gaps between an actor's films.
-- Assumptions: gap = difference between two neighbouring distinct release years of the actor;
-- a gap of 1 means no break; actors with one release year have no gap and are not shown.
-- No window functions are used: the "next year" is the smallest year greater than the current one.

-- V1: one row per gap

-- CTE
-- actor_years keeps each (actor, year) once, so the self-join in gaps is small.
-- The INNER JOIN drops the last year of an actor (it has no next year).
WITH actor_years AS (
    SELECT DISTINCT fa.actor_id, f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
),
gaps AS (
    SELECT
        ay1.actor_id,
        ay1.release_year AS prev_year,
        MIN(ay2.release_year) AS next_year
    FROM actor_years AS ay1
    INNER JOIN actor_years AS ay2
        ON ay2.actor_id = ay1.actor_id
        AND ay2.release_year > ay1.release_year
    GROUP BY ay1.actor_id, ay1.release_year
)
SELECT
    a.actor_id,
    a.first_name,
    a.last_name,
    g.prev_year,
    g.next_year,
    g.next_year - g.prev_year AS gap_years
FROM gaps AS g
INNER JOIN public.actor AS a
    ON a.actor_id = g.actor_id
ORDER BY gap_years DESC, a.last_name, a.first_name;

-- Subquery
-- No joins: names and the next year come from scalar subqueries.
-- The last year of an actor has no next year (NULL) and is removed in the outer WHERE.
SELECT
    g.actor_id,
    (SELECT a.first_name FROM public.actor AS a WHERE a.actor_id = g.actor_id) AS first_name,
    (SELECT a.last_name FROM public.actor AS a WHERE a.actor_id = g.actor_id) AS last_name,
    g.prev_year,
    g.next_year,
    g.next_year - g.prev_year AS gap_years
FROM (
    SELECT
        y.actor_id,
        y.release_year AS prev_year,
        (
            SELECT MIN(f2.release_year)
            FROM public.film AS f2
            WHERE f2.release_year > y.release_year
                AND f2.film_id IN (
                    SELECT fa2.film_id
                    FROM public.film_actor AS fa2
                    WHERE fa2.actor_id = y.actor_id
                )
        ) AS next_year
    FROM (
        SELECT DISTINCT
            fa.actor_id,
            (SELECT f.release_year FROM public.film AS f WHERE f.film_id = fa.film_id) AS release_year
        FROM public.film_actor AS fa
    ) AS y
) AS g
WHERE g.next_year IS NOT NULL
ORDER BY gap_years DESC, last_name, first_name;

-- JOIN
-- Self-join without window functions: the next year is the smallest year after the current one.
SELECT
    a.actor_id,
    a.first_name,
    a.last_name,
    f1.release_year AS prev_year,
    MIN(f2.release_year) AS next_year,
    MIN(f2.release_year) - f1.release_year AS gap_years
FROM public.actor AS a
INNER JOIN public.film_actor AS fa1
    ON fa1.actor_id = a.actor_id
INNER JOIN public.film AS f1
    ON f1.film_id = fa1.film_id
INNER JOIN public.film_actor AS fa2
    ON fa2.actor_id = a.actor_id
INNER JOIN public.film AS f2
    ON f2.film_id = fa2.film_id
    AND f2.release_year > f1.release_year
GROUP BY a.actor_id, a.first_name, a.last_name, f1.release_year
ORDER BY gap_years DESC, a.last_name, a.first_name;

-- Pros / cons (V1):
--   CTE: DISTINCT years first, so the self-join works on a small set; - two steps,
--        every year is still compared with all later years of the actor.
--   Subquery: no joins; - heavy nesting, a correlated subquery per actor-year,
--             names read by scalar subqueries.
--   JOIN: one query; - the self-join multiplies rows (films per actor squared)
--         and is hard to read.
-- Production: CTE (distinct years, then a self-join). If window functions were allowed,
-- I would use LAG instead, it is shorter and needs no self-join.


-- V2: one row per actor

-- CTE
-- The gaps are built as in V1 (self-join, no window functions), then aggregated per actor.
WITH actor_years AS (
    SELECT DISTINCT fa.actor_id, f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
),
gaps AS (
    SELECT
        ay1.actor_id,
        MIN(ay2.release_year) - ay1.release_year AS gap_years
    FROM actor_years AS ay1
    INNER JOIN actor_years AS ay2
        ON ay2.actor_id = ay1.actor_id
        AND ay2.release_year > ay1.release_year
    GROUP BY ay1.actor_id, ay1.release_year
)
SELECT
    a.actor_id,
    a.first_name,
    a.last_name,
    MAX(g.gap_years) AS longest_break_years,
    ROUND(AVG(g.gap_years), 2) AS avg_gap_years
FROM gaps AS g
INNER JOIN public.actor AS a
    ON a.actor_id = g.actor_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_break_years DESC, a.last_name, a.first_name;

-- Subquery
-- No joins: names are scalar subqueries on the grouped actor_id.
-- The last year of an actor has no next year (gap is NULL) and is removed by WHERE.
SELECT
    g.actor_id,
    (SELECT a.first_name FROM public.actor AS a WHERE a.actor_id = g.actor_id) AS first_name,
    (SELECT a.last_name FROM public.actor AS a WHERE a.actor_id = g.actor_id) AS last_name,
    MAX(g.gap_years) AS longest_break_years,
    ROUND(AVG(g.gap_years), 2) AS avg_gap_years
FROM (
    SELECT
        y.actor_id,
        (
            SELECT MIN(f2.release_year)
            FROM public.film AS f2
            WHERE f2.release_year > y.release_year
                AND f2.film_id IN (
                    SELECT fa2.film_id
                    FROM public.film_actor AS fa2
                    WHERE fa2.actor_id = y.actor_id
                )
        ) - y.release_year AS gap_years
    FROM (
        SELECT DISTINCT
            fa.actor_id,
            (SELECT f.release_year FROM public.film AS f WHERE f.film_id = fa.film_id) AS release_year
        FROM public.film_actor AS fa
    ) AS y
) AS g
WHERE g.gap_years IS NOT NULL
GROUP BY g.actor_id
ORDER BY longest_break_years DESC, last_name, first_name;

-- JOIN
-- The self-join from V1 builds the gaps, then they are aggregated per actor.
SELECT
    a.actor_id,
    a.first_name,
    a.last_name,
    MAX(g.gap_years) AS longest_break_years,
    ROUND(AVG(g.gap_years), 2) AS avg_gap_years
FROM public.actor AS a
INNER JOIN (
    SELECT
        fa1.actor_id,
        MIN(f2.release_year) - f1.release_year AS gap_years
    FROM public.film_actor AS fa1
    INNER JOIN public.film AS f1
        ON f1.film_id = fa1.film_id
    INNER JOIN public.film_actor AS fa2
        ON fa2.actor_id = fa1.actor_id
    INNER JOIN public.film AS f2
        ON f2.film_id = fa2.film_id
        AND f2.release_year > f1.release_year
    GROUP BY fa1.actor_id, f1.release_year
) AS g
    ON g.actor_id = a.actor_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_break_years DESC, a.last_name, a.first_name;

-- Pros / cons (V2):
--   CTE: simple, reuses the gaps logic of V1; - needs two aggregation levels.
--   Subquery: no joins; - nested 3 levels, harder to maintain.
--   JOIN: one query; - self-join cost, still needs a derived table for the second aggregation.
-- Production: CTE (distinct years, self-join for the gaps, then aggregation per actor).
-- If window functions were allowed, I would use LAG in the gaps step.
