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
