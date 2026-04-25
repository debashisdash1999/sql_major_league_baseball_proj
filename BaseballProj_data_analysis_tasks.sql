USE major_league_baseball;

-- ============================================================
-- MLB PLAYER, SCHOOL & SALARY ANALYSIS
-- Tool: MySQL Workbench
-- Parts: School Analysis → Salary Analysis → Career Analysis → Player Comparison
-- ============================================================


-- ============================================================
-- PART 1: SCHOOL ANALYSIS
-- ============================================================

-- Preview both tables to understand the structure before querying
SELECT * FROM schools;
SELECT * FROM school_details;

-- Count distinct schools per decade that produced at least one MLB player
-- FLOOR(yearID / 10) * 10 groups years into decade buckets (e.g., 1980, 1990)
SELECT FLOOR(yearID / 10) * 10 AS decade,
       COUNT(DISTINCT schoolID) AS num_of_schools
FROM schools
GROUP BY decade
ORDER BY decade;

-- Rank schools by total distinct players produced — show top 5 overall
-- LEFT JOIN ensures schools with no detail records still appear
SELECT sd.name_full AS school_name, COUNT(DISTINCT s.playerID) AS num_of_players
FROM schools s LEFT JOIN school_details sd
    ON s.schoolID = sd.schoolID
GROUP BY s.schoolID
ORDER BY num_of_players DESC
LIMIT 5;

-- For each decade, find the top 3 schools by player count
-- CTE 1 (ds): aggregates player count per school per decade
-- CTE 2 (rn): assigns a rank within each decade using ROW_NUMBER
-- Final SELECT: filters to top 3 per decade
WITH ds AS (
    SELECT FLOOR(s.yearID / 10) * 10 AS decade,
           sd.name_full AS school_name,
           COUNT(DISTINCT s.playerID) AS num_of_players
    FROM schools s LEFT JOIN school_details sd
        ON s.schoolID = sd.schoolID
    GROUP BY decade, s.schoolID
),
rn AS (
    SELECT decade, school_name, num_of_players,
           ROW_NUMBER() OVER (PARTITION BY decade ORDER BY num_of_players DESC) AS row_num
    FROM ds
)
SELECT * FROM rn 
WHERE row_num <= 3
ORDER BY decade DESC, row_num;


-- ============================================================
-- PART 2: SALARY ANALYSIS
-- ============================================================

-- Preview the salaries table
SELECT * FROM salaries;

-- Identify the top 20% of teams by average annual payroll
-- CTE (ts): calculates total spend per team per year
-- CTE (sp): averages that spend and uses NTILE(5) to bucket teams into quintiles
-- spend_pct = 1 means the top 20%
WITH ts AS (
    SELECT teamID, yearID, SUM(salary) AS total_spend
    FROM salaries
    GROUP BY teamID, yearID
    ORDER BY teamID, yearID
),
sp AS (
    SELECT teamID,
           AVG(total_spend) AS avg_spend,
           NTILE(5) OVER (ORDER BY AVG(total_spend) DESC) AS spend_pct
    FROM ts
    GROUP BY teamID
)
SELECT teamID, ROUND(avg_spend / 1000000, 1) AS avg_spend_in_millions
FROM sp WHERE spend_pct = 1;

-- Show cumulative spending per team over the years
-- Running total using SUM() as a window function partitioned by team, ordered by year
-- Divided by 1M for readability
WITH ts AS (
    SELECT teamID, yearID, SUM(salary) AS total_spend
    FROM salaries
    GROUP BY teamID, yearID
    ORDER BY teamID, yearID
)
SELECT teamID, yearID,
       ROUND(SUM(total_spend) OVER (PARTITION BY teamID ORDER BY yearID) / 1000000, 1) AS cumulative_sum_in_mil
FROM ts;

-- Find the first year each team's cumulative spending crossed $1 billion
-- CTE (ts): total spend per team per year
-- CTE (cs): running cumulative sum per team
-- CTE (rn): row numbers only on rows that already exceeded 1B — first row = the crossing year
WITH ts AS (
    SELECT teamID, yearID, SUM(salary) AS total_spend
    FROM salaries
    GROUP BY teamID, yearID
    ORDER BY teamID, yearID
),
cs AS (
    SELECT teamID, yearID,
           SUM(total_spend) OVER (PARTITION BY teamID ORDER BY yearID) AS cumulative_sum
    FROM ts
),
rn AS (
    SELECT teamID, yearID, cumulative_sum,
           ROW_NUMBER() OVER (PARTITION BY teamID ORDER BY cumulative_sum) AS rn
    FROM cs
    WHERE cumulative_sum > 1000000000
)
SELECT teamID, yearID, ROUND(cumulative_sum / 1000000000, 2) AS cum_sum_in_bil 
FROM rn WHERE rn = 1;


-- ============================================================
-- PART 3: PLAYER CAREER ANALYSIS
-- ============================================================

-- Preview players table and get total count
SELECT * FROM players;
SELECT COUNT(*) FROM players;

