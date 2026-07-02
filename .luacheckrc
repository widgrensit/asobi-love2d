std = "lua54"
max_line_length = 120

-- Callback signatures routinely receive positional args they do not use;
-- unused locals are still reported.
unused_args = false

-- LOVE engine global, available when the SDK runs inside a love2d game.
read_globals = {
	"love",
}
