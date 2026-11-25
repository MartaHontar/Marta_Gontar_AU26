CREATE SCHEMA IF NOT EXISTS core;

-- Task 1: current-quarter revenue by category.
-- date_trunc('quarter', LOCALTIMESTAMP) gives the start of the current
-- quarter; adding three months gives its exclusive end. This also fixes
-- the year because the filter uses full timestamps, not quarter number alone.
-- INNER JOINs start from payments, so categories without sales have no row.
-- HAVING removes groups whose total revenue is zero. For example, a category
-- with no payment in the current quarter, or a payment from 2007, must not appear.
-- The sample database contains 2007 payments only, so an empty view in 2026
-- is expected. Verify it against the function below and with the fixed-date
-- query in the Task 2 tests.
CREATE OR REPLACE VIEW public.sales_revenue_by_category_qtr AS
SELECT  c.name::text          AS category,
        SUM(p.amount)         AS total_sales_revenue
FROM    public.payment       p
JOIN    public.rental        r  ON r.rental_id    = p.rental_id
JOIN    public.inventory     i  ON i.inventory_id = r.inventory_id
JOIN    public.film_category fc ON fc.film_id     = i.film_id
JOIN    public.category      c  ON c.category_id  = fc.category_id
WHERE   p.payment_date >= date_trunc('quarter', LOCALTIMESTAMP)
  AND   p.payment_date <  date_trunc('quarter', LOCALTIMESTAMP) + INTERVAL '3 months'
GROUP BY c.category_id, c.name
HAVING  SUM(p.amount) > 0;

-- Task 2: the date parameter identifies both quarter and year and makes
-- historical periods testable. It defaults to today, matching the view.
-- This SQL function has no separate quarter number, so quarter 0 or 5 cannot
-- be passed. PostgreSQL rejects an invalid date before the function runs.
-- NULL or a period with no payments returns zero rows.
CREATE OR REPLACE FUNCTION public.get_sales_revenue_by_category_qtr(
        p_date date DEFAULT CURRENT_DATE)
RETURNS TABLE (category text, total_sales_revenue numeric)
LANGUAGE sql
STABLE
AS $$
    SELECT  c.name::text, SUM(p.amount)
    FROM    public.payment       p
    JOIN    public.rental        r  ON r.rental_id    = p.rental_id
    JOIN    public.inventory     i  ON i.inventory_id = r.inventory_id
    JOIN    public.film_category fc ON fc.film_id     = i.film_id
    JOIN    public.category      c  ON c.category_id  = fc.category_id

    WHERE   p.payment_date >= date_trunc('quarter', p_date::timestamp)
      AND   p.payment_date <  date_trunc('quarter', p_date::timestamp) + INTERVAL '3 months'
    GROUP BY c.category_id, c.name
    HAVING  SUM(p.amount) > 0;
$$;

