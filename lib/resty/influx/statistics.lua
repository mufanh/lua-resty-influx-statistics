-- Copyright (C) mufanh

local _M = { _VERSION = "0.0.1" }

local ngx = ngx
local table = table
local require = require
local pairs = pairs
local type = type
local assert = assert
local error = error

local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO

local influx_util = require "resty.influx.util"
local influx_object = require "resty.influx.object"
local lru_cache = require "resty.lrucache"

local table_concat = table.concat
local new_timer = assert(ngx.timer.at, "Nginx timer component is not available")
local get_phase = ngx.get_phase

-- constants
local DEFAULT_LRU_CACHE_MAX_ITEMS = 2048
local DEFAULT_LRU_CACHE_EXPIRE_SECONDS = 120
local DEFAULT_UPLOAD_DELAY_SECONDS = 60

-- globals as upvalues (module is intended to run once per worker process)
local _configured = false
local _started = false

local _influx_cfg
local _cache
local _cache_cfg
local _upload_delay_seconds
local _server_name

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
    assert(get_phase() == "init", "Statistics configure at init phase")

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

    -- upload delay
    _upload_delay_seconds = opts.upload_delay_seconds or DEFAULT_UPLOAD_DELAY_SECONDS

    _configured = true
    log(INFO, "Influx statistics configure success")
end

-- upload statistics
local function upload(influx)
    -- if cache max count > cfg, may lost some data
    local keys = _cache:get_keys(_cache_cfg.max_count)
    local need_flush = false
    for _, k in pairs(keys) do
        local statistic = _cache:get(k)
        if statistic and statistic.key then
            influx:set_measurement('statistics')
            influx:add_tag("server", _server_name)
            influx:add_tag("event", statistic.key)
            influx:add_tag("app", statistic.app)
            influx:add_tag("category", statistic.category)
            influx:add_tag("action", statistic.action)
            influx:add_tag("result", statistic.result)
            influx:add_field("count", statistic.count)
            influx:add_field("min", statistic.min)
            influx:add_field("max", statistic.max)
            influx:add_field("total", statistic.total)
            influx:add_field("average", statistic.average)
            influx:buffer()

            need_flush = true
        end
    end

    -- clear all
    _cache:flush_all()

    if need_flush then
        local ok, err = influx:flush()
        if not ok then
            log(ERR, "Upload statistics to influxdb fail, error:", err)
        end
    end
end

-- run at each worker
function _M.start()
    assert(get_phase() == "init_worker", "Statistics start at init worker phase")

    if not _configured then
        return
    end

    local influx, err = influx_object:new(_influx_cfg)
    if not influx then
        error("Influxdb initialization failed, error: " .. err or "unknown")
        return
    end

    local check
    check = function(premature)
        if not premature then
            -- upload statistic
            upload(influx)

            local ok, err = new_timer(_upload_delay_seconds, check)
            if not ok then
                log(ERR, "Nginx timer create fail, error: ", err)
                return
            end
        end
    end
    local ok, err = new_timer(_upload_delay_seconds, check)
    if not ok then
        log(ERR, "Nginx timer create fail, error: ", err)
        return
    end

    -- set started status
    _started = true

    log(INFO, "Influx statistics configure success")
end

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

-- add statistical buried point information
function _M.accumulate(app, category, action, result, count, cost)
    if not _configured then
        return
    end

    if not _started then
        log(WARN, "Influx statistics not start or start fail")
        return
    end

    app = app or "*"
    category = category or "*"
    action = action or "*"
    result = result or "*"

    local key = table_concat({ app, "-", category, "-", action, "-", result })
    local statistic = _cache:get(key)
    if statistic == nil then
        statistic = { key = key, app = app, category = category, action = action, result = result,
                      count = 0, min = 0, max = 0, total = 0, average = 0 }
    end
    calculate(statistic, count, cost)

    -- you need to ensure that the statistics are sent to influxdb within
    -- the expiration time, otherwise the statistics may be lost
    _cache:set(key, statistic, _cache_cfg.expire_seconds or DEFAULT_LRU_CACHE_EXPIRE_SECONDS)
end

return _M
