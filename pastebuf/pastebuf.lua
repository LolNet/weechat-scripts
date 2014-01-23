local w = weechat
local g = {
   script = {
      name = "pastebuf",
      author = "tomoe-mami <https://github.com/tomoe-mami>",
      version = "0.1",
      license = "WTFPL",
      description = "View text from various pastebin sites inside a buffer.",
      url = "https://github.com/tomoe-mami/weechat-scripts/tree/master/pastebuf"
   },
   config = {},
   defaults = {
      fetch_timeout = {
         value = 30000,
         type = "number",
         description = "Timeout for fetching URL (in milliseconds)"
      },
      highlighter_timeout = {
         value = 3000,
         type = "number",
         description = "Timeout for syntax highlighter (in milliseconds)"
      },
      show_line_number = {
         value = true,
         type = "boolean",
         description = "Show line number"
      },
      color_line_number = {
         value = "default,darkgray",
         type = "string",
         description = "Color for line number"
      },
      color_line = {
         value = "default,default",
         type = "string",
         description = "Color for line content"
      },
      syntax_highlighter = {
         value = "",
         type = "string",
         description =
            "External command that will be used as syntax highlighter. " ..
            "$lang will be replaced by the name of syntax language"
      },
      sticky_notes_retardness_level = {
         value = 1,
         type = "number",
         description =
            "The retardness level of Sticky Notes API. Use level 0 if they " ..
            "somehow fixed their JSON string. Use level 1 to fix their awful " ..
            "JSON string first before decoding it. Use level 2 if level 1 " ..
            "failed fixing their JSON string. In level 2, we'll abandon their " ..
            "API and just fetch the raw paste. Default is 1."
      }
   },
   sites = {
      ["bpaste.net"] = {
         pattern = "^http://bpaste%.net/show/(%w+)",
         raw = "http://bpaste.net/raw/%s/"
      },
      ["codepad.org"] = {
         pattern = "^http://codepad%.org/(%w+)",
         raw = "http://codepad.org/%s/raw.php"
      },
      ["dpaste.com"] = {
         pattern = "^http://dpaste%.com/(%w+)",
         raw = "http://dpaste.com/%s/plain/"
      },
      ["dpaste.de"] = {
         pattern = "^https://dpaste%.de/(%w+)",
         raw = "https://dpaste.de/%s/raw"
      },
      ["fpaste.org"] = {
         pattern = "^http://fpaste%.org/(%w+/?%w*)",
         raw = "http://fpaste.org/%s/raw"
      },
      ["gist.github.com"] = {
         pattern = "^https://gist%.github%.com/([^/]+/[^/]+)",
         raw = "https://gist.github.com/%s/raw"
      },
      ["ideone.com"] = {
         pattern = "^http://ideone%.com/(%w+)",
         raw = "http://ideone.com/plain/%s"
      },
      ["paste.debian.net"] = {
         pattern = "^http://paste%.debian%.net/(%w+)",
         raw = "http://paste.debian.net/plain/%s"
      },
      ["pastebin.ca"] = {
         pattern = "^http://pastebin%.ca/(%w+)",
         raw = "http://pastebin.ca/raw/%s"
      },
      ["pastebin.com"] = {
         pattern = "^http://pastebin%.com/(%w+)",
         raw = "http://pastebin.com/raw.php?i=%s"
      },
      ["pastebin.osuosl.org"] = {
         pattern = "^http://pastebin%.osuosl%.org/(%w+)",
         raw = "http://pastebin.osuosl.org/%s/raw/"
      },
      ["pastie.org"] = {
         raw = "http://pastie.org/pastes/%s/download"
      },
      ["sprunge.us"] = {
         pattern = "^http://sprunge%.us/(%w+)",
         raw = "http://sprunge.us/%s"
      },
      ["vpaste.net"] = {
         pattern = "http://vpaste%.net/(%w+)",
         raw = "http://vpaste.net/%s?raw"
      }
   },
   keys = {
      normal = {
         ["meta2-A"]    = "/window scroll -1",           -- arrow up
         ["meta2-B"]    = "/window scroll 1",            -- arrow down
         ["meta2-C"]    = "/window scroll_horiz 1",      -- arrow right
         ["meta2-D"]    = "/window scroll_horiz -1",     -- arrow left
         ["meta-OA"]    = "/window scroll -10",          -- ctrl+arrow up
         ["meta-OB"]    = "/window scroll 10",           -- ctrl+arrow down
         ["meta-OC"]    = "/window scroll_horiz 10",     -- ctrl+arrow right
         ["meta-OD"]    = "/window scroll_horiz -10",    -- ctrl+arrow left
         ["meta2-1~"]   = "/pastebuf **scroll start",    -- home
         ["meta2-4~"]   = "/pastebuf **scroll end",      -- end
         ["meta-c"]     = "/buffer close",               -- alt+c
      }
   },
   -- NOTE: keep this true until it is clear what caused the stderr output of one process
   -- is included in other process
   hide_stderr = true,
   buffers = {},
   actions = {},
   langs = {
      -- syntax lang aliases.
      none = false,
      plain = false,
      text = false,
      shell = "sh",
      markdown = false
   },
   sgr = {
      attributes = {
         [1] = "*", -- bold
         [3] = "/", -- italic
         [4] = "_", -- underline
         [7] = "!"  -- inverse
      },
      colors = {
         [ 0] = "black",
         [ 1] = "red",
         [ 2] = "green",
         [ 3] = "yellow",
         [ 4] = "blue",
         [ 5] = "magenta",
         [ 6] = "cyan",
         [ 7] = "gray",

         [ 8] = "darkgray",
         [ 9] = "lightred",
         [10] = "lightgreen",
         [11] = "brown",
         [12] = "lightblue",
         [13] = "lightmagenta",
         [14] = "lightcyan",
         [15] = "white"
      }
   }
}