-- Task 3: popularity means rental count by customers living in each country.
-- ROW_NUMBER selects one film per country. Ties are resolved by title and
-- then film_id, making the result stable. Unknown countries or countries
-- without rentals are returned with 'No data found'. Input is case-insensitive;
-- duplicate names are returned once. NULL or an empty array raises an exception.
CREATE OR REPLACE FUNCTION core.most_popular_films_by_countries(p_countries text[])
RETURNS TABLE (country text, film text, rating text, language text,
               length integer, release_year integer)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    IF p_countries IS NULL OR cardinality(p_countries) = 0 THEN
        RAISE EXCEPTION 'p_countries must be a non-empty array of country names';
    END IF;

    RETURN QUERY
    WITH req AS (
        SELECT DISTINCT ON (lower(btrim(x))) btrim(x) AS requested, lower(btrim(x)) AS k
        FROM   unnest(p_countries) AS x
        WHERE  x IS NOT NULL AND btrim(x) <> ''
        ORDER  BY lower(btrim(x))
    ),
    cnt AS (
        SELECT req.k, co.country AS country_name, f.film_id, COUNT(*) AS rentals
        FROM   req
        JOIN   public.country   co ON lower(co.country) = req.k
        JOIN   public.city      ci ON ci.country_id  = co.country_id
        JOIN   public.address   a  ON a.city_id      = ci.city_id
        JOIN   public.customer  cu ON cu.address_id  = a.address_id
        JOIN   public.rental    r  ON r.customer_id  = cu.customer_id
        JOIN   public.inventory i  ON i.inventory_id = r.inventory_id
        JOIN   public.film      f  ON f.film_id      = i.film_id
        GROUP  BY req.k, co.country, f.film_id
    ),
    ranked AS (
        SELECT cnt.*, ROW_NUMBER() OVER (PARTITION BY cnt.k
                         ORDER BY cnt.rentals DESC, f.title, f.film_id) AS rn
        FROM   cnt JOIN public.film f ON f.film_id = cnt.film_id
    )
    SELECT  COALESCE(rk.country_name, req.requested)::text,
            COALESCE(f.title::text, 'No data found'),
            f.rating::text,
            btrim(l.name::text),
            f.length::integer,
            f.release_year::integer
    FROM    req
    LEFT JOIN ranked rk ON rk.k = req.k AND rk.rn = 1
    LEFT JOIN public.film     f ON f.film_id     = rk.film_id
    LEFT JOIN public.language l ON l.language_id = f.language_id
    ORDER BY 1;
END;
$$;

-- Task 4: ILIKE performs case-insensitive pattern matching; percent matches
-- any number of characters and underscore matches one character. Multiple
-- in-stock films produce one row each, numbered from 1. If no matching film
-- is in stock, the function returns a message row. NULL or blank input raises
-- an exception. A leading percent can require scanning film titles; a trigram
-- index can help on a larger database. EXISTS checks stock only for matched
-- titles and stops when it finds an available copy.
CREATE OR REPLACE FUNCTION core.films_in_stock_by_title(p_title_pattern text)
RETURNS TABLE (row_num integer, film_title text, language text,
               customer_name text, rental_date timestamp)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    IF p_title_pattern IS NULL OR btrim(p_title_pattern) = '' THEN
        RAISE EXCEPTION 'Title pattern must not be NULL or empty (example: ''%%love%%'')';
    END IF;

    RETURN QUERY
    SELECT  (ROW_NUMBER() OVER (ORDER BY f.title, f.film_id))::integer,
            f.title::text,
            btrim(l.name::text),
            (cu.first_name || ' ' || cu.last_name)::text,
            lr.rental_date
    FROM    public.film f
    JOIN    public.language l ON l.language_id = f.language_id
    LEFT JOIN LATERAL (
            SELECT r.rental_date, r.customer_id
            FROM   public.rental r
            JOIN   public.inventory i ON i.inventory_id = r.inventory_id
            WHERE  i.film_id = f.film_id
            ORDER  BY r.rental_date DESC
            LIMIT  1) lr ON TRUE
    LEFT JOIN public.customer cu ON cu.customer_id = lr.customer_id
    WHERE   f.title ILIKE p_title_pattern
      AND   EXISTS (
              SELECT 1 FROM public.inventory i
              WHERE  i.film_id = f.film_id
                AND  NOT EXISTS (SELECT 1 FROM public.rental r
                                 WHERE r.inventory_id = i.inventory_id
                                   AND r.return_date IS NULL))
    ORDER BY f.title, f.film_id;

    IF NOT FOUND THEN
        RAISE NOTICE 'No film matching % is in stock', p_title_pattern;
        RETURN QUERY SELECT 1, ('Film not found in stock: ' || p_title_pattern)::text,
                            NULL::text, NULL::text, NULL::timestamp;
    END IF;
END;
$$;

