-- splitroute: foreign_keys=off
-- The vpn action is now tunnel, and a tunnel list can name the tunnel it uses.
-- SQLite can't change a CHECK or add a constrained column in place, so lists is
-- rebuilt; ids are kept, so entries and import_sources still point at the right
-- rows. The runner turns foreign keys off for this migration (DROP TABLE lists
-- would otherwise cascade to every entry) and checks foreign_key_check before it commits.

CREATE TABLE lists_new (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 64),
    source     TEXT    NOT NULL CHECK (source IN ('release', 'custom', 'import')),
    action     TEXT    NOT NULL CHECK (action IN ('direct', 'block', 'tunnel')),
    -- action tunnel only: the tunnel to use. NULL: the default tunnel. A tunnel
    -- that lists use can't be deleted (RESTRICT); the daemon says which lists.
    tunnel_id  INTEGER REFERENCES tunnels (id) ON DELETE RESTRICT,
    position   INTEGER NOT NULL, -- config order
    note       TEXT    NOT NULL DEFAULT '', -- custom lists: "#" lines after the last entry
    created_at TEXT    NOT NULL,
    updated_at TEXT    NOT NULL,
    CHECK (tunnel_id IS NULL OR action = 'tunnel')
);

INSERT INTO lists_new (id, name, source, action, position, note, created_at, updated_at)
SELECT id, name, source, CASE action WHEN 'vpn' THEN 'tunnel' ELSE action END, position, note, created_at, updated_at
FROM lists;

DROP TABLE lists;
ALTER TABLE lists_new RENAME TO lists;