function prepare_modules(modules)
   local module_exists = function (name)
     if package.loaded[name] then
       return true
     else
       for _, searcher in ipairs(package.searchers or package.loaders) do
         local loader = searcher(name)
         if type(loader) == "function" then
           package.preload[name] = loader
           return true
         end
       end
       return false
     end
   end

   for alias, name in pairs(modules) do
      if module_exists(name) then
         _G[alias] = require(name)
      end
   end
end

function convert_plugin_option_value(opt_type, opt_value)
   if opt_type == "number" or opt_type == "boolean" then
      opt_value = tonumber(opt_value)
      if opt_type == "boolean" then
         opt_value = (opt_value ~= 0)
      end
   end
   return opt_value
end

function load_config()
   for opt_name, info in pairs(g.defaults) do
      if w.config_is_set_plugin(opt_name) == 0 then
         local val
         if info.type == "boolean" then
            val = info.value and 1 or 0
         elseif info.type == "number" then
            val = info.value or 0
         else
            val = info.value or ""
            if opt_name == "syntax_highlighter" and val == "" then
               val = nil
            end
         end
         w.config_set_plugin(opt_name, val)
         w.config_set_desc_plugin(opt_name, info.description or "")
         g.config[opt_name] = val
      else
         local val = w.config_get_plugin(opt_name)
         g.config[opt_name] = convert_plugin_option_value(info.type, val)
      end
   end
end

function bind_keys(buffer, flag)
   local prefix = flag and "key_bind_" or "key_unbind_"
   for key, command in pairs(g.keys) do
      w.buffer_set(buffer, prefix .. key, flag and command or "")
   end
end

-- crude converter from csi sgr colors to weechat color
function convert_csi_sgr(text)
   local fg, bg, attr = "", "", "|"

   local shift_param = function(s)
      if s then
         local p1, p2, chunk = s:find("^(%d+);?")
         if p1 then
            return chunk, s:sub(p2 + 1)
         end
      end
   end

   local convert_cb = function(code)
      local chunk, code = shift_param(code)
      while chunk do
         chunk = tonumber(chunk)
         if chunk == 0 then
            attr = ""
         elseif g.sgr.attributes[chunk] then
            attr = g.sgr.attributes[chunk]
         elseif chunk >= 30 and chunk <= 37 then
            fg = g.sgr.colors[ chunk - 30 ]
         elseif chunk == 38 then
            local c2, c3
            c2, code = shift_param(code)
            fg, c2 = "default", tonumber(c2)
            if c2 == 5 then
               c3, code = shift_param(code)
               if c3 then
                  fg = tonumber(c3)
               end
            end
         elseif chunk == 39 then
            fg = "default"
         elseif chunk >= 40 and chunk <= 47 then
            bg = g.sgr.colors[ chunk - 40 ]
         elseif chunk == 48 then
            local c2, c3
            c2, code = shift_param(code)
            bg, c2 = "default", tonumber(c2)
            if c2 == 5 then
               c3, code = shift_param(code)
               if c3 then
                  bg = tonumber(c3)
               end
            end
         elseif chunk == 49 then
            bg = "default"
         elseif chunk >= 90 and chunk <= 97 then
            fg = g.sgr.colors[ chunk - 82 ]
         elseif chunk >= 100 and chunk <= 107 then
            bg = g.sgr.colors[ chunk - 92 ]
         end
         chunk, code = shift_param(code)
      end
      local result
      if fg == "" and bg == "" and attr == "" then
         result = "reset"
      else
         result = attr .. fg
         if bg and bg ~= "" then
            result = result .. "," .. bg
         end
      end
      return w.color(result)
   end

   return text:gsub("\27%[([%d;]*)m", convert_cb)
