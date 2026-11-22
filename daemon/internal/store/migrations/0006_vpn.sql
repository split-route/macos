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
