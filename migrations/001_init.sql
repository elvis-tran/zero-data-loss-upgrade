CREATE DATABASE IF NOT EXISTS notesdb;
USE notesdb;

CREATE TABLE IF NOT EXISTS schema_version (
    version INT NOT NULL
);

INSERT INTO schema_version (version)
SELECT 0
WHERE NOT EXISTS (
    SELECT 1 FROM schema_version
);

CREATE TABLE IF NOT EXISTS notes (
    id INT NOT NULL AUTO_INCREMENT,
    author VARCHAR(100) NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);

UPDATE schema_version
SET version = 1
WHERE version < 1;
