-- splitroute: foreign_keys=off
-- Tunnels for the other protocols, and subscriptions that group them.
--
-- A subscription's URL carries the user's token, and a node holds a password or
-- a key: neither is stored here (this database is world-readable). The URL is a
-- root-only file (<state dir>/subscriptions/<id>/url) and a node's options are
-- a root-only file next to the profile (<state dir>/tunnels/<id>/options.json);
-- profile_sha256 is checked before every start, as for an OpenVPN profile.
--
-- tunnels is rebuilt: its kind CHECK listed only openvpn, and SQLite can't
-- change a CHECK in place. kind is now just a length check: the protocol is
-- validated in Go against the core's protocol list, so adding a protocol never
-- forces another rebuild. The runner turns foreign keys off for this migration
-- (DROP TABLE tunnels would otherwise trip lists.tunnel_id) and checks
-- foreign_key_check before it commits.

CREATE TABLE subscriptions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT, -- never reused: files are keyed by it
    name       TEXT    NOT NULL UNIQUE COLLATE NOCASE CHECK (length(name) BETWEEN 1 AND 64),
    last_error TEXT    NOT NULL DEFAULT '', -- why the last update failed; never holds the URL
    created_at TEXT    NOT NULL,
    updated_at TEXT    NOT NULL -- last successful update
);

CREATE TABLE tunnels_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT, -- never reused: files and running tunnels are keyed by it
    name            TEXT    NOT NULL UNIQUE COLLATE NOCASE CHECK (length(name) BETWEEN 1 AND 64),
    kind            TEXT    NOT NULL DEFAULT 'openvpn' CHECK (length(kind) BETWEEN 1 AND 32), -- the core's protocol name
    profile_sha256  TEXT    NOT NULL CHECK (length(profile_sha256) = 64 AND profile_sha256 NOT GLOB '*[^0-9a-f]*'),
    remotes         TEXT    NOT NULL DEFAULT '', -- host:port lines, for display
    needs_auth      INTEGER NOT NULL DEFAULT 0 CHECK (needs_auth IN (0, 1)),
    key_encrypted   INTEGER NOT NULL DEFAULT 0 CHECK (key_encrypted IN (0, 1)),
    scripts         TEXT    NOT NULL DEFAULT '', -- script directives the user confirmed, space separated
    auto_connect    INTEGER NOT NULL DEFAULT 0 CHECK (auto_connect IN (0, 1)),
    -- A tunnel that came from a subscription. RESTRICT, not CASCADE: the daemon
    -- removes a subscription's tunnels itself, after checking that no list uses them.
    subscription_id INTEGER REFERENCES subscriptions (id) ON DELETE RESTRICT,
    warning         TEXT    NOT NULL DEFAULT '', -- something to show on the tunnel (certificate checks off)
    position        INTEGER NOT NULL,
    created_at      TEXT    NOT NULL,
    updated_at      TEXT    NOT NULL
);

INSERT INTO tunnels_new (id, name, kind, profile_sha256, remotes, needs_auth, key_encrypted, scripts, auto_connect, position, created_at, updated_at)
SELECT id, name, kind, profile_sha256, remotes, needs_auth, key_encrypted, scripts, auto_connect, position, created_at, updated_at
FROM tunnels;

-- Keep the id sequence: a removed tunnel's id must not come back, because files
-- and running tunnels are keyed by it.
DELETE FROM sqlite_sequence WHERE name = 'tunnels_new';
INSERT INTO sqlite_sequence (name, seq) SELECT 'tunnels_new', seq FROM sqlite_sequence WHERE name = 'tunnels';

DROP TABLE tunnels;
ALTER TABLE tunnels_new RENAME TO tunnels;