end

function message(s)
   w.print("", g.script.name .. "\t" .. s)
end

function get_lang(lang)
   if not lang or lang == "" then
      return false
   end
   lang = lang:lower()
   if g.langs[lang] ~= nil then
      lang = g.langs[lang]
   end
   return lang
end

-- false will delete a localvar. nil (or value not specified) will return
-- the current value. anything else will set the localvar to that value.
function localvar(pointer, variable, value)
   if value == nil then
      return w.buffer_get_string(pointer, "localvar_" .. variable)
   elseif value == false then
      w.buffer_set(pointer, "localvar_del_" .. variable, "")
   else
      if value == true then value = 1 end
      w.buffer_set(pointer, "localvar_set_" .. variable, value)
   end
end

function parse_response_header(response)
   local p, c, m, h, r = response:match("^(%S+) (%d+) (.-)\r\n(.-)\r\n\r\n(.*)$")
   if p then
      c = tonumber(c)
      if c == 301 or c == 302 or c == 303 then
         if r ~= "" then
            -- since we use followlocation=1, there will be another block of header
            -- after the first empty line. parse that one instead.
            return parse_response_header(r)
         end
      end

      local result = {
         protocol = p,
         status_code = c,
         status_message = m
      }

      if h then
         result.headers = {}
         h = h .. "\r\n"
         for name, value in h:gmatch("([^:]+):%s+(.-)\r\n") do
            result.headers[name] = value
         end
      end
      return result
   end
end

function exec_generic_cb(short_name, cmd, status, response, err)
   local buffer = g.buffers[short_name]
   if not buffer then
      return
   end
   if status == 0 or status == w.WEECHAT_HOOK_PROCESS_RUNNING then
      buffer.temp = buffer.temp .. response
      if buffer.callback_partial and type(buffer.callback_partial) == "function" then
         buffer.callback_partial(buffer, short_name, response)
      end
      if status == 0 then
         local data = buffer.temp
         buffer.temp = nil
         if buffer.callback_ok and type(buffer.callback_ok) == "function" then
            buffer.callback_ok(buffer, short_name, data)
         end
      end
   elseif status >= 1 or status == w.WEECHAT_HOOK_PROCESS_ERROR then
      if (cmd:sub(1, 4) ~= "url:" and g.hide_stderr) or not err or err == "" then
         err = "Error when trying to access " .. cmd
      end
      message(string.format("Error %d: %s", status, err))
      if buffer.callback_error and type(buffer.callback_error) == "function" then
         buffer.callback_error(buffer, short_name, status, err)
      end
   end
end

function exec_generic(short_name, cmd, options, callbacks)
   local buffer = g.buffers[short_name]
   buffer.temp = ""
   if callbacks then
      local cb_type = type(callbacks)
      local types = { ok = true, error = true, partial = true, input = true }
      if cb_type == "function" then
         buffer.callback_ok = callbacks
      elseif cb_type == "table" then
         for t, f in pairs(callbacks) do
            if type(f) == "function" and types[t] then
               buffer["callback_" .. t] = f
            end
         end
      end
   end
   if cmd:sub(1,4) == "url:" and options then
      if not options.useragent then
         options.useragent = g.useragent
      end
      if not options.followlocation then
         options.followlocation = 1
      end
   end

   if options then
      buffer.hook = w.hook_process_hashtable(
         cmd,
         options,
         g.config.fetch_timeout,
         "exec_generic_cb",
         short_name)

      if options.stdin and options.stdin == 1 and buffer.callback_input then
         buffer.callback_input(buffer, short_name, buffer.hook)
      end
   else
      buffer.hook = w.hook_process(
         cmd,
         g.config.fetch_timeout,
         "exec_generic_cb",
         short_name)
   end
   return buffer.hook
end

function request_head(short_name, url, options, callbacks)
   if not options then
      options = {}
   end
   options.nobody = 1
   options.header = 1
   exec_generic(short_name, "url:" .. url, options, callbacks)
end

function get_site_config(u)
   local host = u:match("^https?://([^/]+)")
   if host then
      if host:match("^www%.") then
         host = host:sub(5)
      end
      if g.sites[host] then
         local site = g.sites[host]
         site.host = host
         if site.handler then
            site.url = u
            return site
         else
            local id = u:match(site.pattern)
            if id then
               site.id = id
               site.url = u
               return site
            end
         end
      end
   end