-- Task 5: the film ID comes from the sequence attached to film.film_id.
-- The title check ignores case and surrounding spaces; an advisory lock
-- prevents concurrent calls from inserting the same title. Existing titles
-- raise an exception. The language is looked up by name and must exist.
-- Release year and language are optional. Defaults are the current year
-- and Klingon. The setup below adds Klingon only when it is missing.
-- Any failed insert raises an exception; the statement is rolled back, so
-- no partially inserted film remains. The table trigger handles fulltext.
INSERT INTO public.language (name)
SELECT 'Klingon'
WHERE  NOT EXISTS (SELECT 1 FROM public.language WHERE lower(name::text) = 'klingon');

CREATE OR REPLACE FUNCTION core.new_movie(
        p_title        text,
        p_release_year integer DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::integer,
        p_language     text    DEFAULT 'Klingon')
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_title       text := btrim(p_title);
    v_language_id integer;
    v_film_id     integer;
BEGIN
    IF v_title IS NULL OR v_title = '' THEN
        RAISE EXCEPTION 'Movie title must not be NULL or empty';
    END IF;
    IF p_release_year IS NULL OR p_release_year NOT BETWEEN 1901 AND 2155 THEN
        RAISE EXCEPTION 'Release year % is invalid (allowed 1901..2155)', p_release_year;
    END IF;
    IF p_language IS NULL OR btrim(p_language) = '' THEN
        RAISE EXCEPTION 'Language must not be NULL or empty';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('core.new_movie:' || lower(v_title)));

    SELECT l.language_id INTO v_language_id
    FROM   public.language l
    WHERE  lower(l.name::text) = lower(btrim(p_language));
    IF v_language_id IS NULL THEN
        RAISE EXCEPTION 'Language "%" does not exist in table language', p_language;
    END IF;

    IF EXISTS (SELECT 1 FROM public.film f WHERE lower(f.title) = lower(v_title)) THEN
        RAISE EXCEPTION 'Movie "%" already exists in table film', v_title;
    END IF;

    v_film_id := nextval(pg_get_serial_sequence('public.film', 'film_id'));

    INSERT INTO public.film (film_id, title, language_id, release_year,
                             rental_duration, rental_rate, replacement_cost)
    VALUES (v_film_id, v_title, v_language_id, p_release_year, 3, 4.99, 19.99);

    RETURN v_film_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Could not insert "%": duplicate key (%)', v_title, SQLERRM;
    WHEN raise_exception THEN
        RAISE;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Insert of movie "%" failed: %', v_title, SQLERRM;
END;
$$;

-- Tests for Task 5. The valid test inserts a row and removes it afterward.
-- The duplicate-title and unknown-language tests must raise exceptions.
DO $$
DECLARE v_id integer;
BEGIN

    v_id := core.new_movie('Test Movie For Homework');
    RAISE NOTICE 'Inserted film_id=% -> %', v_id,
        (SELECT row(title, rental_rate, rental_duration, replacement_cost, release_year)
         FROM public.film WHERE film_id = v_id);

    BEGIN
        PERFORM core.new_movie('TEST MOVIE FOR HOMEWORK');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;

    BEGIN
        PERFORM core.new_movie('Another Test Movie', 2020, 'Elvish-XYZ');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;

    DELETE FROM public.film WHERE film_id = v_id;
END $$;


-- Tests for Tasks 1 and 2
-- Valid: today’s function result must match the current-quarter view.
SELECT * FROM public.sales_revenue_by_category_qtr
EXCEPT
SELECT * FROM public.get_sales_revenue_by_category_qtr(CURRENT_DATE);

-- Valid historical period: returns the 2007 Q1 category totals, if present.
SELECT * FROM public.get_sales_revenue_by_category_qtr(DATE '2007-02-15')
ORDER BY category;

-- Edge cases: no data returns no rows; NULL also returns no rows.
SELECT * FROM public.get_sales_revenue_by_category_qtr(DATE '1999-01-01');
SELECT * FROM public.get_sales_revenue_by_category_qtr(NULL);

-- Example of data that must not appear in the current-quarter view:
-- a payment dated 2007-02-15, or a category with no current-quarter payment.
