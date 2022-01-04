# vim:set ft= ts=4 sw=4 et:

use strict;
use warnings;

use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);


plan tests => 3 * blocks() * 20;

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_package_path "$pwd/lib/?.lua;;";
_EOC_

repeat_each(20);
no_shuffle();
run_tests();

__DATA__

=== TEST 1: sanity
--- http_config eval
"$::HttpConfig"
. q{
    init_worker_by_lua_block {
        local influx_statistics = require "resty.influx.statistics"

        local opts = {
            enabled = true,
            server_name = "test",
            influx_cfg = {
                host = "127.0.0.1",
                port = 8086,
                db = "test",
                proto = "http",
            },
            cache_cfg = {
                max_items = 1000,
                expire_seconds = 120,
                max_count = 800
            },
            upload_delay_seconds = 1
        }
        influx_statistics.configure(opts)
    }
}

--- config
	location /t {
		content_by_lua_block {
            local influx_statistics = require "resty.influx.statistics"

            local startTime = ngx.now()
            ngx.sleep(1)
            influx_statistics.accumulate('app', 'test', '/t', 'ok', 1, ngx.now() - startTime)

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