end

function init_mode(buf_ptr, mode)
   local prev_mode = localvar(buf_ptr, "mode")
   for key, _ in pairs(g.keys[prev_mode]) do
      w.buffer_set(buf_ptr, "key_unbind_" .. key, "")
   end
   for key, cmd in pairs(g.keys[mode]) do
      w.buffer_set(buf_ptr, "key_bind_" .. key, cmd)
   end
   localvar(buf_ptr, "mode", mode)
end

function action_scroll(buffer, short_name, param)
   if param == "start" then
      w.command(buffer.pointer, "/window scroll_top")
      w.command(buffer.pointer, "/window scroll_horiz -100%")
   elseif param == "end" then
      w.command(buffer.pointer, "/window scroll_bottom")
      w.command(buffer.pointer, "/window scroll_horiz -100%")
   end
end

function action_save(buffer, short_name, filename)
   if not filename or filename == "" then
      message("You need to specify destination filename after `save`")
   else
      filename = filename:gsub("^~/", os.getenv("HOME") .. "/")
      local output = open_file(filename, "w")
      if output then
         local input = open_file(buffer.temp_name)
         if input then
            local chunk_size, written, chunk = 64 * 1024, 0
            chunk = input:read(chunk_size)
            while chunk do
               output:write(chunk)
               written = written + #chunk
               chunk = input:read(chunk_size)
            end
            input:close()
            message(string.format(
               "%d %s written to %s",
               written,
               (written == 1 and "byte" or "bytes"),
               filename))
         end
         output:close()
      end
   end
end

function action_change_language(buffer, short_name, new_lang)
   if not g.config.syntax_highlighter then
      return
   end

   new_lang = new_lang:match("^%s*(%S+)")
   if not new_lang then
      message("You need to specify the name of syntax language after `lang`")
   else
      local current_lang = localvar(buffer.pointer, "lang") or ""
      new_lang = get_lang(new_lang)
      if current_lang ~= new_lang then
         local fp = open_file(buffer.temp_name)
         if fp then
            buffer.file = fp
            if new_lang then
               localvar(buffer.pointer, "lang", new_lang)
               run_syntax_highlighter(short_name, fp)
            else
               localvar(buffer.pointer, "lang", false)
               display_plain(short_name, fp)
            end
            fp:close()
            buffer.file = nil
         end
      end
   end
end

function action_open_recent_url(current_buffer, limit)
   local list = {}
   limit = tonumber(limit)
   if not limit or limit == 0 then
      limit = 1
   end

   local buf_lines = w.infolist_get("buffer_lines", current_buffer, "")
   if buf_lines and buf_lines ~= "" then

      local url_matcher = "(https?://[%w:!/#_~@&=,;%+%?%[%]%.%%%-]+)"
      local process_line = function ()
         if w.infolist_integer(buf_lines, "displayed") ~= 1 then
            return 0
         end
         local line = w.infolist_string(buf_lines, "message")
         line = w.string_remove_color(line, "")
         local url = line:match(url_matcher)
         if not url then
            return 0
         end
         local site = get_site_config(url)
         if site then
            if site.handler and type(site.handler) == "function" then
               site.handler(site, url)
            else
               handler_normal(site, url)
            end
            return 1
         end
         return 0
      end

      w.infolist_prev(buf_lines)
      local c = process_line()
      while c < limit do
         if w.infolist_prev(buf_lines) ~= 1 then break end
         c = c + process_line()
      end
      w.infolist_free(buf_lines)
      if not c or c == 0 then
         message("No URLs from supported paste services found")
      end
   end
end

function create_buffer(site)
   local short_name
   if site.short_name then
      short_name = site.short_name
   else
      short_name = string.format("%s:%s", site.host, site.id)
   end
   local name = string.format("%s:%s", g.script.name, short_name)
   local buffer = w.buffer_new(name, "buffer_input_cb", "", "buffer_close_cb", "")

   if buffer and buffer ~= "" then
      local default_mode = "normal"
      w.buffer_set(buffer, "type", "free")
      w.buffer_set(buffer, "short_name", short_name)
      w.buffer_set(buffer, "display", "1")
      localvar(buffer, "mode", default_mode)
      init_mode(buffer, default_mode)

      g.buffers[short_name] = { pointer = buffer }
      return g.buffers[short_name], short_name
   end
end

