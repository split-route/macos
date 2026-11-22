-- Imports: lists downloaded from a URL. Their entries are rows in entries,
-- replaced in one transaction per successful download.

CREATE TABLE import_sources (
    list_id       INTEGER PRIMARY KEY REFERENCES lists (id) ON DELETE CASCADE,
    url           TEXT    NOT NULL CHECK (url LIKE 'https://%' AND length(url) <= 2048),
    refresh_hours INTEGER NOT NULL DEFAULT 0 CHECK (refresh_hours BETWEEN 0 AND 168), -- 0: default
    etag          TEXT    NOT NULL DEFAULT '',
    last_modified TEXT    NOT NULL DEFAULT '',
    sha256        TEXT    NOT NULL DEFAULT '', -- of the last good download
    fetched_at    TEXT    NOT NULL DEFAULT '', -- last download that replaced the entries
    checked_at    TEXT    NOT NULL DEFAULT '', -- last attempt, successful or not
    last_error    TEXT    NOT NULL DEFAULT '',
    force         INTEGER NOT NULL DEFAULT 0 CHECK (force IN (0, 1)), -- download on the next pass
    skipped       INTEGER NOT NULL DEFAULT 0 -- lines the last download had that were skipped
);
