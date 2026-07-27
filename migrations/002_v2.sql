USE notesdb;

ALTER TABLE notes
ADD COLUMN content TEXT NULL AFTER author;

UPDATE notes
SET content = body
WHERE id <= 10;

SELECT SLEEP(15);

ALTER TABLE notes
DROP COLUMN body;

UPDATE schema_version
SET version = 2;