function display_plain(short_name, fp)
   local pointer = g.buffers[short_name].pointer
   local total_lines = 0

   if g.config.show_line_number then
      local lines, total_lines = {}, 0
      for line in fp:lines() do
         total_lines = total_lines + 1
         lines[total_lines] = line
      end

      if total_lines > 0 then
         w.buffer_clear(pointer)
         local num_col_width = #tostring(total_lines)
         local y = 0
         for _, line in ipairs(lines) do
            print_line(pointer, y, num_col_width, line)
            y = y + 1
         end
      end
   else
      for line in fp:lines() do
         print_line(pointer, total_lines, nil, line)
         total_lines = total_lines + 1
      end
   end
end

function run_syntax_highlighter(short_name, fp)
   local buffer = g.buffers[short_name]
   local cmd = w.buffer_string_replace_local_var(
      buffer.pointer,
      g.config.syntax_highlighter)

   local input_cb = function (_, _, hook)
      for line in fp:lines() do
         w.hook_set(hook, "stdin", line .. "\n")
      end
      w.hook_set(hook, "stdin_close", "")
   end

   local complete_cb = function (_, _, data)
      local y, num_col_width = 0
      data = convert_csi_sgr(data)
      if g.config.show_line_number then
         local _, total_lines = string.gsub(data .. "\n", ".-\n[^\n]*", "")
         num_col_width = #tostring(total_lines)
      end
      w.buffer_clear(buffer.pointer)
      for line in data:gmatch("(.-)\n") do
         print_line(buffer.pointer, y, num_col_width, line)
         y = y + 1
      end
   end

   exec_generic(
      short_name,
      cmd,
      { stdin = 1 },
      {
         ok = complete_cb,
         input = input_cb
      });
end

function open_file(filename, mode)
   local fp = io.open(filename, mode or "r")
   if not fp then
      message(string.format("Unable to open file %s", filename))
   else
      return fp
   end
end

function write_temp(data)
   local temp_name = os.tmpname()
   local fp = open_file(temp_name, "w+")
   if fp then
      fp:write(data)
      fp:seek("set")
      return fp, temp_name
   end
end

function display_paste(short_name)
   local buffer = g.buffers[short_name]
   local fp = open_file(buffer.temp_name)
   if fp then
      buffer.file = fp
      local lang = get_lang(localvar(buffer.pointer, "lang"))
      if g.config.syntax_highlighter and lang then
         run_syntax_highlighter(short_name, fp)
      else
         display_plain(short_name, fp)
      end
      fp:close()
      buffer.file = nil

      localvar(buffer.pointer, "temp", buffer.temp_name)
      w.buffer_set(
         buffer.pointer,
         "title",
         string.format("%s: %s", g.script.name, localvar(buffer.pointer, "url")))
   end
end

function print_line(buffer, y, num_width, content)
   local line = w.color(g.config.color_line) .. " " .. content
   if num_width then
      line = string.format(
         "%s %" .. num_width .. "d %s",
         w.color(g.config.color_line_number),
         y + 1,
         line)
   end
   w.print_y(buffer, y, line)
end

function decode_json_response(s)
   if not s or s == "" then
      message("Error: No response received")
   else
      local decoded = json.decode(s)
      if not decoded or type(decoded) ~= "table" then
         message("Error: Unable to parse server response")
      else
         return decoded
      end
   end
end

