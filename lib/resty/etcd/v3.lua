-- https://github.com/ledgetech/lua-resty-http
local split         = require("ngx.re").split
local typeof        = require("typeof")
local cjson         = require("cjson.safe")
local setmetatable  = setmetatable
local random        = math.random
local clear_tab     = require("table.clear")
local utils         = require("resty.etcd.utils")
local tab_nkeys     = require("table.nkeys")
local encode_args   = ngx.encode_args
local now           = ngx.now
local sub_str       = string.sub
local str_byte      = string.byte
local str_char      = string.char
local ipairs        = ipairs
local pairs         = pairs
local unpack        = unpack
local re_match      = ngx.re.match
local type          = type
local tab_insert    = table.insert
local str_lower     = string.lower
local tab_clone     = require("table.clone")
local decode_json   = cjson.decode
local encode_json   = cjson.encode
local encode_base64 = ngx.encode_base64
local decode_base64 = ngx.decode_base64
local semaphore     = require("ngx.semaphore")
local health_check  = require("resty.etcd.health_check")
local pl_path       = require("pl.path")

math.randomseed(now() * 1000 + ngx.worker.pid())

local INIT_COUNT_RESIZE = 2e8

local _M = {}

local mt = { __index = _M }

local unmodifiable_headers = {
    ["authorization"] = true,
    ["content-length"] = true,
    ["transfer-encoding"] = true,
    ["connection"] = true,
    ["upgrade"] = true,
}


-- define local refresh function variable
local refresh_jwt_token


local function ring_balancer(self)
    local endpoints = self.endpoints
    local endpoints_len = #endpoints

    self.init_count = self.init_count + 1
    local pos = self.init_count % endpoints_len + 1
    if self.init_count >= INIT_COUNT_RESIZE then
        self.init_count = 0
    end

    return endpoints[pos]
end


local function choose_endpoint(self)
    for _, _ in ipairs(self.endpoints) do
        local endpoint = ring_balancer(self)
        if health_check.get_target_status(endpoint.http_host) then
            utils.log_info("choose endpoint: ", endpoint.http_host)
            return endpoint
        end
    end

    return nil, "has no healthy etcd endpoint available"
end


