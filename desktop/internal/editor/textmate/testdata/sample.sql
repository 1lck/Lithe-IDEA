-- Create the users table
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    name VARCHAR(255) NOT NULL DEFAULT 'anonymous',
    score DECIMAL(10, 2) = 1.5e3
);
/* block
   comment */
SELECT u.id, COUNT(*) AS total, MAX(u.score)
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.name LIKE 'A%' AND o.created_at >= '2024-01-01'
GROUP BY u.id
HAVING COUNT(*) > 10
ORDER BY total DESC;
INSERT INTO users (name) VALUES ("quoted"), (NULL);
