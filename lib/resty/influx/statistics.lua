-- Copyright (C) mufanh

local _M = { _VERSION = "0.0.1" }

local ngx = ngx
local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO
local new_timer = ngx.timer.at

local influx_util = require "resty.influx.util"
local influx_object = require "resty.influx.object"
local lru_cache = require "resty.lrucache"

-- constants
local DEFAULT_LRU_CACHE_MAX_ITEMS = 2048
local DEFAULT_LRU_CACHE_EXPIRE_SECONDS = 120
local DEFAULT_UPLOAD_DELAY_SECONDS = 60

-- globals as upvalues (module is intended to run once per worker process)
local _enabled = false
local _influx_cfg
local _influx
local _cache_cfg
local _cache
local _server_name

-- the submitted information is combined to reduce the amount of data sent and improve the performance
local function calculate(statistic, count, cost)
    statistic.count = statistic.count + count
    if statistic.min < 0.00000001 or cost < statistic.min then
        statistic.min = cost
    end
    if cost > statistic.max then
        statistic.max = cost
    end
    statistic.total = statistic.total + cost
    if statistic.count > 0 then
        statistic.average = statistic.total / statistic.count
    end
end

-- upload statistics
local function upload()
    if not _enabled then
        log(WARN, "Influx statistics enabled false")
        return
    end

    local keys = _cache:get_keys(_cache_cfg.max_count)
    for _, k in pairs(keys) do
        local statistic = _cache:get(k)
        if statistic and statistic.key then
            _influx:set_measurement('statistics')
            _influx:add_tag("server", _server_name)
            _influx:add_tag("event", statistic.key)
            _influx:add_tag("app", statistic.app)
            _influx:add_tag("category", statistic.category)
            _influx:add_tag("action", statistic.action)
            _influx:add_tag("result", statistic.result)
            _influx:add_field("count", statistic.count)
            _influx:add_field("min", statistic.min)
            _influx:add_field("max", statistic.max)
            _influx:add_field("total", statistic.total)
            _influx:add_field("average", statistic.average)
            _influx:buffer()
        end
    end

    local ok, err = _influx:flush()
    if not ok then
        log(ERR, "Upload statistics to influxdb fail, error:", err)
    end
end

--- configure influx statistics
--- opts:
--- enabled: false means witch off, others means switch on
--- server_name: server name default "influx-statistics"
--- influx_cfg: influxdb config table(lua-resty-influx)
--- cache_cfg: lru cache config
------ max_items: cache max size
------ expire_seconds: cache expire seconds
------ max_count: cache values fetch size
--- upload_delay_seconds: upload task run delay deconds
_M.configure = function(opts)
    assert(type(opts) == "table", "Expected a table, got " .. type(opts))

    if opts.enabled == false then
        log(WARN, "Switch off")
        return
    end

    local ok, err = influx_util.validate_options(opts.influx_cfg)
    if not ok then
        log(ERR, "Influxdb config err, error: ", err)
        return
    end
    _influx_cfg = opts.influx_cfg

    local influx, err = influx_object:new(_influx_cfg)
    if not ok then
        log(ERR, "Influxdb initialization failed, error: ", err)
        return
    end
    _influx = influx

    if not opts.cache_cfg then
        opts.cache_cfg = {}
    end
    opts.cache_cfg.max_items = opts.cache_cfg.max_items or DEFAULT_LRU_CACHE_MAX_ITEMS
    _cache_cfg = opts.cache_cfg

    local cache, err = lru_cache.new(opts.cache_cfg.max_items)
    if not cache then
        log(ERR, "Lru cache initialization failed, error: ", err)
        return
    end
    _cache = cache

    -- server_name
    _server_name = opts.server_name or "influx-statistics"

    -- init upload nginx timer
    if not new_timer then
        log(ERR, "Nginx timer component is not available")
        return
    end

    opts.upload_delay_seconds = opts.upload_delay_seconds or DEFAULT_UPLOAD_DELAY_SECONDS

    local check
    check = function(premature)
        if not premature then
            -- upload statistic
            upload()

            local ok, err = new_timer(opts.upload_delay_seconds, check)
            if not ok then
                log(ERR, "Nginx timer create fail, error: ", err)
                return
            end
        end
    end
    local ok, err = new_timer(opts.upload_delay_seconds, check)
    if not ok then
        log(ERR, "Nginx timer create fail, error: ", err)
        return
    end

    _enabled = true
    log(INFO, "Influx statistics configure success")
end

-- add statistical buried point information
function _M.accumulate(app, category, action, result, count, cost)
    if not _enabled then
        return
    end

    local key = table.concat(app, category, action, result)
    local statistic = _cache:get(key)
    if statistic then
        statistic = { key = key, app = app, category = category, action = action, result = result,
                      count = 0, min = 0, max = 0, total = 0, average = 0 }
    end
    calculate(statistic, count, cost)

    -- you need to ensure that the statistics are sent to influxdb within
    -- the expiration time, otherwise the statistics may be lost
    _cache:put(key, statistic, _cache_cfg.expire_seconds or DEFAULT_LRU_CACHE_EXPIRE_SECONDS)
end

return _M
