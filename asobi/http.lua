-- Synchronous HTTP wrapper over luasocket.http for asobi-love2d.
-- LÖVE bundles luasocket so HTTP works out of the box. HTTPS requires
-- luasec (not bundled by LÖVE) — build with use_ssl=true and have luasec
-- on the path.
--
-- Synchronous on purpose: HTTP calls happen in setup paths (register,
-- login) where blocking briefly is acceptable. The realtime WebSocket
-- is the non-blocking surface used in the game loop.

local socket_http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("asobi.json")

local M = {}

local function build_url(client, path, query)
	local url = client.base_url .. path
	if query then
		local parts = {}
		for k, v in pairs(query) do
			parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
		end
		if #parts > 0 then url = url .. "?" .. table.concat(parts, "&") end
	end
	return url
end

local function headers(client)
	local h = {["Content-Type"] = "application/json"}
	if client.session_token and client.session_token ~= "" then
		h["Authorization"] = "Bearer " .. client.session_token
	end
	return h
end

-- Performs an HTTP request. Returns (data, err) where data is a decoded
-- table on success and err is a table {status_code, error} on failure.
local function request(client, method, path, body, query)
	local url = build_url(client, path, query)
	local req_body = body and json.encode(body) or ""
	local resp = {}
	local req_headers = headers(client)
	req_headers["Content-Length"] = tostring(#req_body)

	local source = (#req_body > 0) and ltn12.source.string(req_body) or nil
	local _, code, _, _ = socket_http.request{
		url = url,
		method = method,
		headers = req_headers,
		source = source,
		sink = ltn12.sink.table(resp),
	}

	local payload = table.concat(resp)
	local decoded
	if payload ~= "" then
		decoded = json.decode(payload)
	end

	if type(code) ~= "number" then
		return nil, {status_code = 0, error = tostring(code)}
	end
	if code >= 400 then
		local emsg = (decoded and decoded.error) or ("HTTP " .. code)
		return nil, {status_code = code, error = emsg}
	end
	return decoded or {}, nil
end

function M.get(client, path, query) return request(client, "GET", path, nil, query) end
function M.post(client, path, body) return request(client, "POST", path, body, nil) end
function M.put(client, path, body) return request(client, "PUT", path, body, nil) end
function M.delete(client, path, body) return request(client, "DELETE", path, body, nil) end

return M
