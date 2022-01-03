-- Configuration file for LuaCheck
-- see: https://luacheck.readthedocs.io/en/stable/
--
-- To run do: `luacheck .` from the repo

std             = "ngx_lua"
unused_args     = false
redefined       = false
max_line_length = false

globals = {
}

not_globals = {
}

ignore = {
}

exclude_files = {
}