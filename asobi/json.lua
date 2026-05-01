-- Minimal JSON encoder/decoder for asobi-love2d.
-- Handles the subset of JSON the asobi server emits: objects, arrays,
-- strings, numbers, booleans, null. Not a full RFC 8259 implementation
-- (no surrogate pair decoding for \uXXXX past BMP, no NaN/Infinity).

local M = {}

local null_marker = setmetatable({}, {__tostring = function() return "null" end})
M.null = null_marker

local function is_array(t)
	local n = 0
	for k, _ in pairs(t) do
		if type(k) ~= "number" then return false end
		n = n + 1
	end
	if n == 0 then return false end
	for i = 1, n do
		if t[i] == nil then return false end
	end
	return true, n
end

local escape_map = {
	['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
	['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function encode_string(s)
	return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
		return escape_map[c] or string.format('\\u%04x', c:byte())
	end) .. '"'
end

local encode_value
encode_value = function(v)
	local t = type(v)
	if v == null_marker then return "null" end
	if t == "nil" then return "null" end
	if t == "boolean" then return v and "true" or "false" end
	if t == "number" then
		if v ~= v then return "null" end
		if v == math.huge or v == -math.huge then return "null" end
		if v % 1 == 0 and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return tostring(v)
	end
	if t == "string" then return encode_string(v) end
	if t == "table" then
		local arr, n = is_array(v)
		if arr then
			local parts = {}
			for i = 1, n do parts[i] = encode_value(v[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			if type(k) == "string" then
				parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(val)
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot encode " .. t)
end

function M.encode(v)
	return encode_value(v)
end

local decode_value

local function skip_ws(s, i)
	while i <= #s do
		local c = s:byte(i)
		if c == 32 or c == 9 or c == 10 or c == 13 then
			i = i + 1
		else
			return i
		end
	end
	return i
end

local function decode_string(s, i)
	if s:byte(i) ~= 34 then error("expected string at " .. i) end
	i = i + 1
	local out = {}
	while i <= #s do
		local c = s:byte(i)
		if c == 34 then
			return table.concat(out), i + 1
		elseif c == 92 then
			local n = s:byte(i + 1)
			if n == 34 then out[#out + 1] = '"'; i = i + 2
			elseif n == 92 then out[#out + 1] = '\\'; i = i + 2
			elseif n == 47 then out[#out + 1] = '/'; i = i + 2
			elseif n == 98 then out[#out + 1] = '\b'; i = i + 2
			elseif n == 102 then out[#out + 1] = '\f'; i = i + 2
			elseif n == 110 then out[#out + 1] = '\n'; i = i + 2
			elseif n == 114 then out[#out + 1] = '\r'; i = i + 2
			elseif n == 116 then out[#out + 1] = '\t'; i = i + 2
			elseif n == 117 then
				local hex = s:sub(i + 2, i + 5)
				local code = tonumber(hex, 16)
				if not code then error("bad \\u escape at " .. i) end
				if code < 128 then
					out[#out + 1] = string.char(code)
				elseif code < 2048 then
					out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + (code % 64))
				else
					out[#out + 1] = string.char(
						224 + math.floor(code / 4096),
						128 + (math.floor(code / 64) % 64),
						128 + (code % 64))
				end
				i = i + 6
			else
				error("bad escape at " .. i)
			end
		else
			out[#out + 1] = string.char(c)
			i = i + 1
		end
	end
	error("unterminated string")
end

local function decode_number(s, i)
	local j = i
	if s:byte(j) == 45 then j = j + 1 end
	while j <= #s do
		local c = s:byte(j)
		if (c >= 48 and c <= 57) or c == 46 or c == 43 or c == 45
			or c == 69 or c == 101 then
			j = j + 1
		else
			break
		end
	end
	local n = tonumber(s:sub(i, j - 1))
	if n == nil then error("bad number at " .. i) end
	return n, j
end

local function decode_array(s, i)
	i = skip_ws(s, i + 1)
	local arr = {}
	if s:byte(i) == 93 then return arr, i + 1 end
	while true do
		local v
		v, i = decode_value(s, i)
		arr[#arr + 1] = v
		i = skip_ws(s, i)
		local c = s:byte(i)
		if c == 44 then i = skip_ws(s, i + 1)
		elseif c == 93 then return arr, i + 1
		else error("expected , or ] at " .. i) end
	end
end

local function decode_object(s, i)
	i = skip_ws(s, i + 1)
	local obj = {}
	if s:byte(i) == 125 then return obj, i + 1 end
	while true do
		local k
		k, i = decode_string(s, i)
		i = skip_ws(s, i)
		if s:byte(i) ~= 58 then error("expected : at " .. i) end
		local v
		v, i = decode_value(s, skip_ws(s, i + 1))
		obj[k] = v
		i = skip_ws(s, i)
		local c = s:byte(i)
		if c == 44 then i = skip_ws(s, i + 1)
		elseif c == 125 then return obj, i + 1
		else error("expected , or } at " .. i) end
	end
end

decode_value = function(s, i)
	i = skip_ws(s, i)
	local c = s:byte(i)
	if c == 34 then return decode_string(s, i)
	elseif c == 123 then return decode_object(s, i)
	elseif c == 91 then return decode_array(s, i)
	elseif c == 116 and s:sub(i, i + 3) == "true" then return true, i + 4
	elseif c == 102 and s:sub(i, i + 4) == "false" then return false, i + 5
	elseif c == 110 and s:sub(i, i + 3) == "null" then return null_marker, i + 4
	elseif c == 45 or (c and c >= 48 and c <= 57) then return decode_number(s, i)
	else error("unexpected char at " .. tostring(i) .. ": " .. tostring(c))
	end
end

function M.decode(s)
	if type(s) ~= "string" then return nil, "input must be a string" end
	local ok, val = pcall(function()
		local v, _ = decode_value(s, 1)
		return v
	end)
	if not ok then return nil, val end
	return val, nil
end

return M