function handler_sticky_notes(site, url, lang)
   local id, hash = url:match("^https?://[^/]+/(%w+)/?(%w*)")
   if id then
      site.id = id
      local short_name = string.format("%s:%s", site.host, id)
      if not g.buffers[short_name] then
         g.buffers[short_name] = { host = site.host, url = url }
         local api_url = string.format("http://%s/api/json/%s", site.host, site.id)
         if hash then
            api_url = api_url .. "/" .. hash

            local fix_json = function (json_string)
               return json_string:gsub('"data":%s*"(.-)"', function (s)
                  s = s:gsub("\\", "\\\\")
                  s = s:gsub(
                     "([\t\n\r\b\f])",
                     {
                        ["\t"] = "\\t", ["\n"] = "\\n",
                        ["\r"] = "\\r", ["\b"] = "\\b",
                        ["\f"] = "\\f"
                     })

                  s = s:gsub(
                     "&([^;]+);",
                     { lt = "<", gt = ">", quot = '\\"', amp = "&" })

                  return string.format('"data": "%s"', s)
               end)
            end

            local process_info = function (buffer, short_name, data)
               if g.config.sticky_notes_retardness_level == 1 then
                  data = fix_json(data)
               end
               local info = decode_json_response(data)
               if not info then
                  if g.buffers[short_name] then
                     g.buffers[short_name] = nil
                  end
                  return
               end

               if info.result.error then
                  message(string.format("Error: %s", info.result.error))
               else
                  local param = {
                     short_name = short_name,
                     url = buffer.url,
                     host = buffer.host
                  }
                  local buffer = create_buffer(param)
                  if not buffer then return end

                  localvar(buffer.pointer, "url", param.url)
                  localvar(buffer.pointer, "host", param.host)
                  localvar(buffer.pointer, "id", param.id)

                  w.buffer_set(
                     buffer.pointer,
                     "title",
                     string.format("%s: %s", g.script.name, param.url))

                  local use_highlighter = false
                  if info.result.language and
                     info.result.language ~= json.null and
                     info.result.language ~= "" then
                     local lang = get_lang(info.result.language)
                     if lang then
                        localvar(buffer.pointer, "lang", lang)
                        if g.config.syntax_highlighter then
                           use_highlighter = true
                        end
                     end
                  end

                  buffer.file, buffer.temp_name = write_temp(info.result.data)
                  if buffer.file then
                     if use_highlighter then
                        run_syntax_highlighter(short_name, buffer.file)
                     else
                        display_plain(short_name, buffer.file)
                     end
                     buffer.file:close()
                     buffer.file = nil
                  end
               end
            end

            local on_error = function (buffer, short_name, status, message)
               g.buffers[short_name] = nil
            end

            exec_generic(short_name, "url:" .. api_url, {}, { ok = process_info, error = on_error })
         end
      end
   end
end

function handler_gist(site, url)
   local first, second = url:match("^https://gist%.github%.com/([^/]+)/?([^/]*)")
   local host, gist_id = "gist.github.com"

   if second and second ~= "" then
      gist_id = second
   elseif first then
      gist_id = first
   else
      message("Unrecognized gist url")
      return w.WEECHAT_RC_ERROR
   end

   local short_name = string.format("%s:%s", host, gist_id)
   if not g.buffers[short_name] then
      g.buffers[short_name] = {}
      local api_url = string.format("https://api.github.com/gists/%s", gist_id)

      local display_entry = function (entry)
         local entry_buffer, entry_short_name = create_buffer({
               host = host,
               id = string.format("%s/%s", gist_id, entry.filename)
            })

         if entry_buffer then
            local title = string.format(
               "%s: %s (file: %s)",
               g.script.name,
               url,
               entry.filename)

            if entry.description then
               title = string.format("%s [%s]", title, entry.description)
            end
            w.buffer_set(entry_buffer.pointer, "title", title)

            local use_highlighter = false
            if entry.language and
               entry.language ~= json.null and
               entry.language ~= "" then
               local lang = get_lang(entry.language)
               if lang then
                  localvar(entry_buffer.pointer, "lang", lang)
                  if g.config.syntax_highlighter then
                     use_highlighter = true
                  end
               end
            end

            entry_buffer.parent = short_name
            entry_buffer.file, entry_buffer.temp_name = write_temp(entry.content)
            if entry_buffer.file then
               if use_highlighter then
                  run_syntax_highlighter(entry_short_name, entry_buffer.file)
               else
                  display_plain(entry_short_name, entry_buffer.file)
               end
               entry_buffer.file:close()
               entry_buffer.file = nil
            end
            return entry_buffer, entry_short_name
         end
      end

      local process_info = function (buffer, short_name, data)
         local info = decode_json_response(data)
         if not info then
            if g.buffers[short_name] then
               g.buffers[short_name] = nil
            end
            return
         end

         if info.message then
            message(string.format("Gist error: %s", info.message))
            g.buffers[short_name] = nil
         else

            if info.files and type(info.files) == "table" then
               buffer.sub = {}
               local description
               if info.description and info.description ~= json.null then
                  description = info.description:gsub("[\r\n]+", " ")
               end

               for _, entry in pairs(info.files) do
                  entry.description = description
                  local sub_buffer, sub_short_name = display_entry(entry)
                  if sub_buffer then
                     buffer.sub[sub_short_name] = sub_buffer.pointer
                  end
               end

            end
         end
      end

      local on_error = function (buffer, short_name, status, message)
         g.buffers[short_name] = nil
      end

      exec_generic(short_name, "url:" .. api_url, {}, { ok = process_info, error = on_error })
   else
      message("Gist is already opened. Close all buffers related to this " ..
              "gist first before making another request")
   end
   return w.WEECHAT_RC_OK
end