local function request_uri_via_unix_socket(self, uri, params)
    local parsed_uri, err = self:parse_uri(uri, false)
    if not parsed_uri then
        return nil, err
    end

    local path, query
    params.scheme, params.host, params.port, path, query = unpack(parsed_uri)

    local use_unix_socket = false
    if params.unix_socket_proxy then
        local sock_path = params.unix_socket_proxy:sub(#"unix:" + 1)
        use_unix_socket = pl_path.exists(sock_path)
    end

    if use_unix_socket then
        if not params.headers then
            params.headers = {}
        end

        params.headers["Host"] = params.host
        params.host = params.unix_socket_proxy
        params.port = nil
    end

    params.path = params.path or path
    params.query = params.query or query
    params.ssl_server_name = params.ssl_server_name or params.host

    local res
    res, err = self:connect(params)
    if not res then
        return nil, err
    end

    res, err = self:request(params)
    if not res then
        self:close()
        return nil, err
    end

    local body
    body, err = res:read_body()
    if not body then
        self:close()
        return nil, err
    end

    res.body = body

    if params.keepalive == false then
        self:close()

    else
        self:set_keepalive(params.keepalive_timeout, params.keepalive_pool)
    end

    return res, nil
end


local function http_request_uri(self, http_cli, method, uri, body, headers, keepalive)
    local endpoint, err = choose_endpoint(self)
    if not endpoint then
        return nil, err
    end

    local full_uri
    if utils.starts_with(uri, "/version") then
        full_uri = endpoint.http_host .. uri
    else
        full_uri = endpoint.full_prefix .. uri
    end

    local res
    res, err = request_uri_via_unix_socket(http_cli, full_uri, {
        method = method,
        body = body,
        headers = headers,
        keepalive = keepalive,
        ssl_verify = self.ssl_verify,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
        ssl_server_name = self.sni,
        unix_socket_proxy = self.unix_socket_proxy,
    })

    if err then
        health_check.report_failure(endpoint.http_host)
        return nil, endpoint.http_host .. ": " .. err
    end

    if res.status >= 500 then
        health_check.report_failure(endpoint.http_host)
        return nil, "invalid response code: " .. res.status
    end

    return res
end


local function _request_uri(self, method, uri, opts, timeout, ignore_auth)
    utils.log_info("v3 request uri: ", uri, ", timeout: ", timeout)

    local body
    if opts and opts.body and tab_nkeys(opts.body) > 0 then
        body = encode_json(opts.body) --encode_args(opts.body)
    end

    if opts and opts.query and tab_nkeys(opts.query) > 0 then
        uri = uri .. '?' .. encode_args(opts.query)
    end

    local headers = {}
    local keepalive = true
    if self.is_auth then
        if not ignore_auth then
            -- authentication reqeust not need auth request
            local _, err = refresh_jwt_token(self, timeout)
            if err then
                return nil, err
            end
            headers.Authorization = self.jwt_token
        else
            keepalive = false   -- jwt_token not keepalive
        end
    end

    if self.extra_headers and type(self.extra_headers) == "table" then
        for key, value in pairs(self.extra_headers) do
            if not unmodifiable_headers[str_lower(key)] then
                headers[key] = value
            end
        end
        utils.log_info("request uri headers: ", encode_json(headers))
    end

    local http_cli, err = utils.http.new()
    if err then
        return nil, err
    end

    if timeout then
        http_cli:set_timeout(timeout * 1000)
    end

    local res
    if health_check.conf.retry then
        local max_retry = #self.endpoints * health_check.conf.max_fails + 1
        for i = 1, max_retry do
            res, err = http_request_uri(self, http_cli, method, uri, body, headers, keepalive)
            if res then
                break
            end

            if err == "has no healthy etcd endpoint available" then
                return nil, err
            end

            if i < max_retry then
                utils.log_warn(err .. ". Retrying")
            end
        end
    else
        res, err = http_request_uri(self, http_cli, method, uri, body, headers, keepalive)
    end

    if err then
        return nil, err
    end

    if not typeof.string(res.body) then
        return res
    end

    res.body = decode_json(res.body)
    return res
end


local function serialize_and_encode_base64(serialize_fn, data)
    local err
    data, err = serialize_fn(data)
    if not data then
        return nil, err
    end
    return encode_base64(data)
end


function _M.new(opts)
    local timeout    = opts.timeout
    local ttl        = opts.ttl
    local api_prefix = opts.api_prefix
    local key_prefix = opts.key_prefix or ""
    local http_host  = opts.http_host
    local user       = opts.user
    local password   = opts.password
    local ssl_verify = opts.ssl_verify
    if ssl_verify == nil then
        ssl_verify = true
    end
    local serializer = opts.serializer
    local extra_headers = opts.extra_headers
    local sni        = opts.sni
    local unix_socket_proxy = opts.unix_socket_proxy
    local init_count = opts.init_count

    if not typeof.uint(timeout) then
        return nil, 'opts.timeout must be unsigned integer'
    end

    if not typeof.string(http_host) and not typeof.table(http_host) then
        return nil, 'opts.http_host must be string or string array'
    end

    if not typeof.int(ttl) then
        return nil, 'opts.ttl must be integer'
    end

    if not typeof.string(api_prefix) then
        return nil, 'opts.api_prefix must be string'
    end

    if not typeof.string(key_prefix) then
        return nil, 'opts.key_prefix must be string'
    end

    if user and not typeof.string(user) then
        return nil, 'opts.user must be string or ignore'
    end

    if password and not typeof.string(password) then
        return nil, 'opts.password must be string or ignore'
    end

    if unix_socket_proxy and not typeof.string(unix_socket_proxy) then
        return nil, 'opts.unix_socket_proxy must be string or ignore'
    end

    if not typeof.number(init_count) then
        init_count = random(100)
    end

    local endpoints = {}
    local http_hosts
    if type(http_host) == 'string' then -- signle node
        http_hosts = {http_host}
    else
        http_hosts = http_host
    end

    for _, host in ipairs(http_hosts) do
        local m, err = re_match(host,
            [=[([^\/]+):\/\/([\da-zA-Z.-]+|\[[\da-fA-F:]+\]):?(\d+)?$]=], "jo")
        if not m then
            return nil, "invalid http host: " .. host .. ", err: " .. (err or "not matched")
        end

        local addr
        if unix_socket_proxy then
            addr = unix_socket_proxy
        else
            addr = m[2] or "127.0.0.1"
        end

        local port
        if not unix_socket_proxy then
            port = m[3] or "2379"
        end

        tab_insert(endpoints, {
            full_prefix = host .. utils.normalize(api_prefix),
            http_host   = host,
            parsed_uri  = m,
            scheme      = m[1],
            host        = m[2] or "127.0.0.1",
            address     = addr,
            port        = port,
            api_prefix  = api_prefix,
        })
    end

    local sema, err = semaphore.new()
    if not sema then
        return nil, err
    end

    if health_check.conf == nil then
        health_check.init()
    end

    return setmetatable({
            last_auth_time = now(), -- save last Authentication time
            last_refresh_jwt_err = nil,
            sema       = sema,
            jwt_token  = nil,       -- last Authentication token
            is_auth    = not not (user and password),
            user       = user,
            password   = password,
            timeout    = timeout,
            ttl        = ttl,
            is_cluster = #endpoints > 1,
            endpoints  = endpoints,
            key_prefix = key_prefix,
            ssl_verify = ssl_verify,
            serializer = serializer,

            ssl_cert_path = opts.ssl_cert_path,
            ssl_key_path = opts.ssl_key_path,
            extra_headers = extra_headers,
            sni        = sni,
            unix_socket_proxy = unix_socket_proxy,
            init_count = init_count,
        },
        mt)
end


local function wake_up_everyone(self)
    local count = -self.sema:count()
    if count > 0 then
        self.sema:post(count)
    end
end


-- return refresh_is_ok, error
function refresh_jwt_token(self, timeout)
    -- token exist and not expire
    -- default is 5min, we use 3min plus random seconds to smooth the refresh across workers
    -- https://github.com/etcd-io/etcd/issues/8287
    if self.jwt_token and now() - self.last_auth_time < 60 * 3 + random(0, 60) then
        return true, nil
    end

    if self.requesting_token then
        self.sema:wait(timeout)
        if self.jwt_token and now() - self.last_auth_time < 60 * 3 + random(0, 60) then
            return true, nil
        end

        if self.last_refresh_jwt_err then
            utils.log_info("v3 refresh jwt last err: ", self.last_refresh_jwt_err)
            return nil, self.last_refresh_jwt_err
        end

        -- something unexpected happened, try again
        utils.log_info("v3 try auth after waiting, timeout: ", timeout)
    end

    self.last_refresh_jwt_err = nil
    self.requesting_token = true

    local opts = {
        body = {
            name         = self.user,
            password     = self.password,
        }
    }

    local res, err
    res, err = _request_uri(self, 'POST', "/auth/authenticate", opts, timeout, true)
    self.requesting_token = false

    if err then
        self.last_refresh_jwt_err = err
        wake_up_everyone(self)
        return nil, err
    end

    if not res or not res.body or not res.body.token then
        err = 'authenticate refresh token fail'
        self.last_refresh_jwt_err = err
        wake_up_everyone(self)
        return nil, err
    end

    self.jwt_token = res.body.token
    self.last_auth_time = now()
    wake_up_everyone(self)

    return true, nil
end



local function set(self, key, val, attr)
    -- verify key
    local _, err = utils.verify_key(key)
    if err then
        return nil, err
    end

    key = encode_base64(key)
    val, err = serialize_and_encode_base64(self.serializer.serialize, val)

    if not val then
        return nil, err
    end

    attr = attr or {}

    local lease
    if attr.lease then
        lease = attr.lease and attr.lease or 0
    end

    local prev_kv
    if attr.prev_kv then
        prev_kv = attr.prev_kv and true or false
    end

    local ignore_value
    if attr.ignore_value then
        ignore_value = attr.ignore_value and true or false
    end

    local ignore_lease
    if attr.ignore_lease then
        ignore_lease = attr.ignore_lease and true or false
    end

    local opts = {
        body = {
            value        = val,
            key          = key,
            lease        = lease,
            prev_kv      = prev_kv,
            ignore_value = ignore_value,
            ignore_lease = ignore_lease,
        }
    }

    local res
    res, err = _request_uri(self, 'POST', "/kv/put", opts, self.timeout)
    if err then
        return nil, err
    end

    -- get
    if res.status < 300  then
        -- TODO(optimize): delay json encode
        utils.log_info("v3 set body: ", encode_json(res.body))
    end

    return res
end

local function get(self, key, attr)

    -- verify key
    local _, err = utils.verify_key(key)
    if err then
        return nil, err
    end

    attr = attr or {}

    local range_end
    if attr.range_end then
        range_end = encode_base64(attr.range_end)
    end

    local limit = attr.limit or 0
    local revision = attr.revision or 0
    local sort_order = attr.sort_order or 0
    local sort_target = attr.sort_target or 0
    local serializable = attr.serializable or false
    local keys_only = attr.keys_only or false
    local count_only = attr.count_only or false
    local min_mod_revision = attr.min_mod_revision or 0
    local max_mod_revision = attr.max_mod_revision or 0
    local min_create_revision = attr.min_create_revision or 0
    local max_create_revision = attr.max_create_revision or 0

    key = encode_base64(key)

    local opts = {
        body = {
            key                 = key,
            range_end           = range_end,
            limit               = limit,
            revision            = revision,
            sort_order          = sort_order,
            sort_target         = sort_target,
            serializable        = serializable,
            keys_only           = keys_only,
            count_only          = count_only,
            min_mod_revision    = min_mod_revision,
            max_mod_revision    = max_mod_revision,
            min_create_revision = min_create_revision,
            max_create_revision = max_create_revision
        }
    }

    local res
    res, err = _request_uri(self, "POST", "/kv/range", opts, attr and attr.timeout or self.timeout)

    if res and res.status == 200 then
        if res.body.kvs and tab_nkeys(res.body.kvs) > 0 then
            for _, kv in ipairs(res.body.kvs) do
                kv.key = decode_base64(kv.key)
                kv.value = decode_base64(kv.value or "")
                kv.value = self.serializer.deserialize(kv.value)
            end
        end
    end

    return res, err
end

local function delete(self, key, attr)
    attr = attr and attr or {}

    local range_end
    if attr.range_end then
        range_end = encode_base64(attr.range_end)
    end

    local prev_kv
    if attr.prev_kv then
        prev_kv = attr.prev_kv and true or false
    end

    key = encode_base64(key)

    local opts = {
        body = {
            key       = key,
            range_end = range_end,
            prev_kv   = prev_kv,
        },
    }


    return _request_uri(self, "POST", "/kv/deleterange", opts, self.timeout)
end

local function txn(self, opts_arg, compare, success, failure)
    if #compare < 1 then
        return nil, "compare couldn't be empty"
    end

    if (success == nil or #success < 1) and (failure == nil or #failure < 1) then
        return nil, "success and failure couldn't be empty at the same time"
    end

    local timeout = opts_arg and opts_arg.timeout
    local opts = {
        body = {
            compare = compare,
            success = success,
            failure = failure,
        },
    }

    return _request_uri(self, "POST", "/kv/txn", opts, timeout or self.timeout)
end


local function http_request_chunk(self, http_cli)
    local endpoint, err = choose_endpoint(self)
    if not endpoint then
        return nil, err
    end

    if not endpoint.port then
        local sock_path = endpoint.address:sub(#"unix:" + 1)
        if not pl_path.exists(sock_path) then
            endpoint.address = endpoint.parsed_uri[2]
            endpoint.port = endpoint.parsed_uri[3]
        end
    end

    local ok
    ok, err = http_cli:connect({
        scheme = endpoint.scheme,
        host = endpoint.address,
        port = endpoint.port,
        ssl_verify = self.ssl_verify,
        ssl_cert_path = self.ssl_cert_path,
        ssl_key_path = self.ssl_key_path,
        ssl_server_name = self.sni,
    })
    if not ok then
        health_check.report_failure(endpoint.http_host)
        return nil, endpoint.http_host .. ": " .. err
    end

    return endpoint, err
end


local function request_chunk(self, method, path, opts, timeout)
    local body, err, _
    if opts and opts.body and tab_nkeys(opts.body) > 0 then
        body, err = encode_json(opts.body)
        if not body then
            return nil, err
        end
    end

    local query
    if opts and opts.query and tab_nkeys(opts.query) > 0 then
        query = encode_args(opts.query)
    end

    local headers = {}
    if self.is_auth then
        -- authentication reqeust not need auth request
        _, err = refresh_jwt_token(self, timeout)
        if err then
            return nil, err
        end
        headers.Authorization = self.jwt_token
    end

    if self.extra_headers and type(self.extra_headers) == "table" then
        for key, value in pairs(self.extra_headers) do
            if not unmodifiable_headers[str_lower(key)] then
                headers[key] = value
            end
        end
        utils.log_info("request chunk headers: ", encode_json(headers))
    end

    local http_cli
    http_cli, err = utils.http.new()
    if err then
        return nil, err
    end

    if timeout then
        _, err = http_cli:set_timeout(timeout * 1000)
        if err then
            return nil, err
        end
    end

    local endpoint
    if health_check.conf.retry then
        local max_retry = #self.endpoints * health_check.conf.max_fails + 1
        for i = 1, max_retry do
            endpoint, err = http_request_chunk(self, http_cli)
            if endpoint then
                break
            end

            if err == "has no healthy etcd endpoint available" then
                return nil, err
            end

            if i < max_retry then
                utils.log_warn(err .. ". Retrying")
            end
        end
    else
        endpoint, err = http_request_chunk(self, http_cli)
    end

    if err then
        return nil, err
    end

    if self.unix_socket_proxy then
        headers["Host"] = endpoint.host
    end

    local res
    res, err = http_cli:request({
        method  = method,
        path    = endpoint.api_prefix .. path,
        body    = body,
        query   = query,
        headers = headers,
    })
    utils.log_info("http request method: ", method, " path: ", path,
             " body: ", body, " query: ", query)

    if not res then
        http_cli:close()
        return nil, err
    end

    if res.status >= 300 then
        http_cli:close()
        return nil, "failed to watch data, response code: " .. res.status
    end


    local function read_watch()
        body = nil

        while(1) do
            local chunk, read_err = res.body_reader()
            if read_err then
                return nil, read_err
            end
            if not chunk then
                break
            end

            if not body then
                body = chunk
            else
                -- this branch will only be executed in rare cases, for example, a single event json
                -- is larger than the proxy_buffer_size of nginx which proxies etcd, so it would be
                -- ok to use a string concat directly without worry about the performance.
                body = body .. chunk
            end

            if #chunk > 0 and str_byte(chunk, -1) == str_byte("\n") then
                break
            end

        end

        if not body then
          return nil, nil
        end

        local chunks, split_err = split(body, [[\n]], "jo")
        if split_err then
            return nil, "failed to split chunks: " .. split_err
        end

        local all_events = {}
        for _, chunk in ipairs(chunks) do
            body, err = decode_json(chunk)
            if not body then
                return nil, "failed to decode json body: " .. (err or " unknown")
            elseif body.error and body.error.http_code >= 500 then
                -- health_check retry should do nothing here
                -- and let connection closed to create a new one
                health_check.report_failure(endpoint.http_host)
                return nil, endpoint.http_host .. ": " .. body.error.http_status
            end

            if body.result and body.result.events then
                for _, event in ipairs(body.result.events) do
                    if event.kv.value then   -- DELETE not have value
                        event.kv.value = decode_base64(event.kv.value or "")
                        event.kv.value = self.serializer.deserialize(event.kv.value)
                    end
                    event.kv.key = decode_base64(event.kv.key)
                    if event.prev_kv then
                        event.prev_kv.value = decode_base64(event.prev_kv.value or "")
                        event.prev_kv.value = self.serializer.deserialize(event.prev_kv.value)
                        event.prev_kv.key = decode_base64(event.prev_kv.key)
                    end
                    tab_insert(all_events, event)
                end
            else
                if #chunks == 1 then
                    return body
                end
            end
        end

        if #all_events > 1 then
            body.result.events = all_events
        end
        return body
    end

    if opts.need_cancel == true then
        return read_watch, nil, http_cli
    else
        return read_watch
    end
end


local function get_range_end(key)
    if #key == 0 then
        return str_char(0)
    end

    local last = sub_str(key, -1)
    key = sub_str(key, 1, #key-1)

    local ascii = str_byte(last) + 1
    local str   = str_char(ascii)

    return key .. str
end


local function watch(self, key, attr)
    -- verify key
    if #key == 0 then
        key = str_char(0)
    end

    key = encode_base64(key)

    local range_end
    if attr.range_end then
        range_end = encode_base64(attr.range_end)
    end

    local prev_kv
    if attr.prev_kv then
        prev_kv = attr.prev_kv and true or false
    end

    local start_revision
    if attr.start_revision then
        start_revision = attr.start_revision and attr.start_revision or 0
    end

    local watch_id
    if attr.watch_id then
        watch_id = attr.watch_id and attr.watch_id or 0
    end

    local progress_notify
    if attr.progress_notify then
        progress_notify = attr.progress_notify and true or false
    end

    local fragment
    if attr.fragment then
        fragment = attr.fragment and true or false
    end

    local filters
    if attr.filters then
        filters = attr.filters and attr.filters or 0
    end

    local need_cancel
    if attr.need_cancel then
        need_cancel = attr.need_cancel and true or false
    end

    local opts = {
        body = {
            create_request = {
                key             = key,
                range_end       = range_end,
                prev_kv         = prev_kv,
                start_revision  = start_revision,
                watch_id        = watch_id,
                progress_notify = progress_notify,
                fragment        = fragment,
                filters         = filters,
            }
        },
        need_cancel = need_cancel,
    }

    local callback_fun, http_cli, err
    callback_fun, err, http_cli = request_chunk(self, 'POST', '/watch',
                                                opts, attr.timeout or self.timeout)
    if not callback_fun then
        return nil, err
    end
    if opts.need_cancel == true then
        return callback_fun, nil, http_cli
    end
    return callback_fun
end

do
    local attr = {}
function _M.get(self, key, opts)
    if not typeof.string(key) then
        return nil, 'key must be string'
    end

    key = utils.get_real_key(self.key_prefix, key)

    clear_tab(attr)
    attr.timeout = opts and opts.timeout
    attr.revision = opts and opts.revision

    return get(self, key, attr)
end

function _M.watch(self, key, opts)
    clear_tab(attr)

    key = utils.get_real_key(self.key_prefix, key)

    attr.start_revision  = opts and opts.start_revision
    attr.timeout = opts and opts.timeout
    attr.progress_notify = opts and opts.progress_notify
    attr.filters  = opts and opts.filters
    attr.prev_kv  = opts and opts.prev_kv
    attr.watch_id = opts and opts.watch_id
    attr.fragment = opts and opts.fragment
    attr.need_cancel = opts and opts.need_cancel

    return watch(self, key, attr)
end

function _M.watchcancel(self, http_cli)
    local res, err = http_cli:close()
    -- to avoid unused variable self
    local _ = self
    return res, err
end

function _M.readdir(self, key, opts)

    clear_tab(attr)

    key = utils.get_real_key(self.key_prefix, key)

    attr.range_end = get_range_end(key)
    attr.revision = opts and opts.revision
    attr.timeout  = opts and opts.timeout
    attr.limit        = opts and opts.limit
    attr.sort_order   = opts and opts.sort_order
    attr.sort_target  = opts and opts.sort_target
    attr.keys_only    = opts and opts.keys_only
    attr.count_only   = opts and opts.count_only

    return get(self, key, attr)
end

function _M.watchdir(self, key, opts)
    clear_tab(attr)

    key = utils.get_real_key(self.key_prefix, key)

    attr.range_end = get_range_end(key)
    attr.start_revision  = opts and opts.start_revision
    attr.timeout = opts and opts.timeout
    attr.progress_notify = opts and opts.progress_notify
    attr.filters  = opts and opts.filters
    attr.prev_kv  = opts and opts.prev_kv
    attr.watch_id = opts and opts.watch_id
    attr.fragment = opts and opts.fragment
    attr.need_cancel = opts and opts.need_cancel

    return watch(self, key, attr)
end

end -- do


do
    local attr = {}
function _M.set(self, key, val, opts)

    clear_tab(attr)

    key = utils.get_real_key(self.key_prefix, key)

    attr.timeout = opts and opts.timeout
    attr.lease   = opts and opts.lease
    attr.prev_kv = opts and opts.prev_kv
    attr.ignore_value = opts and opts.ignore_value
    attr.ignore_lease = opts and opts.ignore_lease

    return set(self, key, val, attr)
end

    -- set key-val if key does not exists (atomic create)
    local compare = {}
    local success = {}
    local failure = {}
function _M.setnx(self, key, val, opts)
    clear_tab(compare)

    key = utils.get_real_key(self.key_prefix, key)

    compare[1] = {}
    compare[1].target = "CREATE"
    compare[1].key    = encode_base64(key)
    compare[1].createRevision = 0

    clear_tab(success)
    success[1] = {}
    success[1].requestPut = {}
    success[1].requestPut.key = encode_base64(key)

    local err
    val, err = serialize_and_encode_base64(self.serializer.serialize, val)
    if not val then
        return nil, "failed to encode val: " .. err
    end
    success[1].requestPut.value = val

    return txn(self, opts, compare, success, nil)
end

-- set key-val and ttl if key is exists (update)
function _M.setx(self, key, val, opts)
    clear_tab(compare)

    key = utils.get_real_key(self.key_prefix, key)

    compare[1] = {}
    compare[1].target = "CREATE"
    compare[1].key    = encode_base64(key)
    compare[1].createRevision = 0

    clear_tab(failure)
    failure[1] = {}
    failure[1].requestPut = {}
    failure[1].requestPut.key = encode_base64(key)

    local err
    val, err = serialize_and_encode_base64(self.serializer.serialize, val)
    if not val then
        return nil, "failed to encode val: " .. err
    end
    failure[1].requestPut.value = val

    return txn(self, opts, compare, nil, failure)
end

end -- do


function _M.txn(self, compare, success, failure, opts)
    local err

    if compare then
        local new_rules = tab_clone(compare)
        for i, rule in ipairs(compare) do
            rule = tab_clone(rule)

            rule.key = encode_base64(utils.get_real_key(self.key_prefix, rule.key))

            if rule.value then
                rule.value, err = serialize_and_encode_base64(self.serializer.serialize, rule.value)
                if not rule.value then
                    return nil, "failed to encode value: " .. err
                end
            end

            new_rules[i] = rule
        end
        compare = new_rules
    end

    if success then
        local new_rules = tab_clone(success)
        for i, rule in ipairs(success) do
            rule = tab_clone(rule)
            if rule.requestPut then
                local requestPut = tab_clone(rule.requestPut)
                requestPut.key = encode_base64(utils.get_real_key(self.key_prefix, requestPut.key))
                requestPut.value, err = serialize_and_encode_base64(self.serializer.serialize,
                                        requestPut.value)
                if not requestPut.value then
                    return nil, "failed to encode value: " .. err
                end

                rule.requestPut = requestPut
            end
            new_rules[i] = rule
        end
        success = new_rules
    end

    return txn(self, opts, compare, success, failure)
end

function _M.grant(self, ttl, id)
    if ttl == nil then
        return nil, "lease grant command needs TTL argument"
    end

    if not typeof.int(ttl) then
        return nil, 'ttl must be integer'
    end

    id = id or 0
    local opts = {
        body = {
            TTL = ttl,
            ID = id
        },
    }

    return _request_uri(self, "POST", "/lease/grant", opts)
end

function _M.revoke(self, id)
    if id == nil then
        return nil, "lease revoke command needs ID argument"
    end

    local opts = {
        body = {
            ID = id
        },
    }

    return _request_uri(self, "POST", "/kv/lease/revoke", opts)
end

function _M.keepalive(self, id)
    if id == nil then
        return nil, "lease keepalive command needs ID argument"
    end

    local opts = {
        body = {
            ID = id
        },
    }

    return _request_uri(self, "POST", "/lease/keepalive", opts)
end

function _M.timetolive(self, id, keys)
    if id == nil then
        return nil, "lease timetolive command needs ID argument"
    end

    keys = keys or false
    local opts = {
        body = {
            ID = id,
            keys = keys
        },
    }

    local res, err
    res, err = _request_uri(self, "POST", "/kv/lease/timetolive", opts)

    if res and res.status == 200 then
        if res.body.keys and tab_nkeys(res.body.keys) > 0 then
            for i, key in ipairs(res.body.keys) do
                res.body.keys[i] = decode_base64(key)
            end
        end
    end

    return res, err
end

function _M.leases(self)
    return _request_uri(self, "POST", "/lease/leases")
end


-- /version
function _M.version(self)
    return _request_uri(self, "GET", "/version", nil, self.timeout)
end


do
    local attr = {}
function _M.delete(self, key, opts)
    clear_tab(attr)

    key = utils.get_real_key(self.key_prefix, key)

    attr.timeout = opts and opts.timeout
    attr.prev_kv = opts and opts.prev_kv

    return delete(self, key, attr)
end

function _M.rmdir(self, key, opts)
    clear_tab(attr)

    key = utils.get_real_key(self.key_prefix, key)

    attr.range_end = get_range_end(key)
    attr.timeout   = opts and opts.timeout
    attr.prev_kv   = opts and opts.prev_kv

    return delete(self, key, attr)
end

end -- do


return _M
