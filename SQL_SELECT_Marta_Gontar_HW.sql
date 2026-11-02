--1.1
-- Task: show all animation movies released between 2017 and 2019 with rate more than 1, sorted alphabetically.
-- Interpretation: rate is rental_rate. between is like [] in math, thus all years are included.
--CTE
-- Join effect: the INNER JOINs act as filters, so only animated films remain.
WITH animation_films AS (
SELECT film_id
FROM public.film_category
INNER JOIN public.category USING (category_id)
WHERE name = 'Animation'
)
SELECT title, release_year, rental_rate
FROM public.film
INNER JOIN animation_films USING (film_id)
WHERE release_year BETWEEN 2017 AND 2019
AND rental_rate > 1
ORDER BY title;

-- Subquery
-- Join effect: no joins here, IN works as a filter, so only animated films remain.
SELECT title, release_year, rental_rate
FROM public.film
WHERE release_year BETWEEN 2017 AND 2019
AND rental_rate > 1
AND film_id IN (
SELECT film_id
FROM public.film_category
WHERE category_id IN (
SELECT category_id
FROM public.category
WHERE name = 'Animation'
)
)
ORDER BY title;

-- JOIN
-- Join effect: the INNER JOINs act as filters, so only animated films remain.
SELECT title, release_year, rental_rate
FROM public.film
INNER JOIN public.film_category USING (film_id)
INNER JOIN public.category USING (category_id)
WHERE name = 'Animation'
AND release_year BETWEEN 2017 AND 2019
AND rental_rate > 1
ORDER BY title;

-- JOIN is the best variant here due to being the shortest and the easiest.
--1.2
-- Task: calculate the revenue earned by each rental store since April 2017 (columns: address and address2 as one column, revenue).
-- Interpretation: a payment belongs to the store that owns the rented inventory item. address2 is empty or NULL
-- for the stores, so CONCAT_WS with NULLIF skips it and there is no NULL or extra space in the address.

-- CTE
-- Join effect: the INNER JOINs inside the CTE keep only payments that have a rental and an inventory item.
-- LEFT JOIN keeps a store even if it had no sales, COALESCE turns its revenue into 0.
WITH store_revenue AS (
SELECT store_id, SUM(amount) AS revenue
FROM public.payment
INNER JOIN public.rental USING (rental_id)
INNER JOIN public.inventory USING (inventory_id)
WHERE payment_date >= DATE '2017-04-01'
GROUP BY store_id
)
SELECT
NULLIF(CONCAT_WS(' ', address, NULLIF(TRIM(address2), '')), '') AS address,
COALESCE(revenue, 0) AS revenue
FROM public.store
INNER JOIN public.address USING (address_id)
LEFT JOIN store_revenue USING (store_id)
ORDER BY revenue DESC;

-- Subquery
-- Join effect: no joins here, every store stays in the result, and a store without sales gets revenue 0 from COALESCE.
SELECT
(
SELECT NULLIF(CONCAT_WS(' ', address, NULLIF(TRIM(address2), '')), '')
FROM public.address
WHERE address_id = s.address_id
) AS address,
COALESCE((
SELECT SUM(amount)
FROM public.payment
WHERE payment_date >= DATE '2017-04-01'
AND rental_id IN (
SELECT rental_id
FROM public.rental
WHERE inventory_id IN (
SELECT inventory_id
FROM public.inventory
WHERE store_id = s.store_id
)
)
), 0) AS revenue
FROM public.store AS s
ORDER BY revenue DESC;