function detect_lang_from_query(url, host)
   local pattern = "%?(.+)$"
   if host == "sprunge.us" then
      return url:match(pattern)
   elseif host == "vpaste.net" then
      local query = url:match(pattern)
      if not query then return end

      for var, value in query:gmatch("([^=]+)=([^&]+)") do
         if var == "ft" then
            return value
         end
      end
   end
end

function handler_normal(site, url, lang)
   local short_name = string.format("%s:%s", site.host, site.id)
   if g.buffers[short_name] then
      local pointer = g.buffers[short_name].pointer
      if pointer then
         w.buffer_set(pointer, "display", "1")
      end
   else
      local buffer, short_name = create_buffer(site)
      if not buffer.hook then
         local raw_url = string.format(site.raw, site.id)
         local title = string.format("%s: Fetching %s", g.script.name, site.url)

         w.buffer_set(buffer.pointer, "title", title)

         localvar(buffer.pointer, "url", url)
         localvar(buffer.pointer, "host", site.host)
         localvar(buffer.pointer, "id", site.id)

         if not lang or lang == "" then
            lang = detect_lang_from_query(url, site.host)
         end
         lang = get_lang(lang)
         if lang then
            localvar(buffer.pointer, "lang", lang)
         end

         local receive_paste = function (buffer, short_name, data)
            buffer.hook = nil
            display_paste(short_name)
         end

         local send_request = function (buffer, short_name)
            buffer.temp_name = os.tmpname()
            exec_generic(
               short_name,
               "url:" .. raw_url,
               { file_out = buffer.temp_name },
               receive_paste)
         end

         local prepare_request = function (buffer, short_name, data)
            buffer.hook = nil
            local response = parse_response_header(data)
            if response then
               if response.status_code == 200 then
                  send_request(buffer, short_name)
               else
                  local title = string.format(
                     "%s: %sError %d: %s (URL: %s)",
                     g.script.name,
                     w.color("chat_prefix_error"),
                     response.status_code,
                     response.status_message,
                     raw_url)

                  w.buffer_set(buffer.pointer, "title", title)
                  w.buffer_set(buffer.pointer, "hotlist", w.WEECHAT_HOTLIST_LOW)
               end
            end
         end

         if site.host == "sprunge.us" then
            -- sprunge doesn't allow HEAD method
            send_request(buffer, short_name)
         else
            request_head(short_name, raw_url, nil, prepare_request)
         end
      end
   end
   return w.WEECHAT_RC_OK
end

function handler_pastie(site, url, lang)
   local first, second = url:match("^http://pastie%.org/(%w+)/?(%w*)")
   local pastie_id
   if first == "pastes" and second and second ~= "" then
      pastie_id = second
   else
      pastie_id = first
   end

   site = {
      url = url,
      raw = site.raw,
      host = "pastie.org",
      id = pastie_id
   }

   return handler_normal(site, url, lang)
end

function open_paste(url, lang)
   local site = get_site_config(url)
   if not site then
      message("Unsupported site: " .. url)
      return w.WEECHAT_RC_ERROR
   end

   if site.handler and type(site.handler) == "function" then
      return site.handler(site, url, lang)
   else
      return handler_normal(site, url, lang)
   end
end

function run_action(buf_ptr, action, param)
   if not g.actions[action] then
      message(string.format("Unknown action: %s", action))
      return
   end

   if action == "open-recent-url" then
      return g.actions[action](buf_ptr, param)
   else
      local short_name = w.buffer_get_string(buf_ptr, "short_name")
      if not g.buffers[short_name] then
         message("Special commands can only be called inside paste buffer")
         return
      end
      return g.actions[action](g.buffers[short_name], short_name, param)
   end
end

function command_cb(_, current_buffer, param)
   local first, second = param:match("^%s*(%S+)%s*(%S*)")
   if not first then
      w.command(current_buffer, "/help " .. g.script.name)
   else
      if first:sub(1, 2) == "**" then
         run_action(current_buffer, first:sub(3), second)
      else
         open_paste(first, second)
      end
   end
   return w.WEECHAT_RC_OK
end

function config_cb(_, opt_name, opt_value)
   local name = opt_name:match("^plugins%.var%.lua%." .. g.script.name .. "%.(.+)$")
   if name and g.defaults[name] then
      g.config[name] = convert_plugin_option_value(g.defaults[name].type, opt_value)
      if name == "sticky_notes_retardness_level" then
         if g.config[name] < 2 then
            g.sites["fpaste.org"].handler = handler_sticky_notes
            g.sites["pastebin.osuosl.org"].handler = handler_sticky_notes
         else
            g.sites["fpaste.org"].handler = nil
            g.sites["pastebin.osuosl.org"].handler = nil
         end
      elseif name == "syntax_highlighter" then
         if g.config[name] == "" then
            g.config[name] = nil
         end
      end
   end