-- Calculate debut age, retirement age, and total career length for each player
-- CAST + CONCAT builds a proper DATE from separate birth year/month/day columns
-- TIMESTAMPDIFF computes the difference in full years between two dates
-- Full version (includes birthdate for verification):
SELECT nameGiven, debut, finalGame,
       CAST(CONCAT(birthYear, '-', birthMonth, '-', birthDay) AS DATE) AS birthdate,
       TIMESTAMPDIFF(YEAR, CAST(CONCAT(birthYear, '-', birthMonth, '-', birthDay) AS DATE), debut) AS starting_age,
       TIMESTAMPDIFF(YEAR, CAST(CONCAT(birthYear, '-', birthMonth, '-', birthDay) AS DATE), finalGame) AS ending_age,
       TIMESTAMPDIFF(YEAR, debut, finalGame) AS career_length_in_yrs
FROM players;

-- Clean output version — sorted by career length descending
SELECT nameGiven, 
       TIMESTAMPDIFF(YEAR, CAST(CONCAT(birthYear, '-', birthMonth, '-', birthDay) AS DATE), debut) AS starting_age,
       TIMESTAMPDIFF(YEAR, CAST(CONCAT(birthYear, '-', birthMonth, '-', birthDay) AS DATE), finalGame) AS ending_age,
       TIMESTAMPDIFF(YEAR, debut, finalGame) AS career_length_in_yrs
FROM players
ORDER BY career_length_in_yrs DESC;

-- Show the team each player was on at the start and end of their career
-- Two joins on salaries: one matching debut year, one matching final year
SELECT p.playerID, p.nameGiven, p.debut, p.finalGame,
       s.yearID AS starting_yr, s.teamID AS initial_team, 
       e.yearID AS end_yr, e.teamID AS last_team
FROM players p 
INNER JOIN salaries s
    ON p.playerID = s.playerID AND YEAR(p.debut) = s.yearID
INNER JOIN salaries e
    ON p.playerID = e.playerID AND YEAR(p.finalGame) = e.yearID;

-- Filter: players who started and ended on the same team AND played for 10+ years
-- Loyalty + longevity filter using team equality and year difference
SELECT p.playerID, p.nameGiven, p.debut, p.finalGame,
       s.yearID AS starting_yr, s.teamID AS initial_team, 
       e.yearID AS end_yr, e.teamID AS last_team
FROM players p 
INNER JOIN salaries s
    ON p.playerID = s.playerID AND YEAR(p.debut) = s.yearID
INNER JOIN salaries e
    ON p.playerID = e.playerID AND YEAR(p.finalGame) = e.yearID
WHERE s.teamID = e.teamID 
AND e.yearID - s.yearID >= 10;


-- ============================================================
-- PART 4: PLAYER COMPARISON ANALYSIS
-- ============================================================

-- Preview the players table
SELECT * FROM players;

-- Find players who share the same birthday
-- CTE builds a proper birthdate from separate columns
-- GROUP_CONCAT lists all players born on the same date as a comma-separated string
WITH bn AS (
    SELECT CAST(CONCAT(birthYear, '-', birthMonth, '-', birthDay) AS DATE) AS birthdate,
           nameGiven
    FROM players
)
SELECT birthdate,
       GROUP_CONCAT(nameGiven SEPARATOR ', ') AS list_of_players
FROM bn
WHERE birthdate IS NOT NULL
GROUP BY birthdate
ORDER BY birthdate;

-- Quick checks before building the batting summary
SELECT * FROM players;
SELECT playerID, bats FROM players;
SELECT DISTINCT (bats) FROM players;
SELECT * FROM salaries;

-- For each team, calculate what percentage of players bat right, left, or both
-- CASE WHEN inside SUM counts how many players fall into each category
-- Divided by total player count and multiplied by 100 for percentage
SELECT s.teamID,
       ROUND(SUM(CASE WHEN p.bats = 'R' THEN 1 ELSE 0 END) / COUNT(s.playerID) * 100, 1) AS bats_right,
       ROUND(SUM(CASE WHEN p.bats = 'L' THEN 1 ELSE 0 END) / COUNT(s.playerID) * 100, 1) AS bats_left,
       ROUND(SUM(CASE WHEN p.bats = 'B' THEN 1 ELSE 0 END) / COUNT(s.playerID) * 100, 1) AS bats_both
FROM salaries s LEFT JOIN players p
    ON s.playerID = p.playerID
GROUP BY s.teamID;

-- Track how average player height and weight at debut have shifted decade over decade
-- CTE (hw): averages height and weight per decade
-- LAG() compares each decade's average to the previous one to show the change
WITH hw AS (
    SELECT FLOOR(YEAR(debut) / 10) * 10 AS decade,
           AVG(height) AS avg_height,
           AVG(weight) AS avg_weight
    FROM players
    GROUP BY decade
)
SELECT decade,
       avg_height - LAG(avg_height) OVER(ORDER BY decade) AS height_diff,
       avg_weight - LAG(avg_weight) OVER(ORDER BY decade) AS weight_diff
FROM hw
WHERE decade IS NOT NULL;
