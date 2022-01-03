OPENRESTY_INSTALL_DIR ?= /usr/local/openresty

.PHONY: all luacheck test install

all: ;

luacheck:
	luacheck lib/resty/influx/statistics.lua
	@echo ""

luareleng:
	util/lua-releng
	@echo ""

test: luareleng luacheck
	prove -I../test-nginx/lib -r -s t/
