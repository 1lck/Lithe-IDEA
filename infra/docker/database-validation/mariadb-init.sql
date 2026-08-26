ALTER DATABASE lithe_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE lithe_test;
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS records (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    title VARCHAR(120) NOT NULL,
    nullable_note TEXT NULL,
    empty_value VARCHAR(32) NOT NULL,
    flag BOOLEAN NOT NULL,
    tiny_value TINYINT NOT NULL,
    event_time TIMESTAMP(6) NOT NULL,
    amount DECIMAL(10, 2) NOT NULL,
    payload JSON NOT NULL,
    binary_value VARBINARY(8) NOT NULL,
    PRIMARY KEY (id),
    KEY records_title_idx (title),
    KEY records_event_time_idx (event_time)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS audit_log (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    action_name VARCHAR(64) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT INTO records
    (title, nullable_note, empty_value, flag, tiny_value, event_time, amount, payload, binary_value)
VALUES
    ('中文 / emoji 🚀', NULL, '', TRUE, 1, '2026-08-10 09:30:00.123456', 1234.50, '{"tags":["demo","中文"],"active":true}', UNHEX('00010203')),
    ('second row', 'a non-empty note', 'filled', FALSE, 127, '2026-08-11 10:45:01.000000', 0.01, '{"tags":[],"active":false}', UNHEX('FF00'));

INSERT INTO audit_log (action_name, created_at)
VALUES ('seed', '2026-08-10 09:00:00.000000');
