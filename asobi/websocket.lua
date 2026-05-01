-- Minimal pure-Lua WebSocket client for asobi-love2d.
-- Implements RFC 6455 client side: handshake, text-frame send (masked),
-- text-frame recv (server frames are unmasked per spec). No fragmentation,
-- no per-message-deflate, no continuation frames. Sufficient for asobi
-- which sends single-frame JSON text messages.
--
-- Non-blocking model: call ws:update() from your love.update(dt). The
-- update() pulls any available bytes from the socket and dispatches
-- complete frames to ws.on_message / on_open / on_close / on_error.

local socket = require("socket")

local M = {}
M.__index = M

local function random_bytes(n)
	math.randomseed(os.time() + (os.clock() * 1e6 % 1e6))
	local out = {}
	for i = 1, n do out[i] = string.char(math.random(0, 255)) end
	return table.concat(out)
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(data)
	local out = {}
	local pad = (3 - (#data % 3)) % 3
	data = data .. string.rep("\0", pad)
	for i = 1, #data, 3 do
		local n = data:byte(i) * 65536 + data:byte(i + 1) * 256 + data:byte(i + 2)
		out[#out + 1] = b64chars:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
		out[#out + 1] = b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
		out[#out + 1] = b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
		out[#out + 1] = b64chars:sub(n % 64 + 1, n % 64 + 1)
	end
	local result = table.concat(out)
	if pad > 0 then
		result = result:sub(1, #result - pad) .. string.rep("=", pad)
	end
	return result
end

-- Parse "ws://host:port/path" or "wss://host:port/path".
local function parse_url(url)
	local scheme, rest = url:match("^(wss?)://(.+)$")
	if not scheme then return nil, "bad url: " .. url end
	local host, port_s, path = rest:match("^([^:/]+):(%d+)(/?.*)$")
	if not host then
		host, path = rest:match("^([^/]+)(/?.*)$")
		port_s = (scheme == "wss") and "443" or "80"
	end
	if path == "" then path = "/" end
	return {
		scheme = scheme,
		host = host,
		port = tonumber(port_s),
		path = path,
	}
end

-- Encode an outgoing client text frame (opcode 0x1, masked).
local function encode_text_frame(payload)
	local len = #payload
	local header
	if len < 126 then
		header = string.char(0x81, 0x80 + len)
	elseif len < 65536 then
		header = string.char(0x81, 0xfe, math.floor(len / 256), len % 256)
	else
		-- 64-bit length. Lua 5.3+ has bit ops; for portability:
		header = string.char(0x81, 0xff,
			0, 0, 0, 0,
			math.floor(len / 16777216) % 256,
			math.floor(len / 65536) % 256,
			math.floor(len / 256) % 256,
			len % 256)
	end
	local mask = random_bytes(4)
	local masked = {}
	for i = 1, len do
		local b = payload:byte(i)
		local m = mask:byte(((i - 1) % 4) + 1)
		-- XOR via arithmetic for 5.1 compatibility.
		local x = 0
		local bit = 1
		local bb, mm = b, m
		for _ = 1, 8 do
			if (bb % 2) ~= (mm % 2) then x = x + bit end
			bit = bit * 2
			bb = math.floor(bb / 2)
			mm = math.floor(mm / 2)
		end
		masked[i] = string.char(x)
	end
	return header .. mask .. table.concat(masked)
end

-- Encode an outgoing client close frame.
local function encode_close_frame()
	local mask = random_bytes(4)
	return string.char(0x88, 0x80) .. mask
end

-- Try to parse one complete frame from the buffer. Returns
--   opcode, payload, consumed_bytes        on a complete frame
--   nil, nil, 0                            on incomplete buffer
-- Server frames are unmasked per RFC 6455.
local function decode_frame(buf)
	if #buf < 2 then return nil, nil, 0 end
	local b1 = buf:byte(1)
	local b2 = buf:byte(2)
	local opcode = b1 % 16
	local masked = b2 >= 128
	local len = b2 % 128
	local idx = 3
	if len == 126 then
		if #buf < 4 then return nil, nil, 0 end
		len = buf:byte(3) * 256 + buf:byte(4)
		idx = 5
	elseif len == 127 then
		if #buf < 10 then return nil, nil, 0 end
		len = buf:byte(7) * 16777216 + buf:byte(8) * 65536
			+ buf:byte(9) * 256 + buf:byte(10)
		idx = 11
	end
	local mask
	if masked then
		if #buf < idx + 3 then return nil, nil, 0 end
		mask = buf:sub(idx, idx + 3)
		idx = idx + 4
	end
	if #buf < idx + len - 1 then return nil, nil, 0 end
	local payload = buf:sub(idx, idx + len - 1)
	if masked then
		local out = {}
		for i = 1, len do
			local p = payload:byte(i)
			local m = mask:byte(((i - 1) % 4) + 1)
			local x = 0
			local bit = 1
			for _ = 1, 8 do
				if (p % 2) ~= (m % 2) then x = x + bit end
				bit = bit * 2
				p = math.floor(p / 2); m = math.floor(m / 2)
			end
			out[i] = string.char(x)
		end
		payload = table.concat(out)
	end
	return opcode, payload, idx + len - 1
end

function M.new()
	return setmetatable({
		state = "closed",  -- closed | connecting | open | closing
		sock = nil,
		buf = "",
		on_open = nil,
		on_message = nil,
		on_close = nil,
		on_error = nil,
	}, M)
end

function M:connect(url)
	local u, err = parse_url(url)
	if not u then return false, err end
	if u.scheme == "wss" then
		return false, "wss (TLS) not supported in this build; use ws:// or add luasec"
	end
	local sock, e = socket.tcp()
	if not sock then return false, e end
	sock:settimeout(5)
	local ok, ce = sock:connect(u.host, u.port)
	if not ok then return false, ce end

	local key = base64(random_bytes(16))
	local req = "GET " .. u.path .. " HTTP/1.1\r\n"
		.. "Host: " .. u.host .. ":" .. u.port .. "\r\n"
		.. "Upgrade: websocket\r\n"
		.. "Connection: Upgrade\r\n"
		.. "Sec-WebSocket-Key: " .. key .. "\r\n"
		.. "Sec-WebSocket-Version: 13\r\n"
		.. "\r\n"
	local _, se = sock:send(req)
	if se then return false, se end

	-- Read response headers (delimited by CRLFCRLF).
	local resp = ""
	while not resp:find("\r\n\r\n", 1, true) do
		local chunk, rerr, partial = sock:receive(1)
		if chunk then
			resp = resp .. chunk
		elseif partial and #partial > 0 then
			resp = resp .. partial
		else
			return false, "handshake read error: " .. tostring(rerr)
		end
		if #resp > 8192 then return false, "handshake response too large" end
	end
	if not resp:match("^HTTP/1%.1 101") then
		return false, "expected 101, got: " .. resp:match("^[^\r\n]*")
	end
	-- We deliberately do NOT verify Sec-WebSocket-Accept — the server is
	-- trusted in our deployment model and skipping the SHA1 keeps this
	-- implementation pure-Lua + dependency-free.

	sock:settimeout(0)
	self.sock = sock
	self.state = "open"
	self.buf = ""
	if self.on_open then self.on_open() end
	return true
end

function M:send(text)
	if self.state ~= "open" then return false, "not open" end
	local frame = encode_text_frame(text)
	local _, err = self.sock:send(frame)
	if err and err ~= "timeout" then
		self.state = "closed"
		if self.on_error then self.on_error(err) end
		return false, err
	end
	return true
end

function M:close()
	if self.state == "open" then
		self.sock:send(encode_close_frame())
		self.state = "closing"
	end
	if self.sock then self.sock:close() end
	self.sock = nil
	self.state = "closed"
	if self.on_close then self.on_close() end
end

-- Called from love.update(dt) (or a smoke loop) to drain incoming bytes
-- and dispatch complete frames.
function M:update()
	if self.state ~= "open" or not self.sock then return end
	while true do
		local chunk, err, partial = self.sock:receive(4096)
		if chunk then
			self.buf = self.buf .. chunk
		elseif partial and #partial > 0 then
			self.buf = self.buf .. partial
			break
		elseif err == "timeout" then
			break
		else
			self.state = "closed"
			if self.on_error then self.on_error(err or "closed") end
			if self.on_close then self.on_close() end
			return
		end
	end
	while true do
		local opcode, payload, consumed = decode_frame(self.buf)
		if not opcode then break end
		self.buf = self.buf:sub(consumed + 1)
		if opcode == 0x1 then
			if self.on_message then self.on_message(payload) end
		elseif opcode == 0x8 then
			self.state = "closed"
			if self.sock then self.sock:close() end
			if self.on_close then self.on_close() end
			return
		elseif opcode == 0x9 then
			-- ping -> pong (same payload, opcode 0xa, masked)
			local mask = random_bytes(4)
			local hdr = string.char(0x8a, 0x80 + #payload) .. mask
			local out = {}
			for i = 1, #payload do
				local p = payload:byte(i)
				local m = mask:byte(((i - 1) % 4) + 1)
				local x = 0; local bit = 1
				for _ = 1, 8 do
					if (p % 2) ~= (m % 2) then x = x + bit end
					bit = bit * 2; p = math.floor(p / 2); m = math.floor(m / 2)
				end
				out[i] = string.char(x)
			end
			self.sock:send(hdr .. table.concat(out))
		end
	end
end

return M
