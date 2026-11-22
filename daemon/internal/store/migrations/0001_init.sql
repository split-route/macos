-- Settings and lists. Everything written here has passed config.Validate;
-- the constraints are a second line of defense against bugs and hand edits.

CREATE TABLE settings (
    id            INTEGER PRIMARY KEY CHECK (id = 1),
    base_url      TEXT    NOT NULL DEFAULT '' CHECK (base_url = '' OR base_url LIKE 'https://%'),
    disabled      INTEGER NOT NULL DEFAULT 0 CHECK (disabled IN (0, 1)),
    migrated_from TEXT    NOT NULL DEFAULT '', -- config file imported on first run, or '' for defaults
    created_at    TEXT    NOT NULL
);

CREATE TABLE lists (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 64),
    source     TEXT    NOT NULL CHECK (source IN ('release', 'custom', 'import')),
    action     TEXT    NOT NULL CHECK (action IN ('direct', 'block', 'vpn')),
    position   INTEGER NOT NULL, -- config order
    note       TEXT    NOT NULL DEFAULT '', -- custom lists: "#" lines after the last entry
    created_at TEXT    NOT NULL,
    updated_at TEXT    NOT NULL
);

CREATE TABLE entries (
    list_id  INTEGER NOT NULL REFERENCES lists (id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    kind     TEXT    NOT NULL CHECK (kind IN ('cidr', 'domain', 'domain_suffix', 'asn')),
    value    TEXT    NOT NULL CHECK (length(value) BETWEEN 1 AND 253),
    note     TEXT    NOT NULL DEFAULT '', -- "#" lines just before the entry
    PRIMARY KEY (list_id, kind, value)
) WITHOUT ROWID;

CREATE INDEX entries_order ON entries (list_id, position);