end

function buffer_input_cb(_, pointer, input)
   local action, param = input:match("^%s*(%S+)%s*(.*)%s*$")
   if action then
      return run_action(pointer, action, param)
   end
   return w.WEECHAT_RC_OK
end

function buffer_close_cb(_, buffer)
   local short_name = w.buffer_get_string(buffer, "short_name")
   if g.buffers[short_name] then
      local buffer = g.buffers[short_name]
      if buffer.hook and buffer.hook ~= "" then
         w.unhook(buffer.hook)
      end
      if buffer.file and io.type(buffer.file) == "file" then
         buffer.file:close()
      end
      if buffer.temp_name then
         os.remove(buffer.temp_name)
      end
      if buffer.parent and g.buffers[buffer.parent] then
         local p = buffer.parent
         if g.buffers[p].sub and g.buffers[p].sub[short_name] then
            g.buffers[p].sub[short_name] = nil
            local sibling_exists = false
            for _ in pairs(g.buffers[p].sub) do
               sibling_exists = true
               break
            end
            if not sibling_exists then
               g.buffers[p] = nil
            end
         end
      end
      g.buffers[short_name] = nil
   end
end

function buffer_mod_cb(_, buffer, command)
   local short_name = w.buffer_get_string(buffer, "short_name")
   if g.buffers[short_name] then
      message("Please don't modify paste buffer's properties")
      return w.WEECHAT_RC_OK_EAT
   else
      return w.WEECHAT_RC_OK
   end
end

function setup()
   w.register(
      g.script.name,
      g.script.author,
      g.script.version,
      g.script.license,
      g.script.description,
      "", "")

   local weechat_version = tonumber(w.info_get("version_number", "") or 0)
   if weechat_version < 0x00040300 then
      message("This script requires Weechat v0.4.3 or newer")
      return
   end

   prepare_modules({ json = "cjson" })
   load_config()

   if json then
      g.sites["gist.github.com"].handler = handler_gist
      if g.config.sticky_notes_retardness_level < 2 then
         g.sites["fpaste.org"].handler = handler_sticky_notes
         g.sites["pastebin.osuosl.org"].handler = handler_sticky_notes
      end
   end
   g.sites["pastie.org"].handler = handler_pastie
   g.useragent = string.format(
      "%s v%s (%s)",
      g.script.name,
      g.script.version,
      g.script.url)

   g.actions = {
      lang = action_change_language,
      save = action_save,
      ["open-recent-url"] = action_open_recent_url,
      scroll = action_scroll
   }

   local sites = {}
   for name, info in pairs(g.sites) do
      local entry = name
      if name == "gist.github.com" or
         name == "fpaste.org" or
         name == "pastebin.osuosl.org" then
         local flag = (info.handler and "with" or "no")
         entry = string.format("%s (%s API)", entry, flag)
      end
      table.insert(sites, entry)
   end

   local supported_sites = ""
   if #sites > 0 then
      supported_sites = "\n\nSupported sites: " .. table.concat(sites, ", ")
   end

   w.hook_config("plugins.var.lua." .. g.script.name .. ".*", "config_cb", "")
   w.hook_command_run("9001|/buffer set *", "buffer_mod_cb", "")
   w.hook_command(
      g.script.name,
      "View the content of a paste inside a buffer" .. supported_sites,
      "<paste-url> [<syntax-language>] | **open-recent-url [<n>]",
      string.format([[
paste-url:              URL of the paste
syntax-language:        Optional language for syntax highlighting
%s**open-recent-url%s <n>:  Open <n> recent pastebin URLs that are mentioned
                        inside current buffer. Default value for <n> is 1.


Inside a paste buffer you can use the following commands:

%slang%s <syntax-language>

   Change the active syntax language for current buffer.
   Use %snone%s to set it to plain text.

%ssave%s <filename>

   Save the content of current buffer into a file.


Keyboard shortcuts for navigating inside paste buffer:

Alt+C                         Close current buffer
Up, Down, Left, Right         Scroll buffer 1 line/char
Ctrl+(Up/Down/Left/Right)     Scroll buffer 10 lines/chars
Home                          Scroll to the start of buffer
End                           Scroll to the end of buffer
]],
   w.color("bold"),
   w.color("-bold"),
   w.color("bold"),
   w.color("-bold"),
   w.color("bold"),
   w.color("-bold"),
   w.color("bold"),
   w.color("-bold")),

      "**open-recent-url",
      "command_cb",
      "")
end

setup()