-- JOIN
-- Join effect: the LEFT JOINs keep a store even if it has no sales. The date filter is in the ON clause,
-- if it was in WHERE, the LEFT JOIN would work like an INNER JOIN and stores without sales would disappear.
SELECT
NULLIF(CONCAT_WS(' ', a.address, NULLIF(TRIM(a.address2), '')), '') AS address,
COALESCE(SUM(p.amount), 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a ON a.address_id = s.address_id
LEFT JOIN public.inventory AS i ON i.store_id = s.store_id
LEFT JOIN public.rental AS r ON r.inventory_id = i.inventory_id
LEFT JOIN public.payment AS p ON p.rental_id = r.rental_id
AND p.payment_date >= DATE '2017-04-01'
GROUP BY s.store_id, a.address, a.address2
ORDER BY revenue DESC;

-- CTE is the best variant here, because it sums the big payment table first and only then adds the address.


--1.3
-- Task: show top-5 actors by number of movies released since 2015 (first_name, last_name, number_of_movies), sorted by number_of_movies descending.
-- Interpretation: since 2015 means 2015 is included. Actors are grouped by actor_id, because two actors can have the same name.
-- Places 4-7 are tied with 10 films, so the name decides who is 5th.

-- CTE
-- Join effect: the INNER JOINs drop actors without films since 2015, they cannot be in the top-5 anyway.
WITH recent_films AS (
SELECT film_id
FROM public.film
WHERE release_year >= 2015
),
actor_counts AS (
SELECT actor_id, COUNT(*) AS number_of_movies
FROM public.film_actor
INNER JOIN recent_films USING (film_id)
GROUP BY actor_id
)
SELECT first_name, last_name, number_of_movies
FROM actor_counts
INNER JOIN public.actor USING (actor_id)
ORDER BY number_of_movies DESC, first_name, last_name
LIMIT 5;

-- Subquery
-- Join effect: no joins here, the count is calculated for every actor (even those with 0 films), and only then the top-5 is cut.
SELECT
first_name,
last_name,
(
SELECT COUNT(*)
FROM public.film_actor
WHERE actor_id = a.actor_id
AND film_id IN (
SELECT film_id
FROM public.film
WHERE release_year >= 2015
)
) AS number_of_movies
FROM public.actor AS a
ORDER BY number_of_movies DESC, first_name, last_name
LIMIT 5;

-- JOIN
-- Join effect: the INNER JOINs drop actors without films since 2015, they cannot be in the top-5 anyway.
SELECT first_name, last_name, COUNT(film_id) AS number_of_movies
FROM public.actor
INNER JOIN public.film_actor USING (actor_id)
INNER JOIN public.film USING (film_id)
WHERE release_year >= 2015
GROUP BY actor_id, first_name, last_name
ORDER BY number_of_movies DESC, first_name, last_name
LIMIT 5;

-- JOIN is the best variant here due to being the shortest and doing one pass over the data.
--1.4
--CTE
-- Join effect: the INNER JOINs inside genre_films keep only films of the 3 genres. The LEFT JOIN keeps years
-- without such films, their counts are NULL, so COALESCE turns them into 0.
WITH genre_films AS (
SELECT release_year, name
FROM public.film
INNER JOIN public.film_category USING (film_id)
INNER JOIN public.category USING (category_id)
WHERE name IN ('Drama', 'Travel', 'Documentary')),
genre_counts AS (
select release_year,
COUNT(*) FILTER (WHERE name = 'Drama') AS number_of_drama_movies,
COUNT(*) FILTER (WHERE name = 'Travel') AS number_of_travel_movies,
COUNT(*) FILTER (WHERE name = 'Documentary') AS number_of_documentary_movies
FROM genre_films
GROUP BY release_year),
all_years AS (
SELECT DISTINCT release_year FROM public.film)
select release_year,
COALESCE(number_of_drama_movies, 0) AS number_of_drama_movies,
COALESCE(number_of_travel_movies, 0) AS number_of_travel_movies,
COALESCE(number_of_documentary_movies, 0) AS number_of_documentary_movies
FROM all_years
LEFT JOIN genre_counts USING (release_year)
ORDER BY release_year DESC;
--Subquery
-- Join effect: no joins here, every year from the list stays in the result, and COUNT gives 0 when there are no films.
SELECT
y.release_year,( SELECT COUNT(*) FROM public.film
WHERE release_year = y.release_year
AND film_id IN (
SELECT film_id FROM public.film_category
WHERE category_id IN (
SELECT category_id
FROM public.category
WHERE name = 'Drama'))) AS number_of_drama_movies,
(SELECT COUNT(*) FROM public.film
WHERE release_year = y.release_year
AND film_id IN (
SELECT film_id FROM public.film_category
WHERE category_id IN (
SELECT category_idFROM public.category
WHERE name = 'Travel'))) AS number_of_travel_movies,
(SELECT COUNT(*) FROM public.film
WHERE release_year = y.release_year
AND film_id IN ( SELECT film_id FROM public.film_category
WHERE category_id IN (
SELECT category_idFROM public.category
WHERE name = 'Documentary'))) AS number_of_documentary_movies
FROM ( SELECT DISTINCT release_yearFROM public.film) AS y
ORDER BY y.release_year DESC;
--JOIN
-- Join effect: the LEFT JOINs start from film, so every year stays in the result even if the film has no category
-- or belongs to another genre. COUNT ignores NULLs, so such years show 0.
SELECT
SELECT
release_year,
COUNT(CASE WHEN name = 'Drama' THEN film_id END) AS number_of_drama_movies,
COUNT(CASE WHEN name = 'Travel' THEN film_id END) AS number_of_travel_movies,
COUNT(CASE WHEN name = 'Documentary' THEN film_id END) AS number_of_documentary_movies
FROM public.film
LEFT JOIN public.film_category USING (film_id)
LEFT JOIN public.category USING (category_id)
GROUP BY release_year
ORDER BY release_year DESC;
-- JOIN is the best variant here due to being the shortest and reading each table only once.




--2.1
WITH revenue AS ( SELECT staff_id, SUM(amount) AS total_revenue FROM payment
    WHERE payment_date >= '2017-01-01'
      AND payment_date <  '2018-01-01'
    GROUP BY staff_id
),
last_store AS (
    SELECT staff_id, store_id
    FROM (
        SELECT p.staff_id, i.store_id,
               ROW_NUMBER() OVER (PARTITION BY p.staff_id
                                  ORDER BY p.payment_date DESC, p.payment_id DESC) AS rn
        FROM payment p
        JOIN rental    r ON r.rental_id    = p.rental_id
        JOIN inventory i ON i.inventory_id = r.inventory_id
        WHERE p.payment_date >= '2017-01-01'
          AND p.payment_date <  '2018-01-01'
    ) t
    WHERE rn = 1
)
SELECT s.staff_id, s.first_name, s.last_name,
       ls.store_id AS last_store_id, rv.total_revenue
FROM revenue rv
JOIN staff       s  ON s.staff_id  = rv.staff_id
JOIN last_store  ls ON ls.staff_id = rv.staff_id
ORDER BY rv.total_revenue DESC
LIMIT 3;

--2.2
SELECT f.film_id, f.title, f.rating,
       COUNT(r.rental_id) AS rental_count,
       CASE f.rating
            WHEN 'G' THEN 'All ages'
            WHEN 'PG' THEN '8+ (parental guidance suggested)'
            WHEN 'PG-13' THEN '13+'
            WHEN 'R' THEN '17+ (under 17 only with an adult)'
            WHEN 'NC-17' THEN '18+'
       END AS expected_audience_age
FROM film f
JOIN inventory i ON i.film_id = f.film_id
JOIN rental r ON r.inventory_id = i.inventory_id
GROUP BY f.film_id, f.title, f.rating
ORDER BY rental_count DESC, f.title
LIMIT 5;



--3.1
SELECT a.actor_id,
       a.first_name,
       a.last_name,
       MAX(f.release_year)                                          AS last_release_year,
       EXTRACT(YEAR FROM CURRENT_DATE) - MAX(f.release_year)   AS years_inactive
FROM actor a
JOIN film_actor fa ON fa.actor_id = a.actor_id
JOIN film       f  ON f.film_id   = fa.film_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY years_inactive DESC, a.last_name, a.first_name;

--3.2
--one row per gap
WITH actor_years AS (
    SELECT DISTINCT fa.actor_id, f.release_year
    FROM film_actor fa
    JOIN film f ON f.film_id = fa.film_id
),
gaps AS (
    SELECT actor_id, LAG(release_year) OVER (PARTITION BY actor_id ORDER BY release_year) AS prev_year, release_year                                                         AS next_year
    FROM actor_years
)
SELECT a.actor_id, a.first_name, a.last_name,
       g.prev_year, g.next_year, g.next_year - g.prev_year AS gap_years
FROM gaps g
JOIN actor a ON a.actor_id = g.actor_id
WHERE g.prev_year IS NOT NULL
ORDER BY gap_years DESC, a.last_name, a.first_name;
-- one row per actor
WITH actor_years AS (
    SELECT DISTINCT fa.actor_id, f.release_year
    FROM film_actor fa
    JOIN film f ON f.film_id = fa.film_id
),
gaps AS (
    SELECT actor_id,
           release_year - LAG(release_year) OVER (PARTITION BY actor_id ORDER BY release_year) AS gap_years
    FROM actor_years
)
SELECT a.actor_id,
       a.first_name,
       a.last_name,
       MAX(g.gap_years)           AS longest_break_years,
       ROUND(AVG(g.gap_years), 2) AS avg_gap_years
FROM gaps g
JOIN actor a ON a.actor_id = g.actor_id
WHERE g.gap_years IS NOT NULL
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_break_years DESC, a.last_name, a.first_name;
