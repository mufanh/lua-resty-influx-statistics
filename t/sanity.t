use strict;
use warnings;
use Test::Nginx::Socket::Lua;

plan tests => 3 * blocks() + 2;

no_shuffle();
run_tests();

__DATA__

=== TEST 1: sanity
--- http_config
init_worker_by_lua_block {
    local influx_statistics = require "resty.influx.statistics"

    local opts = {
        enabled = true,
        server_name = "test",
        influx_cfg = {
            host = "127.0.0.1",
            port = 12345,
            db = "test",
            proto = "http",
        },
        cache_cfg = {
            max_items = 1000,
            expire_seconds = 120,
            max_count = 800
        },
        upload_delay_seconds = 60
    }
    influx_statistics.configure(opts)
}

--- config
	location /t {
		content_by_lua_block {
            local influx_statistics = require "resty.influx.statistics"

            local startTime = os.clock()
            influx_statistics.accumulate('app', 'test', '/t', 'ok', 1, os.clock() - startTime)

            ngx.say('ok')
		}
	}
--- request
GET /t
--- error_code: 200
--- response_body
ok
--- no_error_log
[error]