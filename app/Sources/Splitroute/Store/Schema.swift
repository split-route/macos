// The settings database schema. These are the daemon's migrations 0001-0006 unchanged: the app now owns the
// database, and a database the daemon wrote keeps working with no conversion. Never edit an applied one; add a new entry.

enum Schema {
    /// Marks a migration that rebuilds a table: it runs with foreign keys off and is backed up first.
    static let foreignKeysOff = "-- splitroute: foreign_keys=off"

    static let migrations: [String] = [
#"""
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
"""#,
#"""
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
"""#,
#"""
-- Tunnels: OpenVPN profiles. Only metadata lives here: the database is
-- world-readable, and a profile can hold private keys. The profile itself is
-- a root-only file (<state dir>/tunnels/<id>/profile.ovpn); profile_sha256
-- is checked before every start. Credentials are never stored by the daemon.

CREATE TABLE tunnels (
    id             INTEGER PRIMARY KEY AUTOINCREMENT, -- never reused: files and running tunnels are keyed by it
    name           TEXT    NOT NULL UNIQUE COLLATE NOCASE CHECK (length(name) BETWEEN 1 AND 64),
    kind           TEXT    NOT NULL DEFAULT 'openvpn' CHECK (kind IN ('openvpn')),
    profile_sha256 TEXT    NOT NULL CHECK (length(profile_sha256) = 64 AND profile_sha256 NOT GLOB '*[^0-9a-f]*'),
    remotes        TEXT    NOT NULL DEFAULT '', -- host:port lines, for display
    needs_auth     INTEGER NOT NULL DEFAULT 0 CHECK (needs_auth IN (0, 1)),
    key_encrypted  INTEGER NOT NULL DEFAULT 0 CHECK (key_encrypted IN (0, 1)),
    scripts        TEXT    NOT NULL DEFAULT '', -- script directives the user confirmed, space separated
    auto_connect   INTEGER NOT NULL DEFAULT 0 CHECK (auto_connect IN (0, 1)),
    position       INTEGER NOT NULL,
    created_at     TEXT    NOT NULL,
    updated_at     TEXT    NOT NULL
);
"""#,
#"""
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
"""#,
#"""
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
"""#,
#"""
-- The VPN switch and the selected tunnel.
--
-- vpn_on is whether the user wants the VPN on: the service starts it again after
-- a reboot or restart. selected_tunnel_id is the tunnel that carries all traffic
-- no list names. ON DELETE SET NULL only clears the choice if a tunnel row goes
-- away by another route; the daemon refuses to remove the selected tunnel while
-- the VPN is on.
--
-- ADD COLUMN is enough here (no rebuild): both columns default to a value the
-- old rows can take, and the reference defaults to NULL.

ALTER TABLE settings ADD COLUMN vpn_on INTEGER NOT NULL DEFAULT 0 CHECK (vpn_on IN (0, 1));
ALTER TABLE settings ADD COLUMN selected_tunnel_id INTEGER REFERENCES tunnels (id) ON DELETE SET NULL;
"""#,
#"""
-- The kill switch: while the VPN is on, the service blocks every packet that isn't the
-- engine's, so a dropped tunnel can't leak. kill_switch_lan keeps the local network
-- reachable meanwhile. Off by default: it can cut the network if the service is down.
ALTER TABLE settings ADD COLUMN kill_switch INTEGER NOT NULL DEFAULT 0 CHECK (kill_switch IN (0, 1));
ALTER TABLE settings ADD COLUMN kill_switch_lan INTEGER NOT NULL DEFAULT 1 CHECK (kill_switch_lan IN (0, 1));
"""#,
#"""
-- How proxy tunnels' server names are found: '' (DNS over HTTPS to 1.1.1.1), a DoH server's
-- IP address, or 'system'. Some networks reset DoH to one provider, so it is a setting.
ALTER TABLE settings ADD COLUMN bootstrap TEXT NOT NULL DEFAULT '' CHECK (length(bootstrap) <= 45);
"""#,
#"""
-- splitroute: foreign_keys=off
-- A list can now have no action: it is kept but not applied. lists is rebuilt because SQLite
-- can't change a CHECK in place; ids are kept, so entries and import_sources still point at
-- the right rows (see the fourth migration for why foreign keys are off).

CREATE TABLE lists_new (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 64),
    source     TEXT    NOT NULL CHECK (source IN ('release', 'custom', 'import')),
    action     TEXT    NOT NULL CHECK (action IN ('none', 'direct', 'block', 'tunnel')),
    tunnel_id  INTEGER REFERENCES tunnels (id) ON DELETE RESTRICT,
    position   INTEGER NOT NULL,
    note       TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL,
    updated_at TEXT    NOT NULL,
    CHECK (tunnel_id IS NULL OR action = 'tunnel')
);

INSERT INTO lists_new (id, name, source, action, tunnel_id, position, note, created_at, updated_at)
SELECT id, name, source, action, tunnel_id, position, note, created_at, updated_at FROM lists;

DROP TABLE lists;
ALTER TABLE lists_new RENAME TO lists;
"""#,
#"""
-- Where traffic that no list matches goes: the final route. 'tunnel' with no tunnel is the selected one (the
-- behavior before this column existed). RESTRICT: a tunnel the final route names can't be deleted from under it.
ALTER TABLE settings ADD COLUMN final_action TEXT NOT NULL DEFAULT 'tunnel' CHECK (final_action IN ('direct', 'block', 'tunnel'));
ALTER TABLE settings ADD COLUMN final_tunnel_id INTEGER REFERENCES tunnels (id) ON DELETE RESTRICT;
"""#,
#"""
-- A short description the user gives a custom list or an import; ready-made lists are described by the catalog.
ALTER TABLE lists ADD COLUMN description TEXT NOT NULL DEFAULT '' CHECK (length(description) <= 120);
"""#,
#"""
-- Refuse QUIC (HTTP/3) that no list matched, so browsers use TCP, where a site's name can be read and a block list
-- matches it. On by default: a block list that a browser can skip over QUIC is not much of a block list.
ALTER TABLE settings ADD COLUMN block_quic INTEGER NOT NULL DEFAULT 1 CHECK (block_quic IN (0, 1));
"""#,
#"""
-- The "Apply lists" switch is gone from the app. A database where it was off would stay off with no way back, so lists
-- are on again. (`disabled` stays as a column; the app no longer writes anything but 0.)
UPDATE settings SET disabled = 0;
"""#,
    ]
}
