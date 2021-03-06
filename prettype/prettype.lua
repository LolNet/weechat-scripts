local w = weechat
local pcre = require "rex_pcre"
local unicode = require "unicode"

local g = {
   script = {
      name = "prettype",
      author = "tomoe-mami <https://github.com/tomoe-mami>",
      license = "WTFPL",
      version = "0.3",
      description = "Prettify text you typed with auto-capitalization and proper unicode symbols"
   },
   config = {
      nick_completer = ":",
      mode_color = "lightgreen"
   },
   diacritic_tags = {
      s = 0x0336,
      u = 0x0332
   },
   utf8_flag = pcre.flags().UTF8,
   hooks = {},
   mode = ""
}

function u(...)
   local result = ""
   for _, c in ipairs(arg) do
      if type(c) == "number" then
         c = unicode.utf8.char(c)
      end
      result = result .. c
   end
   return result
end

function combine(tag, text)
   if not g.diacritic_tags[tag] then
      return text
   end
   return pcre.gsub(
      text,
      "(.)",
      u("%1", g.diacritic_tags[tag]),
      nil,
      g.utf8_flag)
end

function convert_mnemonics(prefix, code)
   if not g.mnemonics[code] then
      return prefix .. code
   else
      return u(g.mnemonics[code])
   end
end

function convert_codepoint(s)
   return u(tonumber(s, 16))
end

function replace_patterns(text)
   for _, p in ipairs(g.replacements) do
      text = pcre.gsub(text, p[1], p[2], nil, g.utf8_flag)
   end
   return text
end

function protect_url(text)
   return pcre.gsub(
      text,
      "(^|\\s)([a-z][a-z0-9-]+://)([-a-zA-Z0-9+&@#/%?=~_|\\[\\]\\(\\)!:,\\.;]*[-a-zA-Z0-9+&@#/%=~_|\\[\\]])?($|\\W)",
      "%1`%2%3`%4",
      nil,
      g.utf8_flag)
end

function protect_nick_completion(text, buffer)
   if g.config.nick_completer and g.config.nick_completer ~= "" then
      text = text:gsub(
         "^([^%s]+)(%" .. g.config.nick_completer .. "%s*)",
         function (nick, suffix)
            local result = nick .. suffix
            local nick_ptr = w.nicklist_search_nick(buffer, "", nick)
            if nick_ptr ~= "" then
               return "`" .. result .. "`"
            else
               return result
            end
         end)
   end
   return text
end

function process(text, buffer)
   local placeholders, index = {}, 0
   text = protect_url(text)
   text = protect_nick_completion(text, buffer)

   text = text:gsub("`([^`]+)`", function (s)
      index = index + 1
      placeholders[index] = s
      return "\027\016" .. index .. "\027\016"
   end)

   text = replace_patterns(text)

   text = text:gsub("\027\016(%d+)\027\016", function (i)
      i = tonumber(i)
      return placeholders[i] or ""
   end)

   return text
end

function remove_weechat_escapes(text)
   text = pcre.gsub(text, "\\x19(b[FDBl_#-]|E|\\x1c|[FB*]?[*!/_|]?(\\d{2}|@\\d{5})(,(\\d{2}|@\\d{5}))?)", "")
   return text
end

function input_return_cb(_, buffer, cmd)
   local current_input = w.buffer_get_string(buffer, "input")
   if w.string_is_command_char(current_input) ~= 1 then
      local text = w.buffer_get_string(buffer, "localvar_prettype")
      text = remove_weechat_escapes(text)
      w.buffer_set(buffer, "input", text)
   end
   return w.WEECHAT_RC_OK
end

function input_text_display_cb(_, modifier, buffer, text)
   if w.string_is_command_char(text) ~= 1 then
      text = process(text, buffer)
      w.buffer_set(buffer, "localvar_set_prettype", text)
   end
   return text
end

function cmd_send_original(buffer)
   local input = w.buffer_get_string(buffer, "input")
   if input ~= "" then
      w.buffer_set(buffer, "localvar_set_prettype", input)
      w.command(buffer, "/input return")
   end
end

function init_capture_mode(n)
   if g._fixed_length_param then
      set_capture_mode(false)
   else
      set_capture_mode(true, n)
   end
end

function set_capture_mode(flag, buffer, max_chars, callback)
   if flag and not g._capture_param then
      g._capture_param = {
         count = 0,
         max_chars = max_chars,
         start_cursor_pos = w.buffer_get_integer(buffer, "input_pos"),
         callback = callback
      }
      g.hooks.capture = {
         w.hook_command_run("/input *", "capture_cancel_cb", "cmd"),
         w.hook_signal("buffer_switch", "capture_cancel_cb", "buf"),
         w.hook_signal("window_switch", "capture_cancel_cb", "win"),
         w.hook_signal("input_text_changed", "capture_input_cb", ""),
      }
   else
      for _, hook_ptr in ipairs(g.hooks.capture) do
         w.unhook(hook_ptr)
      end
      g.hooks.capture = nil
      g._capture_param = nil
      g.mode = nil
   end
   w.bar_item_update(g.script.name .. "_mode")
end

function capture_input_cb(_, _, buffer)
   local input = w.buffer_get_string(buffer, "input")
   local param = g._capture_param
   if not param then
      return w.WEECHAT_RC_OK
   end

   if unicode.utf8.len(input) > param.start_cursor_pos and
      param.count < param.max_chars then

      param.count = param.count + 1
      if param.count >= param.max_chars then
         local pos1 = param.start_cursor_pos + 1
         local pos2 = pos1 + param.max_chars - 1
         local chars = unicode.utf8.sub(input, pos1, pos2)
         if unicode.utf8.len(chars) >= param.max_chars then
            local replacement = param.callback(chars)
            if replacement then
               local left = unicode.utf8.sub(input, 1, param.start_cursor_pos) or ""
               local right = unicode.utf8.sub(input, pos2 + 1) or ""
               w.buffer_set(buffer, "input", left .. replacement .. right)
               w.buffer_set(buffer, "input_pos", param.start_cursor_pos + 1)
            end
            set_capture_mode(false)
         end
      end

   end
   return w.WEECHAT_RC_OK
end

function capture_cancel_cb(mode)
   set_capture_mode(false)
   if mode == "cmd" then
      return w.WEECHAT_RC_OK_EAT
   else
      return w.WEECHAT_RC_OK
   end
end

function cmd_input_mnemonic(buffer, args)
   if not args or args == "" then
      args = 2
   end
   local max_chars = tonumber(args)
   if max_chars < 2 or max_chars > 6 then
      max_chars = 2
   end
   g.mode = string.format("Mnemonic (%d)", max_chars)
   set_capture_mode(true, buffer, max_chars, function (s)
      if g.mnemonics[s] then
         return u(g.mnemonics[s])
      end
   end)
end

function cmd_input_codepoint(buffer, args)
   g.mode = "UTF-8 Codepoint"
   set_capture_mode(true, buffer, 4, function (s)
      return convert_codepoint(s)
   end)
end

function command_cb(_, buffer, param)
   local action, args = param:match("^(%S+)%s*(.*)")
   if action then
      local callbacks = {
         ["send-original"] = cmd_send_original,
         mnemonic = cmd_input_mnemonic,
         codepoint = cmd_input_codepoint
      }

      if callbacks[action] then
         callbacks[action](buffer, args)
      end
   end
   return w.WEECHAT_RC_OK
end

function bar_item_cb()
   if not g.mode or g.mode == "" then
      return ""
   else
      return w.color(g.config.mode_color) .. g.mode
   end
end

function config_cb(_, opt_name, opt_value)
   if opt_name == "weechat.completion.nick_completer" then
      g.config.nick_completer = opt_value
   elseif opt_name == "plugins.var.lua.prettype.mode_color" then
      g.config.mode_color = opt_value
   end
   return w.WEECHAT_RC_OK
end

function init_config()
   local opt = w.config_get("weechat.completion.nick_completer")
   if opt and opt ~= "" then
      g.config.nick_completer = w.config_string(opt)
   end

   if w.config_is_set_plugin("mode_color") ~= 1 then
      w.config_set_plugin("mode_color", g.config.mode_color)
   else
      g.config.mode_color = w.config_get_plugin("mode_color")
   end

   w.hook_config("weechat.completion.nick_completer", "config_cb", "")
   w.hook_config("plugins.var.lua.prettype.mode_color", "config_cb", "")
end

function setup()
   assert(
      w.register(
         g.script.name,
         g.script.author,
         g.script.version,
         g.script.license,
         g.script.description,
         "", ""),
      "Unable to register script. Perhaps it has been loaded before?")

   init_config()
   w.hook_command_run("/input return", "input_return_cb", "")
   w.hook_modifier("input_text_display_with_cursor", "input_text_display_cb", "")
   w.bar_item_new(g.script.name .. "_mode", "bar_item_cb", "")
   w.hook_command(
      g.script.name,
      "Control prettype script.",
      "send-original || mnemonic [<n-chars>] || codepoint",
[[
   send-original: Send the original text instead of the modified version.
        mnemonic: Insert RFC 1345 Character Mnemonics (http://tools.ietf.org/html/rfc1345)
       codepoint: Insert UTF-8 codepoint
       <n-chars>: Numbers of character that will be interpreted as mnemonic. If not specified
                  or if it's out of range (less than 2 or larger than 6) it will fallback to
                  the default value (2).
]],
      "send-original || mnemonic || codepoint",
      "command_cb",
      "")
end

g.replacements = {
   { "(^\\s+|\\s+$)",                        "" },
   { "\\.{3,}",                              u(0x2026, " ")},
   { "-{3}",                                 u(0x2014) },
   { "-{2}",                                 u(0x2013) },
   { "<-",                                   u(0x2190) },
   { "->",                                   u(0x2192) },
   { "<<",                                   u(0x00ab) },
   { ">>",                                   u(0x00bb) },
   { "\\+-",                                 u(0x00b1) },
   { "===",                                  u(0x2261) },
   { "(!=|=/=)",                             u(0x2260) },
   { "<=",                                   u(0x2264) },
   { ">=",                                   u(0x2265) },
   { "(?i:\\(r\\))",                         u(0x00ae) },
   { "(?i:\\(c\\))",                         u(0x00a9) },
   { "(?i:\\(tm\\))",                        u(0x2122) },
   { "(\\d+)\\s*x\\s*(\\d+)",                u("%1 ", 0x00d7, " %2") },
   { "[.?!][\\s\"]+\\p{Ll}",                 unicode.utf8.upper },
   {
      "^(?:\\x1b\\x10\\d+\\x1b\\x10\\s*|[\"])?\\p{Ll}",
      unicode.utf8.upper
   },
   {
      "(^(?:\\x1b\\x10\\d+\\x1b\\x10\\s*)?|[-\\x{2014}\\s(\[\"])'",
      u("%1", 0x2018)
   },
   { "'",                                    u(0x2019) },
   {
      "(^(?:\\x1b\\x10\\d+\\x1b\\x10\\s*)?|[-\\x{2014/\\[(\\x{2018}\\s])\"",
      u("%1", 0x201c)
   },
   { "\"",                                   u(0x201d) },
   { "\\bi\\b",                              unicode.utf8.upper },
   {
      "\\b(?i:(https?|ss[lh]|ftp|ii?rc|fyi|cmiiw|afaik|btw|pebkac|wtf|wth|lol|rofl|ymmv|nih|ama|eli5|mfw|mrw|tl;d[rw]|sasl))\\b",
      unicode.utf8.upper
   },
   { "(\\d+)deg\\b",                         u("%1", 0x00b0) },
   { "\\x{00b0}\\s*[cf]\\b",                 unicode.utf8.upper },
   { "<([us])>(.+?)</\\1>",                  combine },
   { "\\s{2,}",                              " " },
}

g.mnemonics = {
-- From RFC 1345 (http://tools.ietf.org/html/rfc1345)
-- First 96 mnemonics are removed since they are just standard 7bit ASCII
-- characters.

      ["NS"] = 0x00a0, -- NO-BREAK SPACE
      ["!I"] = 0x00a1, -- INVERTED EXCLAMATION MARK
      ["Ct"] = 0x00a2, -- CENT SIGN
      ["Pd"] = 0x00a3, -- POUND SIGN
      ["Cu"] = 0x00a4, -- CURRENCY SIGN
      ["Ye"] = 0x00a5, -- YEN SIGN
      ["BB"] = 0x00a6, -- BROKEN BAR
      ["SE"] = 0x00a7, -- SECTION SIGN
      ["':"] = 0x00a8, -- DIAERESIS
      ["Co"] = 0x00a9, -- COPYRIGHT SIGN
      ["-a"] = 0x00aa, -- FEMININE ORDINAL INDICATOR
      ["<<"] = 0x00ab, -- LEFT-POINTING DOUBLE ANGLE QUOTATION MARK
      ["NO"] = 0x00ac, -- NOT SIGN
      ["--"] = 0x00ad, -- SOFT HYPHEN
      ["Rg"] = 0x00ae, -- REGISTERED SIGN
      ["'m"] = 0x00af, -- MACRON
      ["DG"] = 0x00b0, -- DEGREE SIGN
      ["+-"] = 0x00b1, -- PLUS-MINUS SIGN
      ["2S"] = 0x00b2, -- SUPERSCRIPT TWO
      ["3S"] = 0x00b3, -- SUPERSCRIPT THREE
      ["''"] = 0x00b4, -- ACUTE ACCENT
      ["My"] = 0x00b5, -- MICRO SIGN
      ["PI"] = 0x00b6, -- PILCROW SIGN
      [".M"] = 0x00b7, -- MIDDLE DOT
      ["',"] = 0x00b8, -- CEDILLA
      ["1S"] = 0x00b9, -- SUPERSCRIPT ONE
      ["-o"] = 0x00ba, -- MASCULINE ORDINAL INDICATOR
      [">>"] = 0x00bb, -- RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK
      ["14"] = 0x00bc, -- VULGAR FRACTION ONE QUARTER
      ["12"] = 0x00bd, -- VULGAR FRACTION ONE HALF
      ["34"] = 0x00be, -- VULGAR FRACTION THREE QUARTERS
      ["?I"] = 0x00bf, -- INVERTED QUESTION MARK
      ["A!"] = 0x00c0, -- LATIN CAPITAL LETTER A WITH GRAVE
      ["A'"] = 0x00c1, -- LATIN CAPITAL LETTER A WITH ACUTE
      ["A>"] = 0x00c2, -- LATIN CAPITAL LETTER A WITH CIRCUMFLEX
      ["A?"] = 0x00c3, -- LATIN CAPITAL LETTER A WITH TILDE
      ["A:"] = 0x00c4, -- LATIN CAPITAL LETTER A WITH DIAERESIS
      ["AA"] = 0x00c5, -- LATIN CAPITAL LETTER A WITH RING ABOVE
      ["AE"] = 0x00c6, -- LATIN CAPITAL LETTER AE
      ["C,"] = 0x00c7, -- LATIN CAPITAL LETTER C WITH CEDILLA
      ["E!"] = 0x00c8, -- LATIN CAPITAL LETTER E WITH GRAVE
      ["E'"] = 0x00c9, -- LATIN CAPITAL LETTER E WITH ACUTE
      ["E>"] = 0x00ca, -- LATIN CAPITAL LETTER E WITH CIRCUMFLEX
      ["E:"] = 0x00cb, -- LATIN CAPITAL LETTER E WITH DIAERESIS
      ["I!"] = 0x00cc, -- LATIN CAPITAL LETTER I WITH GRAVE
      ["I'"] = 0x00cd, -- LATIN CAPITAL LETTER I WITH ACUTE
      ["I>"] = 0x00ce, -- LATIN CAPITAL LETTER I WITH CIRCUMFLEX
      ["I:"] = 0x00cf, -- LATIN CAPITAL LETTER I WITH DIAERESIS
      ["D-"] = 0x00d0, -- LATIN CAPITAL LETTER ETH (Icelandic)
      ["N?"] = 0x00d1, -- LATIN CAPITAL LETTER N WITH TILDE
      ["O!"] = 0x00d2, -- LATIN CAPITAL LETTER O WITH GRAVE
      ["O'"] = 0x00d3, -- LATIN CAPITAL LETTER O WITH ACUTE
      ["O>"] = 0x00d4, -- LATIN CAPITAL LETTER O WITH CIRCUMFLEX
      ["O?"] = 0x00d5, -- LATIN CAPITAL LETTER O WITH TILDE
      ["O:"] = 0x00d6, -- LATIN CAPITAL LETTER O WITH DIAERESIS
      ["*X"] = 0x00d7, -- MULTIPLICATION SIGN
      ["O/"] = 0x00d8, -- LATIN CAPITAL LETTER O WITH STROKE
      ["U!"] = 0x00d9, -- LATIN CAPITAL LETTER U WITH GRAVE
      ["U'"] = 0x00da, -- LATIN CAPITAL LETTER U WITH ACUTE
      ["U>"] = 0x00db, -- LATIN CAPITAL LETTER U WITH CIRCUMFLEX
      ["U:"] = 0x00dc, -- LATIN CAPITAL LETTER U WITH DIAERESIS
      ["Y'"] = 0x00dd, -- LATIN CAPITAL LETTER Y WITH ACUTE
      ["TH"] = 0x00de, -- LATIN CAPITAL LETTER THORN (Icelandic)
      ["ss"] = 0x00df, -- LATIN SMALL LETTER SHARP S (German)
      ["a!"] = 0x00e0, -- LATIN SMALL LETTER A WITH GRAVE
      ["a'"] = 0x00e1, -- LATIN SMALL LETTER A WITH ACUTE
      ["a>"] = 0x00e2, -- LATIN SMALL LETTER A WITH CIRCUMFLEX
      ["a?"] = 0x00e3, -- LATIN SMALL LETTER A WITH TILDE
      ["a:"] = 0x00e4, -- LATIN SMALL LETTER A WITH DIAERESIS
      ["aa"] = 0x00e5, -- LATIN SMALL LETTER A WITH RING ABOVE
      ["ae"] = 0x00e6, -- LATIN SMALL LETTER AE
      ["c,"] = 0x00e7, -- LATIN SMALL LETTER C WITH CEDILLA
      ["e!"] = 0x00e8, -- LATIN SMALL LETTER E WITH GRAVE
      ["e'"] = 0x00e9, -- LATIN SMALL LETTER E WITH ACUTE
      ["e>"] = 0x00ea, -- LATIN SMALL LETTER E WITH CIRCUMFLEX
      ["e:"] = 0x00eb, -- LATIN SMALL LETTER E WITH DIAERESIS
      ["i!"] = 0x00ec, -- LATIN SMALL LETTER I WITH GRAVE
      ["i'"] = 0x00ed, -- LATIN SMALL LETTER I WITH ACUTE
      ["i>"] = 0x00ee, -- LATIN SMALL LETTER I WITH CIRCUMFLEX
      ["i:"] = 0x00ef, -- LATIN SMALL LETTER I WITH DIAERESIS
      ["d-"] = 0x00f0, -- LATIN SMALL LETTER ETH (Icelandic)
      ["n?"] = 0x00f1, -- LATIN SMALL LETTER N WITH TILDE
      ["o!"] = 0x00f2, -- LATIN SMALL LETTER O WITH GRAVE
      ["o'"] = 0x00f3, -- LATIN SMALL LETTER O WITH ACUTE
      ["o>"] = 0x00f4, -- LATIN SMALL LETTER O WITH CIRCUMFLEX
      ["o?"] = 0x00f5, -- LATIN SMALL LETTER O WITH TILDE
      ["o:"] = 0x00f6, -- LATIN SMALL LETTER O WITH DIAERESIS
      ["-:"] = 0x00f7, -- DIVISION SIGN
      ["o/"] = 0x00f8, -- LATIN SMALL LETTER O WITH STROKE
      ["u!"] = 0x00f9, -- LATIN SMALL LETTER U WITH GRAVE
      ["u'"] = 0x00fa, -- LATIN SMALL LETTER U WITH ACUTE
      ["u>"] = 0x00fb, -- LATIN SMALL LETTER U WITH CIRCUMFLEX
      ["u:"] = 0x00fc, -- LATIN SMALL LETTER U WITH DIAERESIS
      ["y'"] = 0x00fd, -- LATIN SMALL LETTER Y WITH ACUTE
      ["th"] = 0x00fe, -- LATIN SMALL LETTER THORN (Icelandic)
      ["y:"] = 0x00ff, -- LATIN SMALL LETTER Y WITH DIAERESIS
      ["A-"] = 0x0100, -- LATIN CAPITAL LETTER A WITH MACRON
      ["a-"] = 0x0101, -- LATIN SMALL LETTER A WITH MACRON
      ["A("] = 0x0102, -- LATIN CAPITAL LETTER A WITH BREVE
      ["a("] = 0x0103, -- LATIN SMALL LETTER A WITH BREVE
      ["A;"] = 0x0104, -- LATIN CAPITAL LETTER A WITH OGONEK
      ["a;"] = 0x0105, -- LATIN SMALL LETTER A WITH OGONEK
      ["C'"] = 0x0106, -- LATIN CAPITAL LETTER C WITH ACUTE
      ["c'"] = 0x0107, -- LATIN SMALL LETTER C WITH ACUTE
      ["C>"] = 0x0108, -- LATIN CAPITAL LETTER C WITH CIRCUMFLEX
      ["c>"] = 0x0109, -- LATIN SMALL LETTER C WITH CIRCUMFLEX
      ["C."] = 0x010a, -- LATIN CAPITAL LETTER C WITH DOT ABOVE
      ["c."] = 0x010b, -- LATIN SMALL LETTER C WITH DOT ABOVE
      ["C<"] = 0x010c, -- LATIN CAPITAL LETTER C WITH CARON
      ["c<"] = 0x010d, -- LATIN SMALL LETTER C WITH CARON
      ["D<"] = 0x010e, -- LATIN CAPITAL LETTER D WITH CARON
      ["d<"] = 0x010f, -- LATIN SMALL LETTER D WITH CARON
      ["D/"] = 0x0110, -- LATIN CAPITAL LETTER D WITH STROKE
      ["d/"] = 0x0111, -- LATIN SMALL LETTER D WITH STROKE
      ["E-"] = 0x0112, -- LATIN CAPITAL LETTER E WITH MACRON
      ["e-"] = 0x0113, -- LATIN SMALL LETTER E WITH MACRON
      ["E("] = 0x0114, -- LATIN CAPITAL LETTER E WITH BREVE
      ["e("] = 0x0115, -- LATIN SMALL LETTER E WITH BREVE
      ["E."] = 0x0116, -- LATIN CAPITAL LETTER E WITH DOT ABOVE
      ["e."] = 0x0117, -- LATIN SMALL LETTER E WITH DOT ABOVE
      ["E;"] = 0x0118, -- LATIN CAPITAL LETTER E WITH OGONEK
      ["e;"] = 0x0119, -- LATIN SMALL LETTER E WITH OGONEK
      ["E<"] = 0x011a, -- LATIN CAPITAL LETTER E WITH CARON
      ["e<"] = 0x011b, -- LATIN SMALL LETTER E WITH CARON
      ["G>"] = 0x011c, -- LATIN CAPITAL LETTER G WITH CIRCUMFLEX
      ["g>"] = 0x011d, -- LATIN SMALL LETTER G WITH CIRCUMFLEX
      ["G("] = 0x011e, -- LATIN CAPITAL LETTER G WITH BREVE
      ["g("] = 0x011f, -- LATIN SMALL LETTER G WITH BREVE
      ["G."] = 0x0120, -- LATIN CAPITAL LETTER G WITH DOT ABOVE
      ["g."] = 0x0121, -- LATIN SMALL LETTER G WITH DOT ABOVE
      ["G,"] = 0x0122, -- LATIN CAPITAL LETTER G WITH CEDILLA
      ["g,"] = 0x0123, -- LATIN SMALL LETTER G WITH CEDILLA
      ["H>"] = 0x0124, -- LATIN CAPITAL LETTER H WITH CIRCUMFLEX
      ["h>"] = 0x0125, -- LATIN SMALL LETTER H WITH CIRCUMFLEX
      ["H/"] = 0x0126, -- LATIN CAPITAL LETTER H WITH STROKE
      ["h/"] = 0x0127, -- LATIN SMALL LETTER H WITH STROKE
      ["I?"] = 0x0128, -- LATIN CAPITAL LETTER I WITH TILDE
      ["i?"] = 0x0129, -- LATIN SMALL LETTER I WITH TILDE
      ["I-"] = 0x012a, -- LATIN CAPITAL LETTER I WITH MACRON
      ["i-"] = 0x012b, -- LATIN SMALL LETTER I WITH MACRON
      ["I("] = 0x012c, -- LATIN CAPITAL LETTER I WITH BREVE
      ["i("] = 0x012d, -- LATIN SMALL LETTER I WITH BREVE
      ["I;"] = 0x012e, -- LATIN CAPITAL LETTER I WITH OGONEK
      ["i;"] = 0x012f, -- LATIN SMALL LETTER I WITH OGONEK
      ["I."] = 0x0130, -- LATIN CAPITAL LETTER I WITH DOT ABOVE
      ["i."] = 0x0131, -- LATIN SMALL LETTER I DOTLESS
      ["IJ"] = 0x0132, -- LATIN CAPITAL LIGATURE IJ
      ["ij"] = 0x0133, -- LATIN SMALL LIGATURE IJ
      ["J>"] = 0x0134, -- LATIN CAPITAL LETTER J WITH CIRCUMFLEX
      ["j>"] = 0x0135, -- LATIN SMALL LETTER J WITH CIRCUMFLEX
      ["K,"] = 0x0136, -- LATIN CAPITAL LETTER K WITH CEDILLA
      ["k,"] = 0x0137, -- LATIN SMALL LETTER K WITH CEDILLA
      ["kk"] = 0x0138, -- LATIN SMALL LETTER KRA (Greenlandic)
      ["L'"] = 0x0139, -- LATIN CAPITAL LETTER L WITH ACUTE
      ["l'"] = 0x013a, -- LATIN SMALL LETTER L WITH ACUTE
      ["L,"] = 0x013b, -- LATIN CAPITAL LETTER L WITH CEDILLA
      ["l,"] = 0x013c, -- LATIN SMALL LETTER L WITH CEDILLA
      ["L<"] = 0x013d, -- LATIN CAPITAL LETTER L WITH CARON
      ["l<"] = 0x013e, -- LATIN SMALL LETTER L WITH CARON
      ["L."] = 0x013f, -- LATIN CAPITAL LETTER L WITH MIDDLE DOT
      ["l."] = 0x0140, -- LATIN SMALL LETTER L WITH MIDDLE DOT
      ["L/"] = 0x0141, -- LATIN CAPITAL LETTER L WITH STROKE
      ["l/"] = 0x0142, -- LATIN SMALL LETTER L WITH STROKE
      ["N'"] = 0x0143, -- LATIN CAPITAL LETTER N WITH ACUTE
      ["n'"] = 0x0144, -- LATIN SMALL LETTER N WITH ACUTE
      ["N,"] = 0x0145, -- LATIN CAPITAL LETTER N WITH CEDILLA
      ["n,"] = 0x0146, -- LATIN SMALL LETTER N WITH CEDILLA
      ["N<"] = 0x0147, -- LATIN CAPITAL LETTER N WITH CARON
      ["n<"] = 0x0148, -- LATIN SMALL LETTER N WITH CARON
      ["'n"] = 0x0149, -- LATIN SMALL LETTER N PRECEDED BY APOSTROPHE
      ["NG"] = 0x014a, -- LATIN CAPITAL LETTER ENG (Lappish)
      ["ng"] = 0x014b, -- LATIN SMALL LETTER ENG (Lappish)
      ["O-"] = 0x014c, -- LATIN CAPITAL LETTER O WITH MACRON
      ["o-"] = 0x014d, -- LATIN SMALL LETTER O WITH MACRON
      ["O("] = 0x014e, -- LATIN CAPITAL LETTER O WITH BREVE
      ["o("] = 0x014f, -- LATIN SMALL LETTER O WITH BREVE
     ["O\""] = 0x0150, -- LATIN CAPITAL LETTER O WITH DOUBLE ACUTE
     ["o\""] = 0x0151, -- LATIN SMALL LETTER O WITH DOUBLE ACUTE
      ["OE"] = 0x0152, -- LATIN CAPITAL LIGATURE OE
      ["oe"] = 0x0153, -- LATIN SMALL LIGATURE OE
      ["R'"] = 0x0154, -- LATIN CAPITAL LETTER R WITH ACUTE
      ["r'"] = 0x0155, -- LATIN SMALL LETTER R WITH ACUTE
      ["R,"] = 0x0156, -- LATIN CAPITAL LETTER R WITH CEDILLA
      ["r,"] = 0x0157, -- LATIN SMALL LETTER R WITH CEDILLA
      ["R<"] = 0x0158, -- LATIN CAPITAL LETTER R WITH CARON
      ["r<"] = 0x0159, -- LATIN SMALL LETTER R WITH CARON
      ["S'"] = 0x015a, -- LATIN CAPITAL LETTER S WITH ACUTE
      ["s'"] = 0x015b, -- LATIN SMALL LETTER S WITH ACUTE
      ["S>"] = 0x015c, -- LATIN CAPITAL LETTER S WITH CIRCUMFLEX
      ["s>"] = 0x015d, -- LATIN SMALL LETTER S WITH CIRCUMFLEX
      ["S,"] = 0x015e, -- LATIN CAPITAL LETTER S WITH CEDILLA
      ["s,"] = 0x015f, -- LATIN SMALL LETTER S WITH CEDILLA
      ["S<"] = 0x0160, -- LATIN CAPITAL LETTER S WITH CARON
      ["s<"] = 0x0161, -- LATIN SMALL LETTER S WITH CARON
      ["T,"] = 0x0162, -- LATIN CAPITAL LETTER T WITH CEDILLA
      ["t,"] = 0x0163, -- LATIN SMALL LETTER T WITH CEDILLA
      ["T<"] = 0x0164, -- LATIN CAPITAL LETTER T WITH CARON
      ["t<"] = 0x0165, -- LATIN SMALL LETTER T WITH CARON
      ["T/"] = 0x0166, -- LATIN CAPITAL LETTER T WITH STROKE
      ["t/"] = 0x0167, -- LATIN SMALL LETTER T WITH STROKE
      ["U?"] = 0x0168, -- LATIN CAPITAL LETTER U WITH TILDE
      ["u?"] = 0x0169, -- LATIN SMALL LETTER U WITH TILDE
      ["U-"] = 0x016a, -- LATIN CAPITAL LETTER U WITH MACRON
      ["u-"] = 0x016b, -- LATIN SMALL LETTER U WITH MACRON
      ["U("] = 0x016c, -- LATIN CAPITAL LETTER U WITH BREVE
      ["u("] = 0x016d, -- LATIN SMALL LETTER U WITH BREVE
      ["U0"] = 0x016e, -- LATIN CAPITAL LETTER U WITH RING ABOVE
      ["u0"] = 0x016f, -- LATIN SMALL LETTER U WITH RING ABOVE
     ["U\""] = 0x0170, -- LATIN CAPITAL LETTER U WITH DOUBLE ACUTE
     ["u\""] = 0x0171, -- LATIN SMALL LETTER U WITH DOUBLE ACUTE
      ["U;"] = 0x0172, -- LATIN CAPITAL LETTER U WITH OGONEK
      ["u;"] = 0x0173, -- LATIN SMALL LETTER U WITH OGONEK
      ["W>"] = 0x0174, -- LATIN CAPITAL LETTER W WITH CIRCUMFLEX
      ["w>"] = 0x0175, -- LATIN SMALL LETTER W WITH CIRCUMFLEX
      ["Y>"] = 0x0176, -- LATIN CAPITAL LETTER Y WITH CIRCUMFLEX
      ["y>"] = 0x0177, -- LATIN SMALL LETTER Y WITH CIRCUMFLEX
      ["Y:"] = 0x0178, -- LATIN CAPITAL LETTER Y WITH DIAERESIS
      ["Z'"] = 0x0179, -- LATIN CAPITAL LETTER Z WITH ACUTE
      ["z'"] = 0x017a, -- LATIN SMALL LETTER Z WITH ACUTE
      ["Z."] = 0x017b, -- LATIN CAPITAL LETTER Z WITH DOT ABOVE
      ["z."] = 0x017c, -- LATIN SMALL LETTER Z WITH DOT ABOVE
      ["Z<"] = 0x017d, -- LATIN CAPITAL LETTER Z WITH CARON
      ["z<"] = 0x017e, -- LATIN SMALL LETTER Z WITH CARON
      ["O9"] = 0x01a0, -- LATIN CAPITAL LETTER O WITH HORN
      ["o9"] = 0x01a1, -- LATIN SMALL LETTER O WITH HORN
      ["OI"] = 0x01a2, -- LATIN CAPITAL LETTER OI
      ["oi"] = 0x01a3, -- LATIN SMALL LETTER OI
      ["yr"] = 0x01a6, -- LATIN LETTER YR
      ["U9"] = 0x01af, -- LATIN CAPITAL LETTER U WITH HORN
      ["u9"] = 0x01b0, -- LATIN SMALL LETTER U WITH HORN
      ["Z/"] = 0x01b5, -- LATIN CAPITAL LETTER Z WITH STROKE
      ["z/"] = 0x01b6, -- LATIN SMALL LETTER Z WITH STROKE
      ["ED"] = 0x01b7, -- LATIN CAPITAL LETTER EZH
      ["A<"] = 0x01cd, -- LATIN CAPITAL LETTER A WITH CARON
      ["a<"] = 0x01ce, -- LATIN SMALL LETTER A WITH CARON
      ["I<"] = 0x01cf, -- LATIN CAPITAL LETTER I WITH CARON
      ["i<"] = 0x01d0, -- LATIN SMALL LETTER I WITH CARON
      ["O<"] = 0x01d1, -- LATIN CAPITAL LETTER O WITH CARON
      ["o<"] = 0x01d2, -- LATIN SMALL LETTER O WITH CARON
      ["U<"] = 0x01d3, -- LATIN CAPITAL LETTER U WITH CARON
      ["u<"] = 0x01d4, -- LATIN SMALL LETTER U WITH CARON
     ["U:-"] = 0x01d5, -- LATIN CAPITAL LETTER U WITH DIAERESIS AND MACRON
     ["u:-"] = 0x01d6, -- LATIN SMALL LETTER U WITH DIAERESIS AND MACRON
     ["U:'"] = 0x01d7, -- LATIN CAPITAL LETTER U WITH DIAERESIS AND ACUTE
     ["u:'"] = 0x01d8, -- LATIN SMALL LETTER U WITH DIAERESIS AND ACUTE
     ["U:<"] = 0x01d9, -- LATIN CAPITAL LETTER U WITH DIAERESIS AND CARON
     ["u:<"] = 0x01da, -- LATIN SMALL LETTER U WITH DIAERESIS AND CARON
     ["U:!"] = 0x01db, -- LATIN CAPITAL LETTER U WITH DIAERESIS AND GRAVE
     ["u:!"] = 0x01dc, -- LATIN SMALL LETTER U WITH DIAERESIS AND GRAVE
      ["A1"] = 0x01de, -- LATIN CAPITAL LETTER A WITH DIAERESIS AND MACRON
      ["a1"] = 0x01df, -- LATIN SMALL LETTER A WITH DIAERESIS AND MACRON
      ["A7"] = 0x01e0, -- LATIN CAPITAL LETTER A WITH DOT ABOVE AND MACRON
      ["a7"] = 0x01e1, -- LATIN SMALL LETTER A WITH DOT ABOVE AND MACRON
      ["A3"] = 0x01e2, -- LATIN CAPITAL LETTER AE WITH MACRON
      ["a3"] = 0x01e3, -- LATIN SMALL LETTER AE WITH MACRON
      ["G/"] = 0x01e4, -- LATIN CAPITAL LETTER G WITH STROKE
      ["g/"] = 0x01e5, -- LATIN SMALL LETTER G WITH STROKE
      ["G<"] = 0x01e6, -- LATIN CAPITAL LETTER G WITH CARON
      ["g<"] = 0x01e7, -- LATIN SMALL LETTER G WITH CARON
      ["K<"] = 0x01e8, -- LATIN CAPITAL LETTER K WITH CARON
      ["k<"] = 0x01e9, -- LATIN SMALL LETTER K WITH CARON
      ["O;"] = 0x01ea, -- LATIN CAPITAL LETTER O WITH OGONEK
      ["o;"] = 0x01eb, -- LATIN SMALL LETTER O WITH OGONEK
      ["O1"] = 0x01ec, -- LATIN CAPITAL LETTER O WITH OGONEK AND MACRON
      ["o1"] = 0x01ed, -- LATIN SMALL LETTER O WITH OGONEK AND MACRON
      ["EZ"] = 0x01ee, -- LATIN CAPITAL LETTER EZH WITH CARON
      ["ez"] = 0x01ef, -- LATIN SMALL LETTER EZH WITH CARON
      ["j<"] = 0x01f0, -- LATIN SMALL LETTER J WITH CARON
      ["G'"] = 0x01f4, -- LATIN CAPITAL LETTER G WITH ACUTE
      ["g'"] = 0x01f5, -- LATIN SMALL LETTER G WITH ACUTE
     ["AA'"] = 0x01fa, -- LATIN CAPITAL LETTER A WITH RING ABOVE AND ACUTE
     ["aa'"] = 0x01fb, -- LATIN SMALL LETTER A WITH RING ABOVE AND ACUTE
     ["AE'"] = 0x01fc, -- LATIN CAPITAL LETTER AE WITH ACUTE
     ["ae'"] = 0x01fd, -- LATIN SMALL LETTER AE WITH ACUTE
     ["O/'"] = 0x01fe, -- LATIN CAPITAL LETTER O WITH STROKE AND ACUTE
     ["o/'"] = 0x01ff, -- LATIN SMALL LETTER O WITH STROKE AND ACUTE
      [";S"] = 0x02bf, -- MODIFIER LETTER LEFT HALF RING
      ["'<"] = 0x02c7, -- CARON
      ["'("] = 0x02d8, -- BREVE
      ["'."] = 0x02d9, -- DOT ABOVE
      ["'0"] = 0x02da, -- RING ABOVE
      ["';"] = 0x02db, -- OGONEK
     ["'\""] = 0x02dd, -- DOUBLE ACUTE ACCENT
      ["A%"] = 0x0386, -- GREEK CAPITAL LETTER ALPHA WITH ACUTE
      ["E%"] = 0x0388, -- GREEK CAPITAL LETTER EPSILON WITH ACUTE
      ["Y%"] = 0x0389, -- GREEK CAPITAL LETTER ETA WITH ACUTE
      ["I%"] = 0x038a, -- GREEK CAPITAL LETTER IOTA WITH ACUTE
      ["O%"] = 0x038c, -- GREEK CAPITAL LETTER OMICRON WITH ACUTE
      ["U%"] = 0x038e, -- GREEK CAPITAL LETTER UPSILON WITH ACUTE
      ["W%"] = 0x038f, -- GREEK CAPITAL LETTER OMEGA WITH ACUTE
      ["i3"] = 0x0390, -- GREEK SMALL LETTER IOTA WITH ACUTE AND DIAERESIS
      ["A*"] = 0x0391, -- GREEK CAPITAL LETTER ALPHA
      ["B*"] = 0x0392, -- GREEK CAPITAL LETTER BETA
      ["G*"] = 0x0393, -- GREEK CAPITAL LETTER GAMMA
      ["D*"] = 0x0394, -- GREEK CAPITAL LETTER DELTA
      ["E*"] = 0x0395, -- GREEK CAPITAL LETTER EPSILON
      ["Z*"] = 0x0396, -- GREEK CAPITAL LETTER ZETA
      ["Y*"] = 0x0397, -- GREEK CAPITAL LETTER ETA
      ["H*"] = 0x0398, -- GREEK CAPITAL LETTER THETA
      ["I*"] = 0x0399, -- GREEK CAPITAL LETTER IOTA
      ["K*"] = 0x039a, -- GREEK CAPITAL LETTER KAPPA
      ["L*"] = 0x039b, -- GREEK CAPITAL LETTER LAMDA
      ["M*"] = 0x039c, -- GREEK CAPITAL LETTER MU
      ["N*"] = 0x039d, -- GREEK CAPITAL LETTER NU
      ["C*"] = 0x039e, -- GREEK CAPITAL LETTER XI
      ["O*"] = 0x039f, -- GREEK CAPITAL LETTER OMICRON
      ["P*"] = 0x03a0, -- GREEK CAPITAL LETTER PI
      ["R*"] = 0x03a1, -- GREEK CAPITAL LETTER RHO
      ["S*"] = 0x03a3, -- GREEK CAPITAL LETTER SIGMA
      ["T*"] = 0x03a4, -- GREEK CAPITAL LETTER TAU
      ["U*"] = 0x03a5, -- GREEK CAPITAL LETTER UPSILON
      ["F*"] = 0x03a6, -- GREEK CAPITAL LETTER PHI
      ["X*"] = 0x03a7, -- GREEK CAPITAL LETTER CHI
      ["Q*"] = 0x03a8, -- GREEK CAPITAL LETTER PSI
      ["W*"] = 0x03a9, -- GREEK CAPITAL LETTER OMEGA
      ["J*"] = 0x03aa, -- GREEK CAPITAL LETTER IOTA WITH DIAERESIS
      ["V*"] = 0x03ab, -- GREEK CAPITAL LETTER UPSILON WITH DIAERESIS
      ["a%"] = 0x03ac, -- GREEK SMALL LETTER ALPHA WITH ACUTE
      ["e%"] = 0x03ad, -- GREEK SMALL LETTER EPSILON WITH ACUTE
      ["y%"] = 0x03ae, -- GREEK SMALL LETTER ETA WITH ACUTE
      ["i%"] = 0x03af, -- GREEK SMALL LETTER IOTA WITH ACUTE
      ["u3"] = 0x03b0, -- GREEK SMALL LETTER UPSILON WITH ACUTE AND DIAERESIS
      ["a*"] = 0x03b1, -- GREEK SMALL LETTER ALPHA
      ["b*"] = 0x03b2, -- GREEK SMALL LETTER BETA
      ["g*"] = 0x03b3, -- GREEK SMALL LETTER GAMMA
      ["d*"] = 0x03b4, -- GREEK SMALL LETTER DELTA
      ["e*"] = 0x03b5, -- GREEK SMALL LETTER EPSILON
      ["z*"] = 0x03b6, -- GREEK SMALL LETTER ZETA
      ["y*"] = 0x03b7, -- GREEK SMALL LETTER ETA
      ["h*"] = 0x03b8, -- GREEK SMALL LETTER THETA
      ["i*"] = 0x03b9, -- GREEK SMALL LETTER IOTA
      ["k*"] = 0x03ba, -- GREEK SMALL LETTER KAPPA
      ["l*"] = 0x03bb, -- GREEK SMALL LETTER LAMDA
      ["m*"] = 0x03bc, -- GREEK SMALL LETTER MU
      ["n*"] = 0x03bd, -- GREEK SMALL LETTER NU
      ["c*"] = 0x03be, -- GREEK SMALL LETTER XI
      ["o*"] = 0x03bf, -- GREEK SMALL LETTER OMICRON
      ["p*"] = 0x03c0, -- GREEK SMALL LETTER PI
      ["r*"] = 0x03c1, -- GREEK SMALL LETTER RHO
      ["*s"] = 0x03c2, -- GREEK SMALL LETTER FINAL SIGMA
      ["s*"] = 0x03c3, -- GREEK SMALL LETTER SIGMA
      ["t*"] = 0x03c4, -- GREEK SMALL LETTER TAU
      ["u*"] = 0x03c5, -- GREEK SMALL LETTER UPSILON
      ["f*"] = 0x03c6, -- GREEK SMALL LETTER PHI
      ["x*"] = 0x03c7, -- GREEK SMALL LETTER CHI
      ["q*"] = 0x03c8, -- GREEK SMALL LETTER PSI
      ["w*"] = 0x03c9, -- GREEK SMALL LETTER OMEGA
      ["j*"] = 0x03ca, -- GREEK SMALL LETTER IOTA WITH DIAERESIS
      ["v*"] = 0x03cb, -- GREEK SMALL LETTER UPSILON WITH DIAERESIS
      ["o%"] = 0x03cc, -- GREEK SMALL LETTER OMICRON WITH ACUTE
      ["u%"] = 0x03cd, -- GREEK SMALL LETTER UPSILON WITH ACUTE
      ["w%"] = 0x03ce, -- GREEK SMALL LETTER OMEGA WITH ACUTE
      ["'G"] = 0x03d8, -- GREEK NUMERAL SIGN
      [",G"] = 0x03d9, -- GREEK LOWER NUMERAL SIGN
      ["T3"] = 0x03da, -- GREEK CAPITAL LETTER STIGMA
      ["t3"] = 0x03db, -- GREEK SMALL LETTER STIGMA
      ["M3"] = 0x03dc, -- GREEK CAPITAL LETTER DIGAMMA
      ["m3"] = 0x03dd, -- GREEK SMALL LETTER DIGAMMA
      ["K3"] = 0x03de, -- GREEK CAPITAL LETTER KOPPA
      ["k3"] = 0x03df, -- GREEK SMALL LETTER KOPPA
      ["P3"] = 0x03e0, -- GREEK CAPITAL LETTER SAMPI
      ["p3"] = 0x03e1, -- GREEK SMALL LETTER SAMPI
      ["'%"] = 0x03f4, -- ACUTE ACCENT AND DIAERESIS (Tonos and Dialytika)
      ["j3"] = 0x03f5, -- GREEK IOTA BELOW
      ["IO"] = 0x0401, -- CYRILLIC CAPITAL LETTER IO
      ["D%"] = 0x0402, -- CYRILLIC CAPITAL LETTER DJE (Serbocroatian)
      ["G%"] = 0x0403, -- CYRILLIC CAPITAL LETTER GJE (Macedonian)
      ["IE"] = 0x0404, -- CYRILLIC CAPITAL LETTER UKRAINIAN IE
      ["DS"] = 0x0405, -- CYRILLIC CAPITAL LETTER DZE (Macedonian)
      ["II"] = 0x0406, -- CYRILLIC CAPITAL LETTER BYELORUSSIAN-UKRAINIAN I
      ["YI"] = 0x0407, -- CYRILLIC CAPITAL LETTER YI (Ukrainian)
      ["J%"] = 0x0408, -- CYRILLIC CAPITAL LETTER JE
      ["LJ"] = 0x0409, -- CYRILLIC CAPITAL LETTER LJE
      ["NJ"] = 0x040a, -- CYRILLIC CAPITAL LETTER NJE
      ["Ts"] = 0x040b, -- CYRILLIC CAPITAL LETTER TSHE (Serbocroatian)
      ["KJ"] = 0x040c, -- CYRILLIC CAPITAL LETTER KJE (Macedonian)
      ["V%"] = 0x040e, -- CYRILLIC CAPITAL LETTER SHORT U (Byelorussian)
      ["DZ"] = 0x040f, -- CYRILLIC CAPITAL LETTER DZHE
      ["A="] = 0x0410, -- CYRILLIC CAPITAL LETTER A
      ["B="] = 0x0411, -- CYRILLIC CAPITAL LETTER BE
      ["V="] = 0x0412, -- CYRILLIC CAPITAL LETTER VE
      ["G="] = 0x0413, -- CYRILLIC CAPITAL LETTER GHE
      ["D="] = 0x0414, -- CYRILLIC CAPITAL LETTER DE
      ["E="] = 0x0415, -- CYRILLIC CAPITAL LETTER IE
      ["Z%"] = 0x0416, -- CYRILLIC CAPITAL LETTER ZHE
      ["Z="] = 0x0417, -- CYRILLIC CAPITAL LETTER ZE
      ["I="] = 0x0418, -- CYRILLIC CAPITAL LETTER I
      ["J="] = 0x0419, -- CYRILLIC CAPITAL LETTER SHORT I
      ["K="] = 0x041a, -- CYRILLIC CAPITAL LETTER KA
      ["L="] = 0x041b, -- CYRILLIC CAPITAL LETTER EL
      ["M="] = 0x041c, -- CYRILLIC CAPITAL LETTER EM
      ["N="] = 0x041d, -- CYRILLIC CAPITAL LETTER EN
      ["O="] = 0x041e, -- CYRILLIC CAPITAL LETTER O
      ["P="] = 0x041f, -- CYRILLIC CAPITAL LETTER PE
      ["R="] = 0x0420, -- CYRILLIC CAPITAL LETTER ER
      ["S="] = 0x0421, -- CYRILLIC CAPITAL LETTER ES
      ["T="] = 0x0422, -- CYRILLIC CAPITAL LETTER TE
      ["U="] = 0x0423, -- CYRILLIC CAPITAL LETTER U
      ["F="] = 0x0424, -- CYRILLIC CAPITAL LETTER EF
      ["H="] = 0x0425, -- CYRILLIC CAPITAL LETTER HA
      ["C="] = 0x0426, -- CYRILLIC CAPITAL LETTER TSE
      ["C%"] = 0x0427, -- CYRILLIC CAPITAL LETTER CHE
      ["S%"] = 0x0428, -- CYRILLIC CAPITAL LETTER SHA
      ["Sc"] = 0x0429, -- CYRILLIC CAPITAL LETTER SHCHA
     ["=\""] = 0x042a, -- CYRILLIC CAPITAL LETTER HARD SIGN
      ["Y="] = 0x042b, -- CYRILLIC CAPITAL LETTER YERU
     ["%\""] = 0x042c, -- CYRILLIC CAPITAL LETTER SOFT SIGN
      ["JE"] = 0x042d, -- CYRILLIC CAPITAL LETTER E
      ["JU"] = 0x042e, -- CYRILLIC CAPITAL LETTER YU
      ["JA"] = 0x042f, -- CYRILLIC CAPITAL LETTER YA
      ["a="] = 0x0430, -- CYRILLIC SMALL LETTER A
      ["b="] = 0x0431, -- CYRILLIC SMALL LETTER BE
      ["v="] = 0x0432, -- CYRILLIC SMALL LETTER VE
      ["g="] = 0x0433, -- CYRILLIC SMALL LETTER GHE
      ["d="] = 0x0434, -- CYRILLIC SMALL LETTER DE
      ["e="] = 0x0435, -- CYRILLIC SMALL LETTER IE
      ["z%"] = 0x0436, -- CYRILLIC SMALL LETTER ZHE
      ["z="] = 0x0437, -- CYRILLIC SMALL LETTER ZE
      ["i="] = 0x0438, -- CYRILLIC SMALL LETTER I
      ["j="] = 0x0439, -- CYRILLIC SMALL LETTER SHORT I
      ["k="] = 0x043a, -- CYRILLIC SMALL LETTER KA
      ["l="] = 0x043b, -- CYRILLIC SMALL LETTER EL
      ["m="] = 0x043c, -- CYRILLIC SMALL LETTER EM
      ["n="] = 0x043d, -- CYRILLIC SMALL LETTER EN
      ["o="] = 0x043e, -- CYRILLIC SMALL LETTER O
      ["p="] = 0x043f, -- CYRILLIC SMALL LETTER PE
      ["r="] = 0x0440, -- CYRILLIC SMALL LETTER ER
      ["s="] = 0x0441, -- CYRILLIC SMALL LETTER ES
      ["t="] = 0x0442, -- CYRILLIC SMALL LETTER TE
      ["u="] = 0x0443, -- CYRILLIC SMALL LETTER U
      ["f="] = 0x0444, -- CYRILLIC SMALL LETTER EF
      ["h="] = 0x0445, -- CYRILLIC SMALL LETTER HA
      ["c="] = 0x0446, -- CYRILLIC SMALL LETTER TSE
      ["c%"] = 0x0447, -- CYRILLIC SMALL LETTER CHE
      ["s%"] = 0x0448, -- CYRILLIC SMALL LETTER SHA
      ["sc"] = 0x0449, -- CYRILLIC SMALL LETTER SHCHA
      ["='"] = 0x044a, -- CYRILLIC SMALL LETTER HARD SIGN
      ["y="] = 0x044b, -- CYRILLIC SMALL LETTER YERU
      ["%'"] = 0x044c, -- CYRILLIC SMALL LETTER SOFT SIGN
      ["je"] = 0x044d, -- CYRILLIC SMALL LETTER E
      ["ju"] = 0x044e, -- CYRILLIC SMALL LETTER YU
      ["ja"] = 0x044f, -- CYRILLIC SMALL LETTER YA
      ["io"] = 0x0451, -- CYRILLIC SMALL LETTER IO
      ["d%"] = 0x0452, -- CYRILLIC SMALL LETTER DJE (Serbocroatian)
      ["g%"] = 0x0453, -- CYRILLIC SMALL LETTER GJE (Macedonian)
      ["ie"] = 0x0454, -- CYRILLIC SMALL LETTER UKRAINIAN IE
      ["ds"] = 0x0455, -- CYRILLIC SMALL LETTER DZE (Macedonian)
      ["ii"] = 0x0456, -- CYRILLIC SMALL LETTER BYELORUSSIAN-UKRAINIAN I
      ["yi"] = 0x0457, -- CYRILLIC SMALL LETTER YI (Ukrainian)
      ["j%"] = 0x0458, -- CYRILLIC SMALL LETTER JE
      ["lj"] = 0x0459, -- CYRILLIC SMALL LETTER LJE
      ["nj"] = 0x045a, -- CYRILLIC SMALL LETTER NJE
      ["ts"] = 0x045b, -- CYRILLIC SMALL LETTER TSHE (Serbocroatian)
      ["kj"] = 0x045c, -- CYRILLIC SMALL LETTER KJE (Macedonian)
      ["v%"] = 0x045e, -- CYRILLIC SMALL LETTER SHORT U (Byelorussian)
      ["dz"] = 0x045f, -- CYRILLIC SMALL LETTER DZHE
      ["Y3"] = 0x0462, -- CYRILLIC CAPITAL LETTER YAT
      ["y3"] = 0x0463, -- CYRILLIC SMALL LETTER YAT
      ["O3"] = 0x046a, -- CYRILLIC CAPITAL LETTER BIG YUS
      ["o3"] = 0x046b, -- CYRILLIC SMALL LETTER BIG YUS
      ["F3"] = 0x0472, -- CYRILLIC CAPITAL LETTER FITA
      ["f3"] = 0x0473, -- CYRILLIC SMALL LETTER FITA
      ["V3"] = 0x0474, -- CYRILLIC CAPITAL LETTER IZHITSA
      ["v3"] = 0x0475, -- CYRILLIC SMALL LETTER IZHITSA
      ["C3"] = 0x0480, -- CYRILLIC CAPITAL LETTER KOPPA
      ["c3"] = 0x0481, -- CYRILLIC SMALL LETTER KOPPA
      ["G3"] = 0x0490, -- CYRILLIC CAPITAL LETTER GHE WITH UPTURN
      ["g3"] = 0x0491, -- CYRILLIC SMALL LETTER GHE WITH UPTURN
      ["A+"] = 0x05d0, -- HEBREW LETTER ALEF
      ["B+"] = 0x05d1, -- HEBREW LETTER BET
      ["G+"] = 0x05d2, -- HEBREW LETTER GIMEL
      ["D+"] = 0x05d3, -- HEBREW LETTER DALET
      ["H+"] = 0x05d4, -- HEBREW LETTER HE
      ["W+"] = 0x05d5, -- HEBREW LETTER VAV
      ["Z+"] = 0x05d6, -- HEBREW LETTER ZAYIN
      ["X+"] = 0x05d7, -- HEBREW LETTER HET
      ["Tj"] = 0x05d8, -- HEBREW LETTER TET
      ["J+"] = 0x05d9, -- HEBREW LETTER YOD
      ["K%"] = 0x05da, -- HEBREW LETTER FINAL KAF
      ["K+"] = 0x05db, -- HEBREW LETTER KAF
      ["L+"] = 0x05dc, -- HEBREW LETTER LAMED
      ["M%"] = 0x05dd, -- HEBREW LETTER FINAL MEM
      ["M+"] = 0x05de, -- HEBREW LETTER MEM
      ["N%"] = 0x05df, -- HEBREW LETTER FINAL NUN
      ["N+"] = 0x05e0, -- HEBREW LETTER NUN
      ["S+"] = 0x05e1, -- HEBREW LETTER SAMEKH
      ["E+"] = 0x05e2, -- HEBREW LETTER AYIN
      ["P%"] = 0x05e3, -- HEBREW LETTER FINAL PE
      ["P+"] = 0x05e4, -- HEBREW LETTER PE
      ["Zj"] = 0x05e5, -- HEBREW LETTER FINAL TSADI
      ["ZJ"] = 0x05e6, -- HEBREW LETTER TSADI
      ["Q+"] = 0x05e7, -- HEBREW LETTER QOF
      ["R+"] = 0x05e8, -- HEBREW LETTER RESH
      ["Sh"] = 0x05e9, -- HEBREW LETTER SHIN
      ["T+"] = 0x05ea, -- HEBREW LETTER TAV
      [",+"] = 0x060c, -- ARABIC COMMA
      [";+"] = 0x061b, -- ARABIC SEMICOLON
      ["?+"] = 0x061f, -- ARABIC QUESTION MARK
      ["H'"] = 0x0621, -- ARABIC LETTER HAMZA
      ["aM"] = 0x0622, -- ARABIC LETTER ALEF WITH MADDA ABOVE
      ["aH"] = 0x0623, -- ARABIC LETTER ALEF WITH HAMZA ABOVE
      ["wH"] = 0x0624, -- ARABIC LETTER WAW WITH HAMZA ABOVE
      ["ah"] = 0x0625, -- ARABIC LETTER ALEF WITH HAMZA BELOW
      ["yH"] = 0x0626, -- ARABIC LETTER YEH WITH HAMZA ABOVE
      ["a+"] = 0x0627, -- ARABIC LETTER ALEF
      ["b+"] = 0x0628, -- ARABIC LETTER BEH
      ["tm"] = 0x0629, -- ARABIC LETTER TEH MARBUTA
      ["t+"] = 0x062a, -- ARABIC LETTER TEH
      ["tk"] = 0x062b, -- ARABIC LETTER THEH
      ["g+"] = 0x062c, -- ARABIC LETTER JEEM
      ["hk"] = 0x062d, -- ARABIC LETTER HAH
      ["x+"] = 0x062e, -- ARABIC LETTER KHAH
      ["d+"] = 0x062f, -- ARABIC LETTER DAL
      ["dk"] = 0x0630, -- ARABIC LETTER THAL
      ["r+"] = 0x0631, -- ARABIC LETTER REH
      ["z+"] = 0x0632, -- ARABIC LETTER ZAIN
      ["s+"] = 0x0633, -- ARABIC LETTER SEEN
      ["sn"] = 0x0634, -- ARABIC LETTER SHEEN
      ["c+"] = 0x0635, -- ARABIC LETTER SAD
      ["dd"] = 0x0636, -- ARABIC LETTER DAD
      ["tj"] = 0x0637, -- ARABIC LETTER TAH
      ["zH"] = 0x0638, -- ARABIC LETTER ZAH
      ["e+"] = 0x0639, -- ARABIC LETTER AIN
      ["i+"] = 0x063a, -- ARABIC LETTER GHAIN
      ["++"] = 0x0640, -- ARABIC TATWEEL
      ["f+"] = 0x0641, -- ARABIC LETTER FEH
      ["q+"] = 0x0642, -- ARABIC LETTER QAF
      ["k+"] = 0x0643, -- ARABIC LETTER KAF
      ["l+"] = 0x0644, -- ARABIC LETTER LAM
      ["m+"] = 0x0645, -- ARABIC LETTER MEEM
      ["n+"] = 0x0646, -- ARABIC LETTER NOON
      ["h+"] = 0x0647, -- ARABIC LETTER HEH
      ["w+"] = 0x0648, -- ARABIC LETTER WAW
      ["j+"] = 0x0649, -- ARABIC LETTER ALEF MAKSURA
      ["y+"] = 0x064a, -- ARABIC LETTER YEH
      [":+"] = 0x064b, -- ARABIC FATHATAN
     ["\"+"] = 0x064c, -- ARABIC DAMMATAN
      ["=+"] = 0x064d, -- ARABIC KASRATAN
      ["/+"] = 0x064e, -- ARABIC FATHA
      ["'+"] = 0x064f, -- ARABIC DAMMA
      ["1+"] = 0x0650, -- ARABIC KASRA
      ["3+"] = 0x0651, -- ARABIC SHADDA
      ["0+"] = 0x0652, -- ARABIC SUKUN
      ["aS"] = 0x0670, -- SUPERSCRIPT ARABIC LETTER ALEF
      ["p+"] = 0x067e, -- ARABIC LETTER PEH
      ["v+"] = 0x06a4, -- ARABIC LETTER VEH
      ["gf"] = 0x06af, -- ARABIC LETTER GAF
      ["0a"] = 0x06f0, -- EASTERN ARABIC-INDIC DIGIT ZERO
      ["1a"] = 0x06f1, -- EASTERN ARABIC-INDIC DIGIT ONE
      ["2a"] = 0x06f2, -- EASTERN ARABIC-INDIC DIGIT TWO
      ["3a"] = 0x06f3, -- EASTERN ARABIC-INDIC DIGIT THREE
      ["4a"] = 0x06f4, -- EASTERN ARABIC-INDIC DIGIT FOUR
      ["5a"] = 0x06f5, -- EASTERN ARABIC-INDIC DIGIT FIVE
      ["6a"] = 0x06f6, -- EASTERN ARABIC-INDIC DIGIT SIX
      ["7a"] = 0x06f7, -- EASTERN ARABIC-INDIC DIGIT SEVEN
      ["8a"] = 0x06f8, -- EASTERN ARABIC-INDIC DIGIT EIGHT
      ["9a"] = 0x06f9, -- EASTERN ARABIC-INDIC DIGIT NINE
     ["A-0"] = 0x1e00, -- LATIN CAPITAL LETTER A WITH RING BELOW
     ["a-0"] = 0x1e01, -- LATIN SMALL LETTER A WITH RING BELOW
      ["B."] = 0x1e02, -- LATIN CAPITAL LETTER B WITH DOT ABOVE
      ["b."] = 0x1e03, -- LATIN SMALL LETTER B WITH DOT ABOVE
     ["B-."] = 0x1e04, -- LATIN CAPITAL LETTER B WITH DOT BELOW
     ["b-."] = 0x1e05, -- LATIN SMALL LETTER B WITH DOT BELOW
      ["B_"] = 0x1e06, -- LATIN CAPITAL LETTER B WITH LINE BELOW
      ["b_"] = 0x1e07, -- LATIN SMALL LETTER B WITH LINE BELOW
     ["C,'"] = 0x1e08, -- LATIN CAPITAL LETTER C WITH CEDILLA AND ACUTE
     ["c,'"] = 0x1e09, -- LATIN SMALL LETTER C WITH CEDILLA AND ACUTE
      ["D."] = 0x1e0a, -- LATIN CAPITAL LETTER D WITH DOT ABOVE
      ["d."] = 0x1e0b, -- LATIN SMALL LETTER D WITH DOT ABOVE
     ["D-."] = 0x1e0c, -- LATIN CAPITAL LETTER D WITH DOT BELOW
     ["d-."] = 0x1e0d, -- LATIN SMALL LETTER D WITH DOT BELOW
      ["D_"] = 0x1e0e, -- LATIN CAPITAL LETTER D WITH LINE BELOW
      ["d_"] = 0x1e0f, -- LATIN SMALL LETTER D WITH LINE BELOW
      ["D,"] = 0x1e10, -- LATIN CAPITAL LETTER D WITH CEDILLA
      ["d,"] = 0x1e11, -- LATIN SMALL LETTER D WITH CEDILLA
     ["D->"] = 0x1e12, -- LATIN CAPITAL LETTER D WITH CIRCUMFLEX BELOW
     ["d->"] = 0x1e13, -- LATIN SMALL LETTER D WITH CIRCUMFLEX BELOW
     ["E-!"] = 0x1e14, -- LATIN CAPITAL LETTER E WITH MACRON AND GRAVE
     ["e-!"] = 0x1e15, -- LATIN SMALL LETTER E WITH MACRON AND GRAVE
     ["E-'"] = 0x1e16, -- LATIN CAPITAL LETTER E WITH MACRON AND ACUTE
     ["e-'"] = 0x1e17, -- LATIN SMALL LETTER E WITH MACRON AND ACUTE
     ["E->"] = 0x1e18, -- LATIN CAPITAL LETTER E WITH CIRCUMFLEX BELOW
     ["e->"] = 0x1e19, -- LATIN SMALL LETTER E WITH CIRCUMFLEX BELOW
     ["E-?"] = 0x1e1a, -- LATIN CAPITAL LETTER E WITH TILDE BELOW
     ["e-?"] = 0x1e1b, -- LATIN SMALL LETTER E WITH TILDE BELOW
     ["E,("] = 0x1e1c, -- LATIN CAPITAL LETTER E WITH CEDILLA AND BREVE
     ["e,("] = 0x1e1d, -- LATIN SMALL LETTER E WITH CEDILLA AND BREVE
      ["F."] = 0x1e1e, -- LATIN CAPITAL LETTER F WITH DOT ABOVE
      ["f."] = 0x1e1f, -- LATIN SMALL LETTER F WITH DOT ABOVE
      ["G-"] = 0x1e20, -- LATIN CAPITAL LETTER G WITH MACRON
      ["g-"] = 0x1e21, -- LATIN SMALL LETTER G WITH MACRON
      ["H."] = 0x1e22, -- LATIN CAPITAL LETTER H WITH DOT ABOVE
      ["h."] = 0x1e23, -- LATIN SMALL LETTER H WITH DOT ABOVE
     ["H-."] = 0x1e24, -- LATIN CAPITAL LETTER H WITH DOT BELOW
     ["h-."] = 0x1e25, -- LATIN SMALL LETTER H WITH DOT BELOW
      ["H:"] = 0x1e26, -- LATIN CAPITAL LETTER H WITH DIAERESIS
      ["h:"] = 0x1e27, -- LATIN SMALL LETTER H WITH DIAERESIS
      ["H,"] = 0x1e28, -- LATIN CAPITAL LETTER H WITH CEDILLA
      ["h,"] = 0x1e29, -- LATIN SMALL LETTER H WITH CEDILLA
     ["H-("] = 0x1e2a, -- LATIN CAPITAL LETTER H WITH BREVE BELOW
     ["h-("] = 0x1e2b, -- LATIN SMALL LETTER H WITH BREVE BELOW
     ["I-?"] = 0x1e2c, -- LATIN CAPITAL LETTER I WITH TILDE BELOW
     ["i-?"] = 0x1e2d, -- LATIN SMALL LETTER I WITH TILDE BELOW
     ["I:'"] = 0x1e2e, -- LATIN CAPITAL LETTER I WITH DIAERESIS AND ACUTE
     ["i:'"] = 0x1e2f, -- LATIN SMALL LETTER I WITH DIAERESIS AND ACUTE
      ["K'"] = 0x1e30, -- LATIN CAPITAL LETTER K WITH ACUTE
      ["k'"] = 0x1e31, -- LATIN SMALL LETTER K WITH ACUTE
     ["K-."] = 0x1e32, -- LATIN CAPITAL LETTER K WITH DOT BELOW
     ["k-."] = 0x1e33, -- LATIN SMALL LETTER K WITH DOT BELOW
      ["K_"] = 0x1e34, -- LATIN CAPITAL LETTER K WITH LINE BELOW
      ["k_"] = 0x1e35, -- LATIN SMALL LETTER K WITH LINE BELOW
     ["L-."] = 0x1e36, -- LATIN CAPITAL LETTER L WITH DOT BELOW
     ["l-."] = 0x1e37, -- LATIN SMALL LETTER L WITH DOT BELOW
    ["L--."] = 0x1e38, -- LATIN CAPITAL LETTER L WITH DOT BELOW AND MACRON
    ["l--."] = 0x1e39, -- LATIN SMALL LETTER L WITH DOT BELOW AND MACRON
      ["L_"] = 0x1e3a, -- LATIN CAPITAL LETTER L WITH LINE BELOW
      ["l_"] = 0x1e3b, -- LATIN SMALL LETTER L WITH LINE BELOW
     ["L->"] = 0x1e3c, -- LATIN CAPITAL LETTER L WITH CIRCUMFLEX BELOW
     ["l->"] = 0x1e3d, -- LATIN SMALL LETTER L WITH CIRCUMFLEX BELOW
      ["M'"] = 0x1e3e, -- LATIN CAPITAL LETTER M WITH ACUTE
      ["m'"] = 0x1e3f, -- LATIN SMALL LETTER M WITH ACUTE
      ["M."] = 0x1e40, -- LATIN CAPITAL LETTER M WITH DOT ABOVE
      ["m."] = 0x1e41, -- LATIN SMALL LETTER M WITH DOT ABOVE
     ["M-."] = 0x1e42, -- LATIN CAPITAL LETTER M WITH DOT BELOW
     ["m-."] = 0x1e43, -- LATIN SMALL LETTER M WITH DOT BELOW
      ["N."] = 0x1e44, -- LATIN CAPITAL LETTER N WITH DOT ABOVE
      ["n."] = 0x1e45, -- LATIN SMALL LETTER N WITH DOT ABOVE
     ["N-."] = 0x1e46, -- LATIN CAPITAL LETTER N WITH DOT BELOW
     ["n-."] = 0x1e47, -- LATIN SMALL LETTER N WITH DOT BELOW
      ["N_"] = 0x1e48, -- LATIN CAPITAL LETTER N WITH LINE BELOW
      ["n_"] = 0x1e49, -- LATIN SMALL LETTER N WITH LINE BELOW
     ["N->"] = 0x1e4a, -- LATIN CAPITAL LETTER N WITH CIRCUMFLEX BELOW
     ["N->"] = 0x1e4b, -- LATIN SMALL LETTER N WITH CIRCUMFLEX BELOW
     ["O?'"] = 0x1e4c, -- LATIN CAPITAL LETTER O WITH TILDE AND ACUTE
     ["o?'"] = 0x1e4d, -- LATIN SMALL LETTER O WITH TILDE AND ACUTE
     ["O?:"] = 0x1e4e, -- LATIN CAPITAL LETTER O WITH TILDE AND DIAERESIS
     ["o?:"] = 0x1e4f, -- LATIN SMALL LETTER O WITH TILDE AND DIAERESIS
     ["O-!"] = 0x1e50, -- LATIN CAPITAL LETTER O WITH MACRON AND GRAVE
     ["o-!"] = 0x1e51, -- LATIN SMALL LETTER O WITH MACRON AND GRAVE
     ["O-'"] = 0x1e52, -- LATIN CAPITAL LETTER O WITH MACRON AND ACUTE
     ["o-'"] = 0x1e53, -- LATIN SMALL LETTER O WITH MACRON AND ACUTE
      ["P'"] = 0x1e54, -- LATIN CAPITAL LETTER P WITH ACUTE
      ["p'"] = 0x1e55, -- LATIN SMALL LETTER P WITH ACUTE
      ["P."] = 0x1e56, -- LATIN CAPITAL LETTER P WITH DOT ABOVE
      ["p."] = 0x1e57, -- LATIN SMALL LETTER P WITH DOT ABOVE
      ["R."] = 0x1e58, -- LATIN CAPITAL LETTER R WITH DOT ABOVE
      ["r."] = 0x1e59, -- LATIN SMALL LETTER R WITH DOT ABOVE
     ["R-."] = 0x1e5a, -- LATIN CAPITAL LETTER R WITH DOT BELOW
     ["r-."] = 0x1e5b, -- LATIN SMALL LETTER R WITH DOT BELOW
    ["R--."] = 0x1e5c, -- LATIN CAPITAL LETTER R WITH DOT BELOW AND MACRON
    ["r--."] = 0x1e5d, -- LATIN SMALL LETTER R WITH DOT BELOW AND MACRON
      ["R_"] = 0x1e5e, -- LATIN CAPITAL LETTER R WITH LINE BELOW
      ["r_"] = 0x1e5f, -- LATIN SMALL LETTER R WITH LINE BELOW
      ["S."] = 0x1e60, -- LATIN CAPITAL LETTER S WITH DOT ABOVE
      ["s."] = 0x1e61, -- LATIN SMALL LETTER S WITH DOT ABOVE
     ["S-."] = 0x1e62, -- LATIN CAPITAL LETTER S WITH DOT BELOW
     ["s-."] = 0x1e63, -- LATIN SMALL LETTER S WITH DOT BELOW
     ["S'."] = 0x1e64, -- LATIN CAPITAL LETTER S WITH ACUTE AND DOT ABOVE
     ["s'."] = 0x1e65, -- LATIN SMALL LETTER S WITH ACUTE AND DOT ABOVE
     ["S<."] = 0x1e66, -- LATIN CAPITAL LETTER S WITH CARON AND DOT ABOVE
     ["s<."] = 0x1e67, -- LATIN SMALL LETTER S WITH CARON AND DOT ABOVE
    ["S.-."] = 0x1e68, -- LATIN CAPITAL LETTER S WITH DOT BELOW AND DOT ABOVE
    ["S.-."] = 0x1e69, -- LATIN SMALL LETTER S WITH DOT BELOW AND DOT ABOVE
      ["T."] = 0x1e6a, -- LATIN CAPITAL LETTER T WITH DOT ABOVE
      ["t."] = 0x1e6b, -- LATIN SMALL LETTER T WITH DOT ABOVE
     ["T-."] = 0x1e6c, -- LATIN CAPITAL LETTER T WITH DOT BELOW
     ["t-."] = 0x1e6d, -- LATIN SMALL LETTER T WITH DOT BELOW
      ["T_"] = 0x1e6e, -- LATIN CAPITAL LETTER T WITH LINE BELOW
      ["t_"] = 0x1e6f, -- LATIN SMALL LETTER T WITH LINE BELOW
     ["T->"] = 0x1e70, -- LATIN CAPITAL LETTER T WITH CIRCUMFLEX BELOW
     ["t->"] = 0x1e71, -- LATIN SMALL LETTER T WITH CIRCUMFLEX BELOW
    ["U--:"] = 0x1e72, -- LATIN CAPITAL LETTER U WITH DIAERESIS BELOW
    ["u--:"] = 0x1e73, -- LATIN SMALL LETTER U WITH DIAERESIS BELOW
     ["U-?"] = 0x1e74, -- LATIN CAPITAL LETTER U WITH TILDE BELOW
     ["u-?"] = 0x1e75, -- LATIN SMALL LETTER U WITH TILDE BELOW
     ["U->"] = 0x1e76, -- LATIN CAPITAL LETTER U WITH CIRCUMFLEX BELOW
     ["u->"] = 0x1e77, -- LATIN SMALL LETTER U WITH CIRCUMFLEX BELOW
     ["U?'"] = 0x1e78, -- LATIN CAPITAL LETTER U WITH TILDE AND ACUTE
     ["u?'"] = 0x1e79, -- LATIN SMALL LETTER U WITH TILDE AND ACUTE
     ["U-:"] = 0x1e7a, -- LATIN CAPITAL LETTER U WITH MACRON AND DIAERESIS
     ["u-:"] = 0x1e7b, -- LATIN SMALL LETTER U WITH MACRON AND DIAERESIS
      ["V?"] = 0x1e7c, -- LATIN CAPITAL LETTER V WITH TILDE
      ["v?"] = 0x1e7d, -- LATIN SMALL LETTER V WITH TILDE
     ["V-."] = 0x1e7e, -- LATIN CAPITAL LETTER V WITH DOT BELOW
     ["v-."] = 0x1e7f, -- LATIN SMALL LETTER V WITH DOT BELOW
      ["W!"] = 0x1e80, -- LATIN CAPITAL LETTER W WITH GRAVE
      ["w!"] = 0x1e81, -- LATIN SMALL LETTER W WITH GRAVE
      ["W'"] = 0x1e82, -- LATIN CAPITAL LETTER W WITH ACUTE
      ["w'"] = 0x1e83, -- LATIN SMALL LETTER W WITH ACUTE
      ["W:"] = 0x1e84, -- LATIN CAPITAL LETTER W WITH DIAERESIS
      ["w:"] = 0x1e85, -- LATIN SMALL LETTER W WITH DIAERESIS
      ["W."] = 0x1e86, -- LATIN CAPITAL LETTER W WITH DOT ABOVE
      ["w."] = 0x1e87, -- LATIN SMALL LETTER W WITH DOT ABOVE
     ["W-."] = 0x1e88, -- LATIN CAPITAL LETTER W WITH DOT BELOW
     ["w-."] = 0x1e89, -- LATIN SMALL LETTER W WITH DOT BELOW
      ["X."] = 0x1e8a, -- LATIN CAPITAL LETTER X WITH DOT ABOVE
      ["x."] = 0x1e8b, -- LATIN SMALL LETTER X WITH DOT ABOVE
      ["X:"] = 0x1e8c, -- LATIN CAPITAL LETTER X WITH DIAERESIS
      ["x:"] = 0x1e8d, -- LATIN SMALL LETTER X WITH DIAERESIS
      ["Y."] = 0x1e8e, -- LATIN CAPITAL LETTER Y WITH DOT ABOVE
      ["y."] = 0x1e8f, -- LATIN SMALL LETTER Y WITH DOT ABOVE
      ["Z>"] = 0x1e90, -- LATIN CAPITAL LETTER Z WITH CIRCUMFLEX
      ["z>"] = 0x1e91, -- LATIN SMALL LETTER Z WITH CIRCUMFLEX
     ["Z-."] = 0x1e92, -- LATIN CAPITAL LETTER Z WITH DOT BELOW
     ["z-."] = 0x1e93, -- LATIN SMALL LETTER Z WITH DOT BELOW
      ["Z_"] = 0x1e94, -- LATIN CAPITAL LETTER Z WITH LINE BELOW
      ["z_"] = 0x1e95, -- LATIN SMALL LETTER Z WITH LINE BELOW
      ["h_"] = 0x1e96, -- LATIN SMALL LETTER H WITH LINE BELOW
      ["t:"] = 0x1e97, -- LATIN SMALL LETTER T WITH DIAERESIS
      ["w0"] = 0x1e98, -- LATIN SMALL LETTER W WITH RING ABOVE
      ["y0"] = 0x1e99, -- LATIN SMALL LETTER Y WITH RING ABOVE
     ["A-."] = 0x1ea0, -- LATIN CAPITAL LETTER A WITH DOT BELOW
     ["a-."] = 0x1ea1, -- LATIN SMALL LETTER A WITH DOT BELOW
      ["A2"] = 0x1ea2, -- LATIN CAPITAL LETTER A WITH HOOK ABOVE
      ["a2"] = 0x1ea3, -- LATIN SMALL LETTER A WITH HOOK ABOVE
     ["A>'"] = 0x1ea4, -- LATIN CAPITAL LETTER A WITH CIRCUMFLEX AND ACUTE
     ["a>'"] = 0x1ea5, -- LATIN SMALL LETTER A WITH CIRCUMFLEX AND ACUTE
     ["A>!"] = 0x1ea6, -- LATIN CAPITAL LETTER A WITH CIRCUMFLEX AND GRAVE
     ["a>!"] = 0x1ea7, -- LATIN SMALL LETTER A WITH CIRCUMFLEX AND GRAVE
     ["A>2"] = 0x1ea8, -- LATIN CAPITAL LETTER A WITH CIRCUMFLEX AND HOOK ABOVE
     ["a>2"] = 0x1ea9, -- LATIN SMALL LETTER A WITH CIRCUMFLEX AND HOOK ABOVE
     ["A>?"] = 0x1eaa, -- LATIN CAPITAL LETTER A WITH CIRCUMFLEX AND TILDE
     ["a>?"] = 0x1eab, -- LATIN SMALL LETTER A WITH CIRCUMFLEX AND TILDE
    ["A>-."] = 0x1eac, -- LATIN CAPITAL LETTER A WITH CIRCUMFLEX AND DOT BELOW
    ["a>-."] = 0x1ead, -- LATIN SMALL LETTER A WITH CIRCUMFLEX AND DOT BELOW
     ["A('"] = 0x1eae, -- LATIN CAPITAL LETTER A WITH BREVE AND ACUTE
     ["a('"] = 0x1eaf, -- LATIN SMALL LETTER A WITH BREVE AND ACUTE
     ["A(!"] = 0x1eb0, -- LATIN CAPITAL LETTER A WITH BREVE AND GRAVE
     ["a(!"] = 0x1eb1, -- LATIN SMALL LETTER A WITH BREVE AND GRAVE
     ["A(2"] = 0x1eb2, -- LATIN CAPITAL LETTER A WITH BREVE AND HOOK ABOVE
     ["a(2"] = 0x1eb3, -- LATIN SMALL LETTER A WITH BREVE AND HOOK ABOVE
     ["A(?"] = 0x1eb4, -- LATIN CAPITAL LETTER A WITH BREVE AND TILDE
     ["a(?"] = 0x1eb5, -- LATIN SMALL LETTER A WITH BREVE AND TILDE
    ["A(-."] = 0x1eb6, -- LATIN CAPITAL LETTER A WITH BREVE AND DOT BELOW
    ["a(-."] = 0x1eb7, -- LATIN SMALL LETTER A WITH BREVE AND DOT BELOW
     ["E-."] = 0x1eb8, -- LATIN CAPITAL LETTER E WITH DOT BELOW
     ["e-."] = 0x1eb9, -- LATIN SMALL LETTER E WITH DOT BELOW
      ["E2"] = 0x1eba, -- LATIN CAPITAL LETTER E WITH HOOK ABOVE
      ["e2"] = 0x1ebb, -- LATIN SMALL LETTER E WITH HOOK ABOVE
      ["E?"] = 0x1ebc, -- LATIN CAPITAL LETTER E WITH TILDE
      ["e?"] = 0x1ebd, -- LATIN SMALL LETTER E WITH TILDE
     ["E>'"] = 0x1ebe, -- LATIN CAPITAL LETTER E WITH CIRCUMFLEX AND ACUTE
     ["e>'"] = 0x1ebf, -- LATIN SMALL LETTER E WITH CIRCUMFLEX AND ACUTE
     ["E>!"] = 0x1ec0, -- LATIN CAPITAL LETTER E WITH CIRCUMFLEX AND GRAVE
     ["e>!"] = 0x1ec1, -- LATIN SMALL LETTER E WITH CIRCUMFLEX AND GRAVE
     ["E>2"] = 0x1ec2, -- LATIN CAPITAL LETTER E WITH CIRCUMFLEX AND HOOK ABOVE
     ["e>2"] = 0x1ec3, -- LATIN SMALL LETTER E WITH CIRCUMFLEX AND HOOK ABOVE
     ["E>?"] = 0x1ec4, -- LATIN CAPITAL LETTER E WITH CIRCUMFLEX AND TILDE
     ["e>?"] = 0x1ec5, -- LATIN SMALL LETTER E WITH CIRCUMFLEX AND TILDE
    ["E>-."] = 0x1ec6, -- LATIN CAPITAL LETTER E WITH CIRCUMFLEX AND DOT BELOW
    ["e>-."] = 0x1ec7, -- LATIN SMALL LETTER E WITH CIRCUMFLEX AND DOT BELOW
      ["I2"] = 0x1ec8, -- LATIN CAPITAL LETTER I WITH HOOK ABOVE
      ["i2"] = 0x1ec9, -- LATIN SMALL LETTER I WITH HOOK ABOVE
     ["I-."] = 0x1eca, -- LATIN CAPITAL LETTER I WITH DOT BELOW
     ["i-."] = 0x1ecb, -- LATIN SMALL LETTER I WITH DOT BELOW
     ["O-."] = 0x1ecc, -- LATIN CAPITAL LETTER O WITH DOT BELOW
     ["o-."] = 0x1ecd, -- LATIN SMALL LETTER O WITH DOT BELOW
      ["O2"] = 0x1ece, -- LATIN CAPITAL LETTER O WITH HOOK ABOVE
      ["o2"] = 0x1ecf, -- LATIN SMALL LETTER O WITH HOOK ABOVE
     ["O>'"] = 0x1ed0, -- LATIN CAPITAL LETTER O WITH CIRCUMFLEX AND ACUTE
     ["o>'"] = 0x1ed1, -- LATIN SMALL LETTER O WITH CIRCUMFLEX AND ACUTE
     ["O>!"] = 0x1ed2, -- LATIN CAPITAL LETTER O WITH CIRCUMFLEX AND GRAVE
     ["o>!"] = 0x1ed3, -- LATIN SMALL LETTER O WITH CIRCUMFLEX AND GRAVE
     ["O>2"] = 0x1ed4, -- LATIN CAPITAL LETTER O WITH CIRCUMFLEX AND HOOK ABOVE
     ["o>2"] = 0x1ed5, -- LATIN SMALL LETTER O WITH CIRCUMFLEX AND HOOK ABOVE
     ["O>?"] = 0x1ed6, -- LATIN CAPITAL LETTER O WITH CIRCUMFLEX AND TILDE
     ["o>?"] = 0x1ed7, -- LATIN SMALL LETTER O WITH CIRCUMFLEX AND TILDE
    ["O>-."] = 0x1ed8, -- LATIN CAPITAL LETTER O WITH CIRCUMFLEX AND DOT BELOW
    ["o>-."] = 0x1ed9, -- LATIN SMALL LETTER O WITH CIRCUMFLEX AND DOT BELOW
     ["O9'"] = 0x1eda, -- LATIN CAPITAL LETTER O WITH HORN AND ACUTE
     ["o9'"] = 0x1edb, -- LATIN SMALL LETTER O WITH HORN AND ACUTE
     ["O9!"] = 0x1edc, -- LATIN CAPITAL LETTER O WITH HORN AND GRAVE
     ["o9!"] = 0x1edd, -- LATIN SMALL LETTER O WITH HORN AND GRAVE
     ["O92"] = 0x1ede, -- LATIN CAPITAL LETTER O WITH HORN AND HOOK ABOVE
     ["o92"] = 0x1edf, -- LATIN SMALL LETTER O WITH HORN AND HOOK ABOVE
     ["O9?"] = 0x1ee0, -- LATIN CAPITAL LETTER O WITH HORN AND TILDE
     ["o9?"] = 0x1ee1, -- LATIN SMALL LETTER O WITH HORN AND TILDE
    ["O9-."] = 0x1ee2, -- LATIN CAPITAL LETTER O WITH HORN AND DOT BELOW
    ["o9-."] = 0x1ee3, -- LATIN SMALL LETTER O WITH HORN AND DOT BELOW
     ["U-."] = 0x1ee4, -- LATIN CAPITAL LETTER U WITH DOT BELOW
     ["u-."] = 0x1ee5, -- LATIN SMALL LETTER U WITH DOT BELOW
      ["U2"] = 0x1ee6, -- LATIN CAPITAL LETTER U WITH HOOK ABOVE
      ["u2"] = 0x1ee7, -- LATIN SMALL LETTER U WITH HOOK ABOVE
     ["U9'"] = 0x1ee8, -- LATIN CAPITAL LETTER U WITH HORN AND ACUTE
     ["u9'"] = 0x1ee9, -- LATIN SMALL LETTER U WITH HORN AND ACUTE
     ["U9!"] = 0x1eea, -- LATIN CAPITAL LETTER U WITH HORN AND GRAVE
     ["u9!"] = 0x1eeb, -- LATIN SMALL LETTER U WITH HORN AND GRAVE
     ["U92"] = 0x1eec, -- LATIN CAPITAL LETTER U WITH HORN AND HOOK ABOVE
     ["u92"] = 0x1eed, -- LATIN SMALL LETTER U WITH HORN AND HOOK ABOVE
     ["U9?"] = 0x1eee, -- LATIN CAPITAL LETTER U WITH HORN AND TILDE
     ["u9?"] = 0x1eef, -- LATIN SMALL LETTER U WITH HORN AND TILDE
    ["U9-."] = 0x1ef0, -- LATIN CAPITAL LETTER U WITH HORN AND DOT BELOW
    ["u9-."] = 0x1ef1, -- LATIN SMALL LETTER U WITH HORN AND DOT BELOW
      ["Y!"] = 0x1ef2, -- LATIN CAPITAL LETTER Y WITH GRAVE
      ["y!"] = 0x1ef3, -- LATIN SMALL LETTER Y WITH GRAVE
     ["Y-."] = 0x1ef4, -- LATIN CAPITAL LETTER Y WITH DOT BELOW
     ["y-."] = 0x1ef5, -- LATIN SMALL LETTER Y WITH DOT BELOW
      ["Y2"] = 0x1ef6, -- LATIN CAPITAL LETTER Y WITH HOOK ABOVE
      ["y2"] = 0x1ef7, -- LATIN SMALL LETTER Y WITH HOOK ABOVE
      ["Y?"] = 0x1ef8, -- LATIN CAPITAL LETTER Y WITH TILDE
      ["y?"] = 0x1ef9, -- LATIN SMALL LETTER Y WITH TILDE
      [";'"] = 0x1f00, -- GREEK DASIA AND ACUTE ACCENT
      [",'"] = 0x1f01, -- GREEK PSILI AND ACUTE ACCENT
      [";!"] = 0x1f02, -- GREEK DASIA AND VARIA
      [",!"] = 0x1f03, -- GREEK PSILI AND VARIA
      ["?;"] = 0x1f04, -- GREEK DASIA AND PERISPOMENI
      ["?,"] = 0x1f05, -- GREEK PSILI AND PERISPOMENI
      ["!:"] = 0x1f06, -- GREEK DIAERESIS AND VARIA
      ["?:"] = 0x1f07, -- GREEK DIAERESIS AND PERISPOMENI
      ["1N"] = 0x2002, -- EN SPACE
      ["1M"] = 0x2003, -- EM SPACE
      ["3M"] = 0x2004, -- THREE-PER-EM SPACE
      ["4M"] = 0x2005, -- FOUR-PER-EM SPACE
      ["6M"] = 0x2006, -- SIX-PER-EM SPACE
      ["1T"] = 0x2009, -- THIN SPACE
      ["1H"] = 0x200a, -- HAIR SPACE
      ["-1"] = 0x2010, -- HYPHEN
      ["-N"] = 0x2013, -- EN DASH
      ["-M"] = 0x2014, -- EM DASH
      ["-3"] = 0x2015, -- HORIZONTAL BAR
      ["!2"] = 0x2016, -- DOUBLE VERTICAL LINE
      ["=2"] = 0x2017, -- DOUBLE LOW LINE
      ["'6"] = 0x2018, -- LEFT SINGLE QUOTATION MARK
      ["'9"] = 0x2019, -- RIGHT SINGLE QUOTATION MARK
      [".9"] = 0x201a, -- SINGLE LOW-9 QUOTATION MARK
      ["9'"] = 0x201b, -- SINGLE HIGH-REVERSED-9 QUOTATION MARK
     ["\"6"] = 0x201c, -- LEFT DOUBLE QUOTATION MARK
     ["\"9"] = 0x201d, -- RIGHT DOUBLE QUOTATION MARK
      [":9"] = 0x201e, -- DOUBLE LOW-9 QUOTATION MARK
     ["9\""] = 0x201f, -- DOUBLE HIGH-REVERSED-9 QUOTATION MARK
      ["/-"] = 0x2020, -- DAGGER
      ["/="] = 0x2021, -- DOUBLE DAGGER
      [".."] = 0x2025, -- TWO DOT LEADER
      ["%0"] = 0x2030, -- PER MILLE SIGN
      ["1'"] = 0x2032, -- PRIME
      ["2'"] = 0x2033, -- DOUBLE PRIME
      ["3'"] = 0x2034, -- TRIPLE PRIME
     ["1\""] = 0x2035, -- REVERSED PRIME
     ["2\""] = 0x2036, -- REVERSED DOUBLE PRIME
     ["3\""] = 0x2037, -- REVERSED TRIPLE PRIME
      ["Ca"] = 0x2038, -- CARET
      ["<1"] = 0x2039, -- SINGLE LEFT-POINTING ANGLE QUOTATION MARK
      [">1"] = 0x203a, -- SINGLE RIGHT-POINTING ANGLE QUOTATION MARK
      [":X"] = 0x203b, -- REFERENCE MARK
     ["!*2"] = 0x203c, -- DOUBLE EXCLAMATION MARK
      ["'-"] = 0x203e, -- OVERLINE
      ["/f"] = 0x2044, -- FRACTION SLASH
      ["0S"] = 0x2070, -- SUPERSCRIPT DIGIT ZERO
      ["4S"] = 0x2074, -- SUPERSCRIPT DIGIT FOUR
      ["5S"] = 0x2075, -- SUPERSCRIPT DIGIT FIVE
      ["6S"] = 0x2076, -- SUPERSCRIPT DIGIT SIX
      ["7S"] = 0x2077, -- SUPERSCRIPT DIGIT SEVEN
      ["8S"] = 0x2078, -- SUPERSCRIPT DIGIT EIGHT
      ["9S"] = 0x2079, -- SUPERSCRIPT DIGIT NINE
      ["+S"] = 0x207a, -- SUPERSCRIPT PLUS SIGN
      ["-S"] = 0x207b, -- SUPERSCRIPT MINUS
      ["=S"] = 0x207c, -- SUPERSCRIPT EQUALS SIGN
      ["(S"] = 0x207d, -- SUPERSCRIPT LEFT PARENTHESIS
      [")S"] = 0x207e, -- SUPERSCRIPT RIGHT PARENTHESIS
      ["nS"] = 0x207f, -- SUPERSCRIPT LATIN SMALL LETTER N
      ["0s"] = 0x2080, -- SUBSCRIPT DIGIT ZERO
      ["1s"] = 0x2081, -- SUBSCRIPT DIGIT ONE
      ["2s"] = 0x2082, -- SUBSCRIPT DIGIT TWO
      ["3s"] = 0x2083, -- SUBSCRIPT DIGIT THREE
      ["4s"] = 0x2084, -- SUBSCRIPT DIGIT FOUR
      ["5s"] = 0x2085, -- SUBSCRIPT DIGIT FIVE
      ["6s"] = 0x2086, -- SUBSCRIPT DIGIT SIX
      ["7s"] = 0x2087, -- SUBSCRIPT DIGIT SEVEN
      ["8s"] = 0x2088, -- SUBSCRIPT DIGIT EIGHT
      ["9s"] = 0x2089, -- SUBSCRIPT DIGIT NINE
      ["+s"] = 0x208a, -- SUBSCRIPT PLUS SIGN
      ["-s"] = 0x208b, -- SUBSCRIPT MINUS
      ["=s"] = 0x208c, -- SUBSCRIPT EQUALS SIGN
      ["(s"] = 0x208d, -- SUBSCRIPT LEFT PARENTHESIS
      [")s"] = 0x208e, -- SUBSCRIPT RIGHT PARENTHESIS
      ["Li"] = 0x20a4, -- LIRA SIGN
      ["Pt"] = 0x20a7, -- PESETA SIGN
      ["W="] = 0x20a9, -- WON SIGN
      ["oC"] = 0x2103, -- DEGREE CENTIGRADE
      ["co"] = 0x2105, -- CARE OF
      ["oF"] = 0x2109, -- DEGREE FAHRENHEIT
      ["N0"] = 0x2116, -- NUMERO SIGN
      ["PO"] = 0x2117, -- SOUND RECORDING COPYRIGHT
      ["Rx"] = 0x211e, -- PRESCRIPTION TAKE
      ["SM"] = 0x2120, -- SERVICE MARK
      ["TM"] = 0x2122, -- TRADE MARK SIGN
      ["Om"] = 0x2126, -- OHM SIGN
      ["AO"] = 0x212b, -- ANGSTROEM SIGN
      ["13"] = 0x2153, -- VULGAR FRACTION ONE THIRD
      ["23"] = 0x2154, -- VULGAR FRACTION TWO THIRDS
      ["15"] = 0x2155, -- VULGAR FRACTION ONE FIFTH
      ["25"] = 0x2156, -- VULGAR FRACTION TWO FIFTHS
      ["35"] = 0x2157, -- VULGAR FRACTION THREE FIFTHS
      ["45"] = 0x2158, -- VULGAR FRACTION FOUR FIFTHS
      ["16"] = 0x2159, -- VULGAR FRACTION ONE SIXTH
      ["56"] = 0x215a, -- VULGAR FRACTION FIVE SIXTHS
      ["18"] = 0x215b, -- VULGAR FRACTION ONE EIGHTH
      ["38"] = 0x215c, -- VULGAR FRACTION THREE EIGHTHS
      ["58"] = 0x215d, -- VULGAR FRACTION FIVE EIGHTHS
      ["78"] = 0x215e, -- VULGAR FRACTION SEVEN EIGHTHS
      ["1R"] = 0x2160, -- ROMAN NUMERAL ONE
      ["2R"] = 0x2161, -- ROMAN NUMERAL TWO
      ["3R"] = 0x2162, -- ROMAN NUMERAL THREE
      ["4R"] = 0x2163, -- ROMAN NUMERAL FOUR
      ["5R"] = 0x2164, -- ROMAN NUMERAL FIVE
      ["6R"] = 0x2165, -- ROMAN NUMERAL SIX
      ["7R"] = 0x2166, -- ROMAN NUMERAL SEVEN
      ["8R"] = 0x2167, -- ROMAN NUMERAL EIGHT
      ["9R"] = 0x2168, -- ROMAN NUMERAL NINE
      ["aR"] = 0x2169, -- ROMAN NUMERAL TEN
      ["bR"] = 0x216a, -- ROMAN NUMERAL ELEVEN
      ["cR"] = 0x216b, -- ROMAN NUMERAL TWELVE
     ["50R"] = 0x216c, -- ROMAN NUMERAL FIFTY
    ["100R"] = 0x216d, -- ROMAN NUMERAL ONE HUNDRED
    ["500R"] = 0x216e, -- ROMAN NUMERAL FIVE HUNDRED
   ["1000R"] = 0x216f, -- ROMAN NUMERAL ONE THOUSAND
      ["1r"] = 0x2170, -- SMALL ROMAN NUMERAL ONE
      ["2r"] = 0x2171, -- SMALL ROMAN NUMERAL TWO
      ["3r"] = 0x2172, -- SMALL ROMAN NUMERAL THREE
      ["4r"] = 0x2173, -- SMALL ROMAN NUMERAL FOUR
      ["5r"] = 0x2174, -- SMALL ROMAN NUMERAL FIVE
      ["6r"] = 0x2175, -- SMALL ROMAN NUMERAL SIX
      ["7r"] = 0x2176, -- SMALL ROMAN NUMERAL SEVEN
      ["8r"] = 0x2177, -- SMALL ROMAN NUMERAL EIGHT
      ["9r"] = 0x2178, -- SMALL ROMAN NUMERAL NINE
      ["ar"] = 0x2179, -- SMALL ROMAN NUMERAL TEN
      ["br"] = 0x217a, -- SMALL ROMAN NUMERAL ELEVEN
      ["cr"] = 0x217b, -- SMALL ROMAN NUMERAL TWELVE
     ["50r"] = 0x217c, -- SMALL ROMAN NUMERAL FIFTY
    ["100r"] = 0x217d, -- SMALL ROMAN NUMERAL ONE HUNDRED
    ["500r"] = 0x217e, -- SMALL ROMAN NUMERAL FIVE HUNDRED
   ["1000r"] = 0x217f, -- SMALL ROMAN NUMERAL ONE THOUSAND
 ["1000RCD"] = 0x2180, -- ROMAN NUMERAL ONE THOUSAND C D
   ["5000R"] = 0x2181, -- ROMAN NUMERAL FIVE THOUSAND
  ["10000R"] = 0x2182, -- ROMAN NUMERAL TEN THOUSAND
      ["<-"] = 0x2190, -- LEFTWARDS ARROW
      ["-!"] = 0x2191, -- UPWARDS ARROW
      ["->"] = 0x2192, -- RIGHTWARDS ARROW
      ["-v"] = 0x2193, -- DOWNWARDS ARROW
      ["<>"] = 0x2194, -- LEFT RIGHT ARROW
      ["UD"] = 0x2195, -- UP DOWN ARROW
     ["<!!"] = 0x2196, -- NORTH WEST ARROW
     ["//>"] = 0x2197, -- NORTH EAST ARROW
     ["!!>"] = 0x2198, -- SOUTH EAST ARROW
     ["<//"] = 0x2199, -- SOUTH WEST ARROW
      ["<="] = 0x21d0, -- LEFTWARDS DOUBLE ARROW
      ["=>"] = 0x21d2, -- RIGHTWARDS DOUBLE ARROW
      ["=="] = 0x21d4, -- LEFT RIGHT DOUBLE ARROW
      ["FA"] = 0x2200, -- FOR ALL
      ["dP"] = 0x2202, -- PARTIAL DIFFERENTIAL
      ["TE"] = 0x2203, -- THERE EXISTS
      ["/0"] = 0x2205, -- EMPTY SET
      ["DE"] = 0x2206, -- INCREMENT
      ["NB"] = 0x2207, -- NABLA
      ["(-"] = 0x2208, -- ELEMENT OF
      ["-)"] = 0x220b, -- CONTAINS AS MEMBER
      ["*P"] = 0x220f, -- N-ARY PRODUCT
      ["+Z"] = 0x2211, -- N-ARY SUMMATION
      ["-2"] = 0x2212, -- MINUS SIGN
      ["-+"] = 0x2213, -- MINUS-OR-PLUS SIGN
      ["*-"] = 0x2217, -- ASTERISK OPERATOR
      ["Ob"] = 0x2218, -- RING OPERATOR
      ["Sb"] = 0x2219, -- BULLET OPERATOR
      ["RT"] = 0x221a, -- SQUARE ROOT
      ["0("] = 0x221d, -- PROPORTIONAL TO
      ["00"] = 0x221e, -- INFINITY
      ["-L"] = 0x221f, -- RIGHT ANGLE
      ["-V"] = 0x2220, -- ANGLE
      ["PP"] = 0x2225, -- PARALLEL TO
      ["AN"] = 0x2227, -- LOGICAL AND
      ["OR"] = 0x2228, -- LOGICAL OR
      ["(U"] = 0x2229, -- INTERSECTION
      [")U"] = 0x222a, -- UNION
      ["In"] = 0x222b, -- INTEGRAL
      ["DI"] = 0x222c, -- DOUBLE INTEGRAL
      ["Io"] = 0x222e, -- CONTOUR INTEGRAL
      [".:"] = 0x2234, -- THEREFORE
      [":."] = 0x2235, -- BECAUSE
      [":R"] = 0x2236, -- RATIO
      ["::"] = 0x2237, -- PROPORTION
      ["?1"] = 0x223c, -- TILDE OPERATOR
      ["CG"] = 0x223e, -- INVERTED LAZY S
      ["?-"] = 0x2243, -- ASYMPTOTICALLY EQUAL TO
      ["?="] = 0x2245, -- APPROXIMATELY EQUAL TO
      ["?2"] = 0x2248, -- ALMOST EQUAL TO
      ["=?"] = 0x224c, -- ALL EQUAL TO
      ["HI"] = 0x2253, -- IMAGE OF OR APPROXIMATELY EQUAL TO
      ["!="] = 0x2260, -- NOT EQUAL TO
      ["=3"] = 0x2261, -- IDENTICAL TO
      ["=<"] = 0x2264, -- LESS-THAN OR EQUAL TO
      [">="] = 0x2265, -- GREATER-THAN OR EQUAL TO
      ["<*"] = 0x226a, -- MUCH LESS-THAN
      ["*>"] = 0x226b, -- MUCH GREATER-THAN
      ["!<"] = 0x226e, -- NOT LESS-THAN
      ["!>"] = 0x226f, -- NOT GREATER-THAN
      ["(C"] = 0x2282, -- SUBSET OF
      [")C"] = 0x2283, -- SUPERSET OF
      ["(_"] = 0x2286, -- SUBSET OF OR EQUAL TO
      [")_"] = 0x2287, -- SUPERSET OF OR EQUAL TO
      ["0."] = 0x2299, -- CIRCLED DOT OPERATOR
      ["02"] = 0x229a, -- CIRCLED RING OPERATOR
      ["-T"] = 0x22a5, -- UP TACK
      [".P"] = 0x22c5, -- DOT OPERATOR
      [":3"] = 0x22ee, -- VERTICAL ELLIPSIS
      [".3"] = 0x22ef, -- MIDLINE HORIZONTAL ELLIPSIS
      ["Eh"] = 0x2302, -- HOUSE
      ["<7"] = 0x2308, -- LEFT CEILING
      [">7"] = 0x2309, -- RIGHT CEILING
      ["7<"] = 0x230a, -- LEFT FLOOR
      ["7>"] = 0x230b, -- RIGHT FLOOR
      ["NI"] = 0x2310, -- REVERSED NOT SIGN
      ["(A"] = 0x2312, -- ARC
      ["TR"] = 0x2315, -- TELEPHONE RECORDER
      ["Iu"] = 0x2320, -- TOP HALF INTEGRAL
      ["Il"] = 0x2321, -- BOTTOM HALF INTEGRAL
      ["</"] = 0x2329, -- LEFT-POINTING ANGLE BRACKET
      ["/>"] = 0x232a, -- RIGHT-POINTING ANGLE BRACKET
      ["Vs"] = 0x2423, -- OPEN BOX
      ["1h"] = 0x2440, -- OCR HOOK
      ["3h"] = 0x2441, -- OCR CHAIR
      ["2h"] = 0x2442, -- OCR FORK
      ["4h"] = 0x2443, -- OCR INVERTED FORK
      ["1j"] = 0x2446, -- OCR BRANCH BANK IDENTIFICATION
      ["2j"] = 0x2447, -- OCR AMOUNT OF CHECK
      ["3j"] = 0x2448, -- OCR DASH
      ["4j"] = 0x2449, -- OCR CUSTOMER ACCOUNT NUMBER
     ["1-o"] = 0x2460, -- CIRCLED DIGIT ONE
     ["2-o"] = 0x2461, -- CIRCLED DIGIT TWO
     ["3-o"] = 0x2462, -- CIRCLED DIGIT THREE
     ["4-o"] = 0x2463, -- CIRCLED DIGIT FOUR
     ["5-o"] = 0x2464, -- CIRCLED DIGIT FIVE
     ["6-o"] = 0x2465, -- CIRCLED DIGIT SIX
     ["7-o"] = 0x2466, -- CIRCLED DIGIT SEVEN
     ["8-o"] = 0x2467, -- CIRCLED DIGIT EIGHT
     ["9-o"] = 0x2468, -- CIRCLED DIGIT NINE
    ["10-o"] = 0x2469, -- CIRCLED NUMBER TEN
    ["11-o"] = 0x246a, -- CIRCLED NUMBER ELEVEN
    ["12-o"] = 0x246b, -- CIRCLED NUMBER TWELVE
    ["13-o"] = 0x246c, -- CIRCLED NUMBER THIRTEEN
    ["14-o"] = 0x246d, -- CIRCLED NUMBER FOURTEEN
    ["15-o"] = 0x246e, -- CIRCLED NUMBER FIFTEEN
    ["16-o"] = 0x246f, -- CIRCLED NUMBER SIXTEEN
    ["17-o"] = 0x2470, -- CIRCLED NUMBER SEVENTEEN
    ["18-o"] = 0x2471, -- CIRCLED NUMBER EIGHTEEN
    ["19-o"] = 0x2472, -- CIRCLED NUMBER NINETEEN
    ["20-o"] = 0x2473, -- CIRCLED NUMBER TWENTY
     ["(1)"] = 0x2474, -- PARENTHESIZED DIGIT ONE
     ["(2)"] = 0x2475, -- PARENTHESIZED DIGIT TWO
     ["(3)"] = 0x2476, -- PARENTHESIZED DIGIT THREE
     ["(4)"] = 0x2477, -- PARENTHESIZED DIGIT FOUR
     ["(5)"] = 0x2478, -- PARENTHESIZED DIGIT FIVE
     ["(6)"] = 0x2479, -- PARENTHESIZED DIGIT SIX
     ["(7)"] = 0x247a, -- PARENTHESIZED DIGIT SEVEN
     ["(8)"] = 0x247b, -- PARENTHESIZED DIGIT EIGHT
     ["(9)"] = 0x247c, -- PARENTHESIZED DIGIT NINE
    ["(10)"] = 0x247d, -- PARENTHESIZED NUMBER TEN
    ["(11)"] = 0x247e, -- PARENTHESIZED NUMBER ELEVEN
    ["(12)"] = 0x247f, -- PARENTHESIZED NUMBER TWELVE
    ["(13)"] = 0x2480, -- PARENTHESIZED NUMBER THIRTEEN
    ["(14)"] = 0x2481, -- PARENTHESIZED NUMBER FOURTEEN
    ["(15)"] = 0x2482, -- PARENTHESIZED NUMBER FIFTEEN
    ["(16)"] = 0x2483, -- PARENTHESIZED NUMBER SIXTEEN
    ["(17)"] = 0x2484, -- PARENTHESIZED NUMBER SEVENTEEN
    ["(18)"] = 0x2485, -- PARENTHESIZED NUMBER EIGHTEEN
    ["(19)"] = 0x2486, -- PARENTHESIZED NUMBER NINETEEN
    ["(20)"] = 0x2487, -- PARENTHESIZED NUMBER TWENTY
      ["1."] = 0x2488, -- DIGIT ONE FULL STOP
      ["2."] = 0x2489, -- DIGIT TWO FULL STOP
      ["3."] = 0x248a, -- DIGIT THREE FULL STOP
      ["4."] = 0x248b, -- DIGIT FOUR FULL STOP
      ["5."] = 0x248c, -- DIGIT FIVE FULL STOP
      ["6."] = 0x248d, -- DIGIT SIX FULL STOP
      ["7."] = 0x248e, -- DIGIT SEVEN FULL STOP
      ["8."] = 0x248f, -- DIGIT EIGHT FULL STOP
      ["9."] = 0x2490, -- DIGIT NINE FULL STOP
     ["10."] = 0x2491, -- NUMBER TEN FULL STOP
     ["11."] = 0x2492, -- NUMBER ELEVEN FULL STOP
     ["12."] = 0x2493, -- NUMBER TWELVE FULL STOP
     ["13."] = 0x2494, -- NUMBER THIRTEEN FULL STOP
     ["14."] = 0x2495, -- NUMBER FOURTEEN FULL STOP
     ["15."] = 0x2496, -- NUMBER FIFTEEN FULL STOP
     ["16."] = 0x2497, -- NUMBER SIXTEEN FULL STOP
     ["17."] = 0x2498, -- NUMBER SEVENTEEN FULL STOP
     ["18."] = 0x2499, -- NUMBER EIGHTEEN FULL STOP
     ["19."] = 0x249a, -- NUMBER NINETEEN FULL STOP
     ["20."] = 0x249b, -- NUMBER TWENTY FULL STOP
     ["(a)"] = 0x249c, -- PARENTHESIZED LATIN SMALL LETTER A
     ["(b)"] = 0x249d, -- PARENTHESIZED LATIN SMALL LETTER B
     ["(c)"] = 0x249e, -- PARENTHESIZED LATIN SMALL LETTER C
     ["(d)"] = 0x249f, -- PARENTHESIZED LATIN SMALL LETTER D
     ["(e)"] = 0x24a0, -- PARENTHESIZED LATIN SMALL LETTER E
     ["(f)"] = 0x24a1, -- PARENTHESIZED LATIN SMALL LETTER F
     ["(g)"] = 0x24a2, -- PARENTHESIZED LATIN SMALL LETTER G
     ["(h)"] = 0x24a3, -- PARENTHESIZED LATIN SMALL LETTER H
     ["(i)"] = 0x24a4, -- PARENTHESIZED LATIN SMALL LETTER I
     ["(j)"] = 0x24a5, -- PARENTHESIZED LATIN SMALL LETTER J
     ["(k)"] = 0x24a6, -- PARENTHESIZED LATIN SMALL LETTER K
     ["(l)"] = 0x24a7, -- PARENTHESIZED LATIN SMALL LETTER L
     ["(m)"] = 0x24a8, -- PARENTHESIZED LATIN SMALL LETTER M
     ["(n)"] = 0x24a9, -- PARENTHESIZED LATIN SMALL LETTER N
     ["(o)"] = 0x24aa, -- PARENTHESIZED LATIN SMALL LETTER O
     ["(p)"] = 0x24ab, -- PARENTHESIZED LATIN SMALL LETTER P
     ["(q)"] = 0x24ac, -- PARENTHESIZED LATIN SMALL LETTER Q
     ["(r)"] = 0x24ad, -- PARENTHESIZED LATIN SMALL LETTER R
     ["(s)"] = 0x24ae, -- PARENTHESIZED LATIN SMALL LETTER S
     ["(t)"] = 0x24af, -- PARENTHESIZED LATIN SMALL LETTER T
     ["(u)"] = 0x24b0, -- PARENTHESIZED LATIN SMALL LETTER U
     ["(v)"] = 0x24b1, -- PARENTHESIZED LATIN SMALL LETTER V
     ["(w)"] = 0x24b2, -- PARENTHESIZED LATIN SMALL LETTER W
     ["(x)"] = 0x24b3, -- PARENTHESIZED LATIN SMALL LETTER X
     ["(y)"] = 0x24b4, -- PARENTHESIZED LATIN SMALL LETTER Y
     ["(z)"] = 0x24b5, -- PARENTHESIZED LATIN SMALL LETTER Z
     ["A-o"] = 0x24b6, -- CIRCLED LATIN CAPITAL LETTER A
     ["B-o"] = 0x24b7, -- CIRCLED LATIN CAPITAL LETTER B
     ["C-o"] = 0x24b8, -- CIRCLED LATIN CAPITAL LETTER C
     ["D-o"] = 0x24b9, -- CIRCLED LATIN CAPITAL LETTER D
     ["E-o"] = 0x24ba, -- CIRCLED LATIN CAPITAL LETTER E
     ["F-o"] = 0x24bb, -- CIRCLED LATIN CAPITAL LETTER F
     ["G-o"] = 0x24bc, -- CIRCLED LATIN CAPITAL LETTER G
     ["H-o"] = 0x24bd, -- CIRCLED LATIN CAPITAL LETTER H
     ["I-o"] = 0x24be, -- CIRCLED LATIN CAPITAL LETTER I
     ["J-o"] = 0x24bf, -- CIRCLED LATIN CAPITAL LETTER J
     ["K-o"] = 0x24c0, -- CIRCLED LATIN CAPITAL LETTER K
     ["L-o"] = 0x24c1, -- CIRCLED LATIN CAPITAL LETTER L
     ["M-o"] = 0x24c2, -- CIRCLED LATIN CAPITAL LETTER M
     ["N-o"] = 0x24c3, -- CIRCLED LATIN CAPITAL LETTER N
     ["O-o"] = 0x24c4, -- CIRCLED LATIN CAPITAL LETTER O
     ["P-o"] = 0x24c5, -- CIRCLED LATIN CAPITAL LETTER P
     ["Q-o"] = 0x24c6, -- CIRCLED LATIN CAPITAL LETTER Q
     ["R-o"] = 0x24c7, -- CIRCLED LATIN CAPITAL LETTER R
     ["S-o"] = 0x24c8, -- CIRCLED LATIN CAPITAL LETTER S
     ["T-o"] = 0x24c9, -- CIRCLED LATIN CAPITAL LETTER T
     ["U-o"] = 0x24ca, -- CIRCLED LATIN CAPITAL LETTER U
     ["V-o"] = 0x24cb, -- CIRCLED LATIN CAPITAL LETTER V
     ["W-o"] = 0x24cc, -- CIRCLED LATIN CAPITAL LETTER W
     ["X-o"] = 0x24cd, -- CIRCLED LATIN CAPITAL LETTER X
     ["Y-o"] = 0x24ce, -- CIRCLED LATIN CAPITAL LETTER Y
     ["Z-o"] = 0x24cf, -- CIRCLED LATIN CAPITAL LETTER Z
     ["a-o"] = 0x24d0, -- CIRCLED LATIN SMALL LETTER A
     ["b-o"] = 0x24d1, -- CIRCLED LATIN SMALL LETTER B
     ["c-o"] = 0x24d2, -- CIRCLED LATIN SMALL LETTER C
     ["d-o"] = 0x24d3, -- CIRCLED LATIN SMALL LETTER D
     ["e-o"] = 0x24d4, -- CIRCLED LATIN SMALL LETTER E
     ["f-o"] = 0x24d5, -- CIRCLED LATIN SMALL LETTER F
     ["g-o"] = 0x24d6, -- CIRCLED LATIN SMALL LETTER G
     ["h-o"] = 0x24d7, -- CIRCLED LATIN SMALL LETTER H
     ["i-o"] = 0x24d8, -- CIRCLED LATIN SMALL LETTER I
     ["j-o"] = 0x24d9, -- CIRCLED LATIN SMALL LETTER J
     ["k-o"] = 0x24da, -- CIRCLED LATIN SMALL LETTER K
     ["l-o"] = 0x24db, -- CIRCLED LATIN SMALL LETTER L
     ["m-o"] = 0x24dc, -- CIRCLED LATIN SMALL LETTER M
     ["n-o"] = 0x24dd, -- CIRCLED LATIN SMALL LETTER N
     ["o-o"] = 0x24de, -- CIRCLED LATIN SMALL LETTER O
     ["p-o"] = 0x24df, -- CIRCLED LATIN SMALL LETTER P
     ["q-o"] = 0x24e0, -- CIRCLED LATIN SMALL LETTER Q
     ["r-o"] = 0x24e1, -- CIRCLED LATIN SMALL LETTER R
     ["s-o"] = 0x24e2, -- CIRCLED LATIN SMALL LETTER S
     ["t-o"] = 0x24e3, -- CIRCLED LATIN SMALL LETTER T
     ["u-o"] = 0x24e4, -- CIRCLED LATIN SMALL LETTER U
     ["v-o"] = 0x24e5, -- CIRCLED LATIN SMALL LETTER V
     ["w-o"] = 0x24e6, -- CIRCLED LATIN SMALL LETTER W
     ["x-o"] = 0x24e7, -- CIRCLED LATIN SMALL LETTER X
     ["y-o"] = 0x24e8, -- CIRCLED LATIN SMALL LETTER Y
     ["z-o"] = 0x24e9, -- CIRCLED LATIN SMALL LETTER Z
     ["0-o"] = 0x24ea, -- CIRCLED DIGIT ZERO
      ["hh"] = 0x2500, -- BOX DRAWINGS LIGHT HORIZONTAL
      ["HH"] = 0x2501, -- BOX DRAWINGS HEAVY HORIZONTAL
      ["vv"] = 0x2502, -- BOX DRAWINGS LIGHT VERTICAL
      ["VV"] = 0x2503, -- BOX DRAWINGS HEAVY VERTICAL
      ["3-"] = 0x2504, -- BOX DRAWINGS LIGHT TRIPLE DASH HORIZONTAL
      ["3_"] = 0x2505, -- BOX DRAWINGS HEAVY TRIPLE DASH HORIZONTAL
      ["3!"] = 0x2506, -- BOX DRAWINGS LIGHT TRIPLE DASH VERTICAL
      ["3/"] = 0x2507, -- BOX DRAWINGS HEAVY TRIPLE DASH VERTICAL
      ["4-"] = 0x2508, -- BOX DRAWINGS LIGHT QUADRUPLE DASH HORIZONTAL
      ["4_"] = 0x2509, -- BOX DRAWINGS HEAVY QUADRUPLE DASH HORIZONTAL
      ["4!"] = 0x250a, -- BOX DRAWINGS LIGHT QUADRUPLE DASH VERTICAL
      ["4/"] = 0x250b, -- BOX DRAWINGS HEAVY QUADRUPLE DASH VERTICAL
      ["dr"] = 0x250c, -- BOX DRAWINGS LIGHT DOWN AND RIGHT
      ["dR"] = 0x250d, -- BOX DRAWINGS DOWN LIGHT AND RIGHT HEAVY
      ["Dr"] = 0x250e, -- BOX DRAWINGS DOWN HEAVY AND RIGHT LIGHT
      ["DR"] = 0x250f, -- BOX DRAWINGS HEAVY DOWN AND RIGHT
      ["dl"] = 0x2510, -- BOX DRAWINGS LIGHT DOWN AND LEFT
      ["dL"] = 0x2511, -- BOX DRAWINGS DOWN LIGHT AND LEFT HEAVY
      ["Dl"] = 0x2512, -- BOX DRAWINGS DOWN HEAVY AND LEFT LIGHT
      ["LD"] = 0x2513, -- BOX DRAWINGS HEAVY DOWN AND LEFT
      ["ur"] = 0x2514, -- BOX DRAWINGS LIGHT UP AND RIGHT
      ["uR"] = 0x2515, -- BOX DRAWINGS UP LIGHT AND RIGHT HEAVY
      ["Ur"] = 0x2516, -- BOX DRAWINGS UP HEAVY AND RIGHT LIGHT
      ["UR"] = 0x2517, -- BOX DRAWINGS HEAVY UP AND RIGHT
      ["ul"] = 0x2518, -- BOX DRAWINGS LIGHT UP AND LEFT
      ["uL"] = 0x2519, -- BOX DRAWINGS UP LIGHT AND LEFT HEAVY
      ["Ul"] = 0x251a, -- BOX DRAWINGS UP HEAVY AND LEFT LIGHT
      ["UL"] = 0x251b, -- BOX DRAWINGS HEAVY UP AND LEFT
      ["vr"] = 0x251c, -- BOX DRAWINGS LIGHT VERTICAL AND RIGHT
      ["vR"] = 0x251d, -- BOX DRAWINGS VERTICAL LIGHT AND RIGHT HEAVY
     ["Udr"] = 0x251e, -- BOX DRAWINGS UP HEAVY AND RIGHT DOWN LIGHT
     ["uDr"] = 0x251f, -- BOX DRAWINGS DOWN HEAVY AND RIGHT UP LIGHT
      ["Vr"] = 0x2520, -- BOX DRAWINGS VERTICAL HEAVY AND RIGHT LIGHT
     ["UdR"] = 0x2521, -- BOX DRAWINGS DOWN LIGHT AND RIGHT UP HEAVY
     ["uDR"] = 0x2522, -- BOX DRAWINGS UP LIGHT AND RIGHT DOWN HEAVY
      ["VR"] = 0x2523, -- BOX DRAWINGS HEAVY VERTICAL AND RIGHT
      ["vl"] = 0x2524, -- BOX DRAWINGS LIGHT VERTICAL AND LEFT
      ["vL"] = 0x2525, -- BOX DRAWINGS VERTICAL LIGHT AND LEFT HEAVY
     ["Udl"] = 0x2526, -- BOX DRAWINGS UP HEAVY AND LEFT DOWN LIGHT
     ["uDl"] = 0x2527, -- BOX DRAWINGS DOWN HEAVY AND LEFT UP LIGHT
      ["Vl"] = 0x2528, -- BOX DRAWINGS VERTICAL HEAVY AND LEFT LIGHT
     ["UdL"] = 0x2529, -- BOX DRAWINGS DOWN LIGHT AND LEFT UP HEAVY
     ["uDL"] = 0x252a, -- BOX DRAWINGS UP LIGHT AND LEFT DOWN HEAVY
      ["VL"] = 0x252b, -- BOX DRAWINGS HEAVY VERTICAL AND LEFT
      ["dh"] = 0x252c, -- BOX DRAWINGS LIGHT DOWN AND HORIZONTAL
     ["dLr"] = 0x252d, -- BOX DRAWINGS LEFT HEAVY AND RIGHT DOWN LIGHT
     ["dlR"] = 0x252e, -- BOX DRAWINGS RIGHT HEAVY AND LEFT DOWN LIGHT
      ["dH"] = 0x252f, -- BOX DRAWINGS DOWN LIGHT AND HORIZONTAL HEAVY
      ["Dh"] = 0x2530, -- BOX DRAWINGS DOWN HEAVY AND HORIZONTAL LIGHT
     ["DLr"] = 0x2531, -- BOX DRAWINGS RIGHT LIGHT AND LEFT DOWN HEAVY
     ["DlR"] = 0x2532, -- BOX DRAWINGS LEFT LIGHT AND RIGHT DOWN HEAVY
      ["DH"] = 0x2533, -- BOX DRAWINGS HEAVY DOWN AND HORIZONTAL
      ["uh"] = 0x2534, -- BOX DRAWINGS LIGHT UP AND HORIZONTAL
     ["uLr"] = 0x2535, -- BOX DRAWINGS LEFT HEAVY AND RIGHT UP LIGHT
     ["ulR"] = 0x2536, -- BOX DRAWINGS RIGHT HEAVY AND LEFT UP LIGHT
      ["uH"] = 0x2537, -- BOX DRAWINGS UP LIGHT AND HORIZONTAL HEAVY
      ["Uh"] = 0x2538, -- BOX DRAWINGS UP HEAVY AND HORIZONTAL LIGHT
     ["ULr"] = 0x2539, -- BOX DRAWINGS RIGHT LIGHT AND LEFT UP HEAVY
     ["UlR"] = 0x253a, -- BOX DRAWINGS LEFT LIGHT AND RIGHT UP HEAVY
      ["UH"] = 0x253b, -- BOX DRAWINGS HEAVY UP AND HORIZONTAL
      ["vh"] = 0x253c, -- BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL
     ["vLr"] = 0x253d, -- BOX DRAWINGS LEFT HEAVY AND RIGHT VERTICAL LIGHT
     ["vlR"] = 0x253e, -- BOX DRAWINGS RIGHT HEAVY AND LEFT VERTICAL LIGHT
      ["vH"] = 0x253f, -- BOX DRAWINGS VERTICAL LIGHT AND HORIZONTAL HEAVY
     ["Udh"] = 0x2540, -- BOX DRAWINGS UP HEAVY AND DOWN HORIZONTAL LIGHT
     ["uDh"] = 0x2541, -- BOX DRAWINGS DOWN HEAVY AND UP HORIZONTAL LIGHT
      ["Vh"] = 0x2542, -- BOX DRAWINGS VERTICAL HEAVY AND HORIZONTAL LIGHT
    ["UdLr"] = 0x2543, -- BOX DRAWINGS LEFT UP HEAVY AND RIGHT DOWN LIGHT
    ["UdlR"] = 0x2544, -- BOX DRAWINGS RIGHT UP HEAVY AND LEFT DOWN LIGHT
    ["uDLr"] = 0x2545, -- BOX DRAWINGS LEFT DOWN HEAVY AND RIGHT UP LIGHT
    ["uDlR"] = 0x2546, -- BOX DRAWINGS RIGHT DOWN HEAVY AND LEFT UP LIGHT
     ["UdH"] = 0x2547, -- BOX DRAWINGS DOWN LIGHT AND UP HORIZONTAL HEAVY
     ["uDH"] = 0x2548, -- BOX DRAWINGS UP LIGHT AND DOWN HORIZONTAL HEAVY
     ["VLr"] = 0x2549, -- BOX DRAWINGS RIGHT LIGHT AND LEFT VERTICAL HEAVY
     ["VlR"] = 0x254a, -- BOX DRAWINGS LEFT LIGHT AND RIGHT VERTICAL HEAVY
      ["VH"] = 0x254b, -- BOX DRAWINGS HEAVY VERTICAL AND HORIZONTAL
      ["FD"] = 0x2571, -- BOX DRAWINGS LIGHT DIAGONAL UPPER RIGHT TO LOWER LEFT
      ["BD"] = 0x2572, -- BOX DRAWINGS LIGHT DIAGONAL UPPER LEFT TO LOWER RIGHT
      ["TB"] = 0x2580, -- UPPER HALF BLOCK
      ["LB"] = 0x2584, -- LOWER HALF BLOCK
      ["FB"] = 0x2588, -- FULL BLOCK
      ["lB"] = 0x258c, -- LEFT HALF BLOCK
      ["RB"] = 0x2590, -- RIGHT HALF BLOCK
      [".S"] = 0x2591, -- LIGHT SHADE
      [":S"] = 0x2592, -- MEDIUM SHADE
      ["?S"] = 0x2593, -- DARK SHADE
      ["fS"] = 0x25a0, -- BLACK SQUARE
      ["OS"] = 0x25a1, -- WHITE SQUARE
      ["RO"] = 0x25a2, -- WHITE SQUARE WITH ROUNDED CORNERS
      ["Rr"] = 0x25a3, -- WHITE SQUARE CONTAINING BLACK SMALL SQUARE
      ["RF"] = 0x25a4, -- SQUARE WITH HORIZONTAL FILL
      ["RY"] = 0x25a5, -- SQUARE WITH VERTICAL FILL
      ["RH"] = 0x25a6, -- SQUARE WITH ORTHOGONAL CROSSHATCH FILL
      ["RZ"] = 0x25a7, -- SQUARE WITH UPPER LEFT TO LOWER RIGHT FILL
      ["RK"] = 0x25a8, -- SQUARE WITH UPPER RIGHT TO LOWER LEFT FILL
      ["RX"] = 0x25a9, -- SQUARE WITH DIAGONAL CROSSHATCH FILL
      ["sB"] = 0x25aa, -- BLACK SMALL SQUARE
      ["SR"] = 0x25ac, -- BLACK RECTANGLE
      ["Or"] = 0x25ad, -- WHITE RECTANGLE
      ["UT"] = 0x25b2, -- BLACK UP-POINTING TRIANGLE
      ["uT"] = 0x25b3, -- WHITE UP-POINTING TRIANGLE
      ["PR"] = 0x25b6, -- BLACK RIGHT-POINTING TRIANGLE
      ["Tr"] = 0x25b7, -- WHITE RIGHT-POINTING TRIANGLE
      ["Dt"] = 0x25bc, -- BLACK DOWN-POINTING TRIANGLE
      ["dT"] = 0x25bd, -- WHITE DOWN-POINTING TRIANGLE
      ["PL"] = 0x25c0, -- BLACK LEFT-POINTING TRIANGLE
      ["Tl"] = 0x25c1, -- WHITE LEFT-POINTING TRIANGLE
      ["Db"] = 0x25c6, -- BLACK DIAMOND
      ["Dw"] = 0x25c7, -- WHITE DIAMOND
      ["LZ"] = 0x25ca, -- LOZENGE
      ["0m"] = 0x25cb, -- WHITE CIRCLE
      ["0o"] = 0x25ce, -- BULLSEYE
      ["0M"] = 0x25cf, -- BLACK CIRCLE
      ["0L"] = 0x25d0, -- CIRCLE WITH LEFT HALF BLACK
      ["0R"] = 0x25d1, -- CIRCLE WITH RIGHT HALF BLACK
      ["Sn"] = 0x25d8, -- INVERSE BULLET
      ["Ic"] = 0x25d9, -- INVERSE WHITE CIRCLE
      ["Fd"] = 0x25e2, -- BLACK LOWER RIGHT TRIANGLE
      ["Bd"] = 0x25e3, -- BLACK LOWER LEFT TRIANGLE
      ["*2"] = 0x2605, -- BLACK STAR
      ["*1"] = 0x2606, -- WHITE STAR
     ["TEL"] = 0x260e, -- BLACK TELEPHONE
     ["tel"] = 0x260f, -- WHITE TELEPHONE
      ["<H"] = 0x261c, -- WHITE LEFT POINTING INDEX
      [">H"] = 0x261e, -- WHITE RIGHT POINTING INDEX
      ["0u"] = 0x263a, -- WHITE SMILING FACE
      ["0U"] = 0x263b, -- BLACK SMILING FACE
      ["SU"] = 0x263c, -- WHITE SUN WITH RAYS
      ["Fm"] = 0x2640, -- FEMALE SIGN
      ["Ml"] = 0x2642, -- MALE SIGN
      ["cS"] = 0x2660, -- BLACK SPADE SUIT
      ["cH"] = 0x2661, -- WHITE HEART SUIT
      ["cD"] = 0x2662, -- WHITE DIAMOND SUIT
      ["cC"] = 0x2663, -- BLACK CLUB SUIT
     ["cS-"] = 0x2664, -- WHITE SPADE SUIT
     ["cH-"] = 0x2665, -- BLACK HEART SUIT
     ["cD-"] = 0x2666, -- BLACK DIAMOND SUIT
     ["cC-"] = 0x2667, -- WHITE CLUB SUIT
      ["Md"] = 0x2669, -- QUARTER NOTE
      ["M8"] = 0x266a, -- EIGHTH NOTE
      ["M2"] = 0x266b, -- BARRED EIGHTH NOTES
     ["M16"] = 0x266c, -- BARRED SIXTEENTH NOTES
      ["Mb"] = 0x266d, -- MUSIC FLAT SIGN
      ["Mx"] = 0x266e, -- MUSIC NATURAL SIGN
      ["MX"] = 0x266f, -- MUSIC SHARP SIGN
      ["OK"] = 0x2713, -- CHECK MARK
      ["XX"] = 0x2717, -- BALLOT X
      ["-X"] = 0x2720, -- MALTESE CROSS
      ["IS"] = 0x3000, -- IDEOGRAPHIC SPACE
      [",_"] = 0x3001, -- IDEOGRAPHIC COMMA
      ["._"] = 0x3002, -- IDEOGRAPHIC PERIOD
     ["+\""] = 0x3003, -- DITTO MARK
      ["+_"] = 0x3004, -- IDEOGRAPHIC DITTO MARK
      ["*_"] = 0x3005, -- IDEOGRAPHIC ITERATION MARK
      [";_"] = 0x3006, -- IDEOGRAPHIC CLOSING MARK
      ["0_"] = 0x3007, -- IDEOGRAPHIC NUMBER ZERO
      ["<+"] = 0x300a, -- LEFT DOUBLE ANGLE BRACKET
      [">+"] = 0x300b, -- RIGHT DOUBLE ANGLE BRACKET
      ["<'"] = 0x300c, -- LEFT CORNER BRACKET
      [">'"] = 0x300d, -- RIGHT CORNER BRACKET
     ["<\""] = 0x300e, -- LEFT WHITE CORNER BRACKET
     [">\""] = 0x300f, -- RIGHT WHITE CORNER BRACKET
     ["(\""] = 0x3010, -- LEFT BLACK LENTICULAR BRACKET
     [")\""] = 0x3011, -- RIGHT BLACK LENTICULAR BRACKET
      ["=T"] = 0x3012, -- POSTAL MARK
      ["=_"] = 0x3013, -- GETA MARK
      ["('"] = 0x3014, -- LEFT TORTOISE SHELL BRACKET
      [")'"] = 0x3015, -- RIGHT TORTOISE SHELL BRACKET
      ["(I"] = 0x3016, -- LEFT WHITE LENTICULAR BRACKET
      [")I"] = 0x3017, -- RIGHT WHITE LENTICULAR BRACKET
      ["-?"] = 0x301c, -- WAVE DASH
    ["=T:)"] = 0x3020, -- POSTAL MARK FACE
      ["A5"] = 0x3041, -- HIRAGANA LETTER SMALL A
      ["a5"] = 0x3042, -- HIRAGANA LETTER A
      ["I5"] = 0x3043, -- HIRAGANA LETTER SMALL I
      ["i5"] = 0x3044, -- HIRAGANA LETTER I
      ["U5"] = 0x3045, -- HIRAGANA LETTER SMALL U
      ["u5"] = 0x3046, -- HIRAGANA LETTER U
      ["E5"] = 0x3047, -- HIRAGANA LETTER SMALL E
      ["e5"] = 0x3048, -- HIRAGANA LETTER E
      ["O5"] = 0x3049, -- HIRAGANA LETTER SMALL O
      ["o5"] = 0x304a, -- HIRAGANA LETTER O
      ["ka"] = 0x304b, -- HIRAGANA LETTER KA
      ["ga"] = 0x304c, -- HIRAGANA LETTER GA
      ["ki"] = 0x304d, -- HIRAGANA LETTER KI
      ["gi"] = 0x304e, -- HIRAGANA LETTER GI
      ["ku"] = 0x304f, -- HIRAGANA LETTER KU
      ["gu"] = 0x3050, -- HIRAGANA LETTER GU
      ["ke"] = 0x3051, -- HIRAGANA LETTER KE
      ["ge"] = 0x3052, -- HIRAGANA LETTER GE
      ["ko"] = 0x3053, -- HIRAGANA LETTER KO
      ["go"] = 0x3054, -- HIRAGANA LETTER GO
      ["sa"] = 0x3055, -- HIRAGANA LETTER SA
      ["za"] = 0x3056, -- HIRAGANA LETTER ZA
      ["si"] = 0x3057, -- HIRAGANA LETTER SI
      ["zi"] = 0x3058, -- HIRAGANA LETTER ZI
      ["su"] = 0x3059, -- HIRAGANA LETTER SU
      ["zu"] = 0x305a, -- HIRAGANA LETTER ZU
      ["se"] = 0x305b, -- HIRAGANA LETTER SE
      ["ze"] = 0x305c, -- HIRAGANA LETTER ZE
      ["so"] = 0x305d, -- HIRAGANA LETTER SO
      ["zo"] = 0x305e, -- HIRAGANA LETTER ZO
      ["ta"] = 0x305f, -- HIRAGANA LETTER TA
      ["da"] = 0x3060, -- HIRAGANA LETTER DA
      ["ti"] = 0x3061, -- HIRAGANA LETTER TI
      ["di"] = 0x3062, -- HIRAGANA LETTER DI
      ["tU"] = 0x3063, -- HIRAGANA LETTER SMALL TU
      ["tu"] = 0x3064, -- HIRAGANA LETTER TU
      ["du"] = 0x3065, -- HIRAGANA LETTER DU
      ["te"] = 0x3066, -- HIRAGANA LETTER TE
      ["de"] = 0x3067, -- HIRAGANA LETTER DE
      ["to"] = 0x3068, -- HIRAGANA LETTER TO
      ["do"] = 0x3069, -- HIRAGANA LETTER DO
      ["na"] = 0x306a, -- HIRAGANA LETTER NA
      ["ni"] = 0x306b, -- HIRAGANA LETTER NI
      ["nu"] = 0x306c, -- HIRAGANA LETTER NU
      ["ne"] = 0x306d, -- HIRAGANA LETTER NE
      ["no"] = 0x306e, -- HIRAGANA LETTER NO
      ["ha"] = 0x306f, -- HIRAGANA LETTER HA
      ["ba"] = 0x3070, -- HIRAGANA LETTER BA
      ["pa"] = 0x3071, -- HIRAGANA LETTER PA
      ["hi"] = 0x3072, -- HIRAGANA LETTER HI
      ["bi"] = 0x3073, -- HIRAGANA LETTER BI
      ["pi"] = 0x3074, -- HIRAGANA LETTER PI
      ["hu"] = 0x3075, -- HIRAGANA LETTER HU
      ["bu"] = 0x3076, -- HIRAGANA LETTER BU
      ["pu"] = 0x3077, -- HIRAGANA LETTER PU
      ["he"] = 0x3078, -- HIRAGANA LETTER HE
      ["be"] = 0x3079, -- HIRAGANA LETTER BE
      ["pe"] = 0x307a, -- HIRAGANA LETTER PE
      ["ho"] = 0x307b, -- HIRAGANA LETTER HO
      ["bo"] = 0x307c, -- HIRAGANA LETTER BO
      ["po"] = 0x307d, -- HIRAGANA LETTER PO
      ["ma"] = 0x307e, -- HIRAGANA LETTER MA
      ["mi"] = 0x307f, -- HIRAGANA LETTER MI
      ["mu"] = 0x3080, -- HIRAGANA LETTER MU
      ["me"] = 0x3081, -- HIRAGANA LETTER ME
      ["mo"] = 0x3082, -- HIRAGANA LETTER MO
      ["yA"] = 0x3083, -- HIRAGANA LETTER SMALL YA
      ["ya"] = 0x3084, -- HIRAGANA LETTER YA
      ["yU"] = 0x3085, -- HIRAGANA LETTER SMALL YU
      ["yu"] = 0x3086, -- HIRAGANA LETTER YU
      ["yO"] = 0x3087, -- HIRAGANA LETTER SMALL YO
      ["yo"] = 0x3088, -- HIRAGANA LETTER YO
      ["ra"] = 0x3089, -- HIRAGANA LETTER RA
      ["ri"] = 0x308a, -- HIRAGANA LETTER RI
      ["ru"] = 0x308b, -- HIRAGANA LETTER RU
      ["re"] = 0x308c, -- HIRAGANA LETTER RE
      ["ro"] = 0x308d, -- HIRAGANA LETTER RO
      ["wA"] = 0x308e, -- HIRAGANA LETTER SMALL WA
      ["wa"] = 0x308f, -- HIRAGANA LETTER WA
      ["wi"] = 0x3090, -- HIRAGANA LETTER WI
      ["we"] = 0x3091, -- HIRAGANA LETTER WE
      ["wo"] = 0x3092, -- HIRAGANA LETTER WO
      ["n5"] = 0x3093, -- HIRAGANA LETTER N
      ["vu"] = 0x3094, -- HIRAGANA LETTER VU
     ["\"5"] = 0x309b, -- KATAKANA-HIRAGANA VOICED SOUND MARK
      ["05"] = 0x309c, -- KATAKANA-HIRAGANA SEMI-VOICED SOUND MARK
      ["*5"] = 0x309d, -- HIRAGANA ITERATION MARK
      ["+5"] = 0x309e, -- HIRAGANA VOICED ITERATION MARK
      ["a6"] = 0x30a1, -- KATAKANA LETTER SMALL A
      ["A6"] = 0x30a2, -- KATAKANA LETTER A
      ["i6"] = 0x30a3, -- KATAKANA LETTER SMALL I
      ["I6"] = 0x30a4, -- KATAKANA LETTER I
      ["u6"] = 0x30a5, -- KATAKANA LETTER SMALL U
      ["U6"] = 0x30a6, -- KATAKANA LETTER U
      ["e6"] = 0x30a7, -- KATAKANA LETTER SMALL E
      ["E6"] = 0x30a8, -- KATAKANA LETTER E
      ["o6"] = 0x30a9, -- KATAKANA LETTER SMALL O
      ["O6"] = 0x30aa, -- KATAKANA LETTER O
      ["Ka"] = 0x30ab, -- KATAKANA LETTER KA
      ["Ga"] = 0x30ac, -- KATAKANA LETTER GA
      ["Ki"] = 0x30ad, -- KATAKANA LETTER KI
      ["Gi"] = 0x30ae, -- KATAKANA LETTER GI
      ["Ku"] = 0x30af, -- KATAKANA LETTER KU
      ["Gu"] = 0x30b0, -- KATAKANA LETTER GU
      ["Ke"] = 0x30b1, -- KATAKANA LETTER KE
      ["Ge"] = 0x30b2, -- KATAKANA LETTER GE
      ["Ko"] = 0x30b3, -- KATAKANA LETTER KO
      ["Go"] = 0x30b4, -- KATAKANA LETTER GO
      ["Sa"] = 0x30b5, -- KATAKANA LETTER SA
      ["Za"] = 0x30b6, -- KATAKANA LETTER ZA
      ["Si"] = 0x30b7, -- KATAKANA LETTER SI
      ["Zi"] = 0x30b8, -- KATAKANA LETTER ZI
      ["Su"] = 0x30b9, -- KATAKANA LETTER SU
      ["Zu"] = 0x30ba, -- KATAKANA LETTER ZU
      ["Se"] = 0x30bb, -- KATAKANA LETTER SE
      ["Ze"] = 0x30bc, -- KATAKANA LETTER ZE
      ["So"] = 0x30bd, -- KATAKANA LETTER SO
      ["Zo"] = 0x30be, -- KATAKANA LETTER ZO
      ["Ta"] = 0x30bf, -- KATAKANA LETTER TA
      ["Da"] = 0x30c0, -- KATAKANA LETTER DA
      ["Ti"] = 0x30c1, -- KATAKANA LETTER TI
      ["Di"] = 0x30c2, -- KATAKANA LETTER DI
      ["TU"] = 0x30c3, -- KATAKANA LETTER SMALL TU
      ["Tu"] = 0x30c4, -- KATAKANA LETTER TU
      ["Du"] = 0x30c5, -- KATAKANA LETTER DU
      ["Te"] = 0x30c6, -- KATAKANA LETTER TE
      ["De"] = 0x30c7, -- KATAKANA LETTER DE
      ["To"] = 0x30c8, -- KATAKANA LETTER TO
      ["Do"] = 0x30c9, -- KATAKANA LETTER DO
      ["Na"] = 0x30ca, -- KATAKANA LETTER NA
      ["Ni"] = 0x30cb, -- KATAKANA LETTER NI
      ["Nu"] = 0x30cc, -- KATAKANA LETTER NU
      ["Ne"] = 0x30cd, -- KATAKANA LETTER NE
      ["No"] = 0x30ce, -- KATAKANA LETTER NO
      ["Ha"] = 0x30cf, -- KATAKANA LETTER HA
      ["Ba"] = 0x30d0, -- KATAKANA LETTER BA
      ["Pa"] = 0x30d1, -- KATAKANA LETTER PA
      ["Hi"] = 0x30d2, -- KATAKANA LETTER HI
      ["Bi"] = 0x30d3, -- KATAKANA LETTER BI
      ["Pi"] = 0x30d4, -- KATAKANA LETTER PI
      ["Hu"] = 0x30d5, -- KATAKANA LETTER HU
      ["Bu"] = 0x30d6, -- KATAKANA LETTER BU
      ["Pu"] = 0x30d7, -- KATAKANA LETTER PU
      ["He"] = 0x30d8, -- KATAKANA LETTER HE
      ["Be"] = 0x30d9, -- KATAKANA LETTER BE
      ["Pe"] = 0x30da, -- KATAKANA LETTER PE
      ["Ho"] = 0x30db, -- KATAKANA LETTER HO
      ["Bo"] = 0x30dc, -- KATAKANA LETTER BO
      ["Po"] = 0x30dd, -- KATAKANA LETTER PO
      ["Ma"] = 0x30de, -- KATAKANA LETTER MA
      ["Mi"] = 0x30df, -- KATAKANA LETTER MI
      ["Mu"] = 0x30e0, -- KATAKANA LETTER MU
      ["Me"] = 0x30e1, -- KATAKANA LETTER ME
      ["Mo"] = 0x30e2, -- KATAKANA LETTER MO
      ["YA"] = 0x30e3, -- KATAKANA LETTER SMALL YA
      ["Ya"] = 0x30e4, -- KATAKANA LETTER YA
      ["YU"] = 0x30e5, -- KATAKANA LETTER SMALL YU
      ["Yu"] = 0x30e6, -- KATAKANA LETTER YU
      ["YO"] = 0x30e7, -- KATAKANA LETTER SMALL YO
      ["Yo"] = 0x30e8, -- KATAKANA LETTER YO
      ["Ra"] = 0x30e9, -- KATAKANA LETTER RA
      ["Ri"] = 0x30ea, -- KATAKANA LETTER RI
      ["Ru"] = 0x30eb, -- KATAKANA LETTER RU
      ["Re"] = 0x30ec, -- KATAKANA LETTER RE
      ["Ro"] = 0x30ed, -- KATAKANA LETTER RO
      ["WA"] = 0x30ee, -- KATAKANA LETTER SMALL WA
      ["Wa"] = 0x30ef, -- KATAKANA LETTER WA
      ["Wi"] = 0x30f0, -- KATAKANA LETTER WI
      ["We"] = 0x30f1, -- KATAKANA LETTER WE
      ["Wo"] = 0x30f2, -- KATAKANA LETTER WO
      ["N6"] = 0x30f3, -- KATAKANA LETTER N
      ["Vu"] = 0x30f4, -- KATAKANA LETTER VU
      ["KA"] = 0x30f5, -- KATAKANA LETTER SMALL KA
      ["KE"] = 0x30f6, -- KATAKANA LETTER SMALL KE
      ["Va"] = 0x30f7, -- KATAKANA LETTER VA
      ["Vi"] = 0x30f8, -- KATAKANA LETTER VI
      ["Ve"] = 0x30f9, -- KATAKANA LETTER VE
      ["Vo"] = 0x30fa, -- KATAKANA LETTER VO
      [".6"] = 0x30fb, -- KATAKANA MIDDLE DOT
      ["-6"] = 0x30fc, -- KATAKANA-HIRAGANA PROLONGED SOUND MARK
      ["*6"] = 0x30fd, -- KATAKANA ITERATION MARK
      ["+6"] = 0x30fe, -- KATAKANA VOICED ITERATION MARK
      ["b4"] = 0x3105, -- BOPOMOFO LETTER B
      ["p4"] = 0x3106, -- BOPOMOFO LETTER P
      ["m4"] = 0x3107, -- BOPOMOFO LETTER M
      ["f4"] = 0x3108, -- BOPOMOFO LETTER F
      ["d4"] = 0x3109, -- BOPOMOFO LETTER D
      ["t4"] = 0x310a, -- BOPOMOFO LETTER T
      ["n4"] = 0x310b, -- BOPOMOFO LETTER N
      ["l4"] = 0x310c, -- BOPOMOFO LETTER L
      ["g4"] = 0x310d, -- BOPOMOFO LETTER G
      ["k4"] = 0x310e, -- BOPOMOFO LETTER K
      ["h4"] = 0x310f, -- BOPOMOFO LETTER H
      ["j4"] = 0x3110, -- BOPOMOFO LETTER J
      ["q4"] = 0x3111, -- BOPOMOFO LETTER Q
      ["x4"] = 0x3112, -- BOPOMOFO LETTER X
      ["zh"] = 0x3113, -- BOPOMOFO LETTER ZH
      ["ch"] = 0x3114, -- BOPOMOFO LETTER CH
      ["sh"] = 0x3115, -- BOPOMOFO LETTER SH
      ["r4"] = 0x3116, -- BOPOMOFO LETTER R
      ["z4"] = 0x3117, -- BOPOMOFO LETTER Z
      ["c4"] = 0x3118, -- BOPOMOFO LETTER C
      ["s4"] = 0x3119, -- BOPOMOFO LETTER S
      ["a4"] = 0x311a, -- BOPOMOFO LETTER A
      ["o4"] = 0x311b, -- BOPOMOFO LETTER O
      ["e4"] = 0x311c, -- BOPOMOFO LETTER E
     ["eh4"] = 0x311d, -- BOPOMOFO LETTER EH
      ["ai"] = 0x311e, -- BOPOMOFO LETTER AI
      ["ei"] = 0x311f, -- BOPOMOFO LETTER EI
      ["au"] = 0x3120, -- BOPOMOFO LETTER AU
      ["ou"] = 0x3121, -- BOPOMOFO LETTER OU
      ["an"] = 0x3122, -- BOPOMOFO LETTER AN
      ["en"] = 0x3123, -- BOPOMOFO LETTER EN
      ["aN"] = 0x3124, -- BOPOMOFO LETTER ANG
      ["eN"] = 0x3125, -- BOPOMOFO LETTER ENG
      ["er"] = 0x3126, -- BOPOMOFO LETTER ER
      ["i4"] = 0x3127, -- BOPOMOFO LETTER I
      ["u4"] = 0x3128, -- BOPOMOFO LETTER U
      ["iu"] = 0x3129, -- BOPOMOFO LETTER IU
      ["v4"] = 0x312a, -- BOPOMOFO LETTER V
      ["nG"] = 0x312b, -- BOPOMOFO LETTER NG
      ["gn"] = 0x312c, -- BOPOMOFO LETTER GN
    ["(JU)"] = 0x321c, -- PARENTHESIZED HANGUL JU
      ["1c"] = 0x3220, -- PARENTHESIZED IDEOGRAPH ONE
      ["2c"] = 0x3221, -- PARENTHESIZED IDEOGRAPH TWO
      ["3c"] = 0x3222, -- PARENTHESIZED IDEOGRAPH THREE
      ["4c"] = 0x3223, -- PARENTHESIZED IDEOGRAPH FOUR
      ["5c"] = 0x3224, -- PARENTHESIZED IDEOGRAPH FIVE
      ["6c"] = 0x3225, -- PARENTHESIZED IDEOGRAPH SIX
      ["7c"] = 0x3226, -- PARENTHESIZED IDEOGRAPH SEVEN
      ["8c"] = 0x3227, -- PARENTHESIZED IDEOGRAPH EIGHT
      ["9c"] = 0x3228, -- PARENTHESIZED IDEOGRAPH NINE
     ["10c"] = 0x3229, -- PARENTHESIZED IDEOGRAPH TEN
     ["KSC"] = 0x327f, -- KOREAN STANDARD SYMBOL
      ["ff"] = 0xfb00, -- LATIN SMALL LIGATURE FF
      ["fi"] = 0xfb01, -- LATIN SMALL LIGATURE FI
      ["fl"] = 0xfb02, -- LATIN SMALL LIGATURE FL
     ["ffi"] = 0xfb03, -- LATIN SMALL LIGATURE FFI
     ["ffl"] = 0xfb04, -- LATIN SMALL LIGATURE FFL
      ["ft"] = 0xfb05, -- LATIN SMALL LIGATURE FT
      ["st"] = 0xfb06, -- LATIN SMALL LIGATURE ST
     ["3+;"] = 0xfe7d, -- ARABIC SHADDA MEDIAL FORM
     ["aM."] = 0xfe82, -- ARABIC LETTER ALEF WITH MADDA ABOVE FINAL FORM
     ["aH."] = 0xfe84, -- ARABIC LETTER ALEF WITH HAMZA ABOVE FINAL FORM
     ["a+-"] = 0xfe8d, -- ARABIC LETTER ALEF ISOLATED FORM
     ["a+."] = 0xfe8e, -- ARABIC LETTER ALEF FINAL FORM
     ["b+-"] = 0xfe8f, -- ARABIC LETTER BEH ISOLATED FORM
     ["b+,"] = 0xfe90, -- ARABIC LETTER BEH INITIAL FORM
     ["b+;"] = 0xfe91, -- ARABIC LETTER BEH MEDIAL FORM
     ["b+."] = 0xfe92, -- ARABIC LETTER BEH FINAL FORM
     ["tm-"] = 0xfe93, -- ARABIC LETTER TEH MARBUTA ISOLATED FORM
     ["tm."] = 0xfe94, -- ARABIC LETTER TEH MARBUTA FINAL FORM
     ["t+-"] = 0xfe95, -- ARABIC LETTER TEH ISOLATED FORM
     ["t+,"] = 0xfe96, -- ARABIC LETTER TEH INITIAL FORM
     ["t+;"] = 0xfe97, -- ARABIC LETTER TEH MEDIAL FORM
     ["t+."] = 0xfe98, -- ARABIC LETTER TEH FINAL FORM
     ["tk-"] = 0xfe99, -- ARABIC LETTER THEH ISOLATED FORM
     ["tk,"] = 0xfe9a, -- ARABIC LETTER THEH INITIAL FORM
     ["tk;"] = 0xfe9b, -- ARABIC LETTER THEH MEDIAL FORM
     ["tk."] = 0xfe9c, -- ARABIC LETTER THEH FINAL FORM
     ["g+-"] = 0xfe9d, -- ARABIC LETTER JEEM ISOLATED FORM
     ["g+,"] = 0xfe9e, -- ARABIC LETTER JEEM INITIAL FORM
     ["g+;"] = 0xfe9f, -- ARABIC LETTER JEEM MEDIAL FORM
     ["g+."] = 0xfea0, -- ARABIC LETTER JEEM FINAL FORM
     ["hk-"] = 0xfea1, -- ARABIC LETTER HAH ISOLATED FORM
     ["hk,"] = 0xfea2, -- ARABIC LETTER HAH INITIAL FORM
     ["hk;"] = 0xfea3, -- ARABIC LETTER HAH MEDIAL FORM
     ["hk."] = 0xfea4, -- ARABIC LETTER HAH FINAL FORM
     ["x+-"] = 0xfea5, -- ARABIC LETTER KHAH ISOLATED FORM
     ["x+,"] = 0xfea6, -- ARABIC LETTER KHAH INITIAL FORM
     ["x+;"] = 0xfea7, -- ARABIC LETTER KHAH MEDIAL FORM
     ["x+."] = 0xfea8, -- ARABIC LETTER KHAH FINAL FORM
     ["d+-"] = 0xfea9, -- ARABIC LETTER DAL ISOLATED FORM
     ["d+."] = 0xfeaa, -- ARABIC LETTER DAL FINAL FORM
     ["dk-"] = 0xfeab, -- ARABIC LETTER THAL ISOLATED FORM
     ["dk."] = 0xfeac, -- ARABIC LETTER THAL FINAL FORM
     ["r+-"] = 0xfead, -- ARABIC LETTER REH ISOLATED FORM
     ["r+."] = 0xfeae, -- ARABIC LETTER REH FINAL FORM
     ["z+-"] = 0xfeaf, -- ARABIC LETTER ZAIN ISOLATED FORM
     ["z+."] = 0xfeb0, -- ARABIC LETTER ZAIN FINAL FORM
     ["s+-"] = 0xfeb1, -- ARABIC LETTER SEEN ISOLATED FORM
     ["s+,"] = 0xfeb2, -- ARABIC LETTER SEEN INITIAL FORM
     ["s+;"] = 0xfeb3, -- ARABIC LETTER SEEN MEDIAL FORM
     ["s+."] = 0xfeb4, -- ARABIC LETTER SEEN FINAL FORM
     ["sn-"] = 0xfeb5, -- ARABIC LETTER SHEEN ISOLATED FORM
     ["sn,"] = 0xfeb6, -- ARABIC LETTER SHEEN INITIAL FORM
     ["sn;"] = 0xfeb7, -- ARABIC LETTER SHEEN MEDIAL FORM
     ["sn."] = 0xfeb8, -- ARABIC LETTER SHEEN FINAL FORM
     ["c+-"] = 0xfeb9, -- ARABIC LETTER SAD ISOLATED FORM
     ["c+,"] = 0xfeba, -- ARABIC LETTER SAD INITIAL FORM
     ["c+;"] = 0xfebb, -- ARABIC LETTER SAD MEDIAL FORM
     ["c+."] = 0xfebc, -- ARABIC LETTER SAD FINAL FORM
     ["dd-"] = 0xfebd, -- ARABIC LETTER DAD ISOLATED FORM
     ["dd,"] = 0xfebe, -- ARABIC LETTER DAD INITIAL FORM
     ["dd;"] = 0xfebf, -- ARABIC LETTER DAD MEDIAL FORM
     ["dd."] = 0xfec0, -- ARABIC LETTER DAD FINAL FORM
     ["tj-"] = 0xfec1, -- ARABIC LETTER TAH ISOLATED FORM
     ["tj,"] = 0xfec2, -- ARABIC LETTER TAH INITIAL FORM
     ["tj;"] = 0xfec3, -- ARABIC LETTER TAH MEDIAL FORM
     ["tj."] = 0xfec4, -- ARABIC LETTER TAH FINAL FORM
     ["zH-"] = 0xfec5, -- ARABIC LETTER ZAH ISOLATED FORM
     ["zH,"] = 0xfec6, -- ARABIC LETTER ZAH INITIAL FORM
     ["zH;"] = 0xfec7, -- ARABIC LETTER ZAH MEDIAL FORM
     ["zH."] = 0xfec8, -- ARABIC LETTER ZAH FINAL FORM
     ["e+-"] = 0xfec9, -- ARABIC LETTER AIN ISOLATED FORM
     ["e+,"] = 0xfeca, -- ARABIC LETTER AIN INITIAL FORM
     ["e+;"] = 0xfecb, -- ARABIC LETTER AIN MEDIAL FORM
     ["e+."] = 0xfecc, -- ARABIC LETTER AIN FINAL FORM
     ["i+-"] = 0xfecd, -- ARABIC LETTER GHAIN ISOLATED FORM
     ["i+,"] = 0xfece, -- ARABIC LETTER GHAIN INITIAL FORM
     ["i+;"] = 0xfecf, -- ARABIC LETTER GHAIN MEDIAL FORM
     ["i+."] = 0xfed0, -- ARABIC LETTER GHAIN FINAL FORM
     ["f+-"] = 0xfed1, -- ARABIC LETTER FEH ISOLATED FORM
     ["f+,"] = 0xfed2, -- ARABIC LETTER FEH INITIAL FORM
     ["f+;"] = 0xfed3, -- ARABIC LETTER FEH MEDIAL FORM
     ["f+."] = 0xfed4, -- ARABIC LETTER FEH FINAL FORM
     ["q+-"] = 0xfed5, -- ARABIC LETTER QAF ISOLATED FORM
     ["q+,"] = 0xfed6, -- ARABIC LETTER QAF INITIAL FORM
     ["q+;"] = 0xfed7, -- ARABIC LETTER QAF MEDIAL FORM
     ["q+."] = 0xfed8, -- ARABIC LETTER QAF FINAL FORM
     ["k+-"] = 0xfed9, -- ARABIC LETTER KAF ISOLATED FORM
     ["k+,"] = 0xfeda, -- ARABIC LETTER KAF INITIAL FORM
     ["k+;"] = 0xfedb, -- ARABIC LETTER KAF MEDIAL FORM
     ["k+."] = 0xfedc, -- ARABIC LETTER KAF FINAL FORM
     ["l+-"] = 0xfedd, -- ARABIC LETTER LAM ISOLATED FORM
     ["l+,"] = 0xfede, -- ARABIC LETTER LAM INITIAL FORM
     ["l+;"] = 0xfedf, -- ARABIC LETTER LAM MEDIAL FORM
     ["l+."] = 0xfee0, -- ARABIC LETTER LAM FINAL FORM
     ["m+-"] = 0xfee1, -- ARABIC LETTER MEEM ISOLATED FORM
     ["m+,"] = 0xfee2, -- ARABIC LETTER MEEM INITIAL FORM
     ["m+;"] = 0xfee3, -- ARABIC LETTER MEEM MEDIAL FORM
     ["m+."] = 0xfee4, -- ARABIC LETTER MEEM FINAL FORM
     ["n+-"] = 0xfee5, -- ARABIC LETTER NOON ISOLATED FORM
     ["n+,"] = 0xfee6, -- ARABIC LETTER NOON INITIAL FORM
     ["n+;"] = 0xfee7, -- ARABIC LETTER NOON MEDIAL FORM
     ["n+."] = 0xfee8, -- ARABIC LETTER NOON FINAL FORM
     ["h+-"] = 0xfee9, -- ARABIC LETTER HEH ISOLATED FORM
     ["h+,"] = 0xfeea, -- ARABIC LETTER HEH INITIAL FORM
     ["h+;"] = 0xfeeb, -- ARABIC LETTER HEH MEDIAL FORM
     ["h+."] = 0xfeec, -- ARABIC LETTER HEH FINAL FORM
     ["w+-"] = 0xfeed, -- ARABIC LETTER WAW ISOLATED FORM
     ["w+."] = 0xfeee, -- ARABIC LETTER WAW FINAL FORM
     ["j+-"] = 0xfeef, -- ARABIC LETTER ALEF MAKSURA ISOLATED FORM
     ["j+."] = 0xfef0, -- ARABIC LETTER ALEF MAKSURA FINAL FORM
     ["y+-"] = 0xfef1, -- ARABIC LETTER YEH ISOLATED FORM
     ["y+,"] = 0xfef2, -- ARABIC LETTER YEH INITIAL FORM
     ["y+;"] = 0xfef3, -- ARABIC LETTER YEH MEDIAL FORM
     ["y+."] = 0xfef4, -- ARABIC LETTER YEH FINAL FORM
     ["lM-"] = 0xfef5, -- ARABIC LIGATURE LAM WITH ALEF WITH MADDA ABOVE ISOLATED FORM
     ["lM."] = 0xfef6, -- ARABIC LIGATURE LAM WITH ALEF WITH MADDA ABOVE FINAL FORM
     ["lH-"] = 0xfef7, -- ARABIC LIGATURE LAM WITH ALEF WITH HAMZA ABOVE ISOLATED FORM
     ["lH."] = 0xfef8, -- ARABIC LIGATURE LAM WITH ALEF WITH HAMZA ABOVE FINAL FORM
     ["lh-"] = 0xfef9, -- ARABIC LIGATURE LAM WITH ALEF WITH HAMZA BELOW ISOLATED FORM
     ["lh."] = 0xfefa, -- ARABIC LIGATURE LAM WITH ALEF WITH HAMZA BELOW FINAL FORM
     ["la-"] = 0xfefb, -- ARABIC LIGATURE LAM WITH ALEF ISOLATED FORM
     ["la."] = 0xfefc, -- ARABIC LIGATURE LAM WITH ALEF FINAL FORM
     ["\"3"] = 0xe004, -- NON-SPACING UMLAUT (ISO-IR-38 201) (character part)
     ["\"1"] = 0xe005, -- NON-SPACING DIAERESIS WITH ACCENT (ISO-IR-70 192) (character part)
     ["\"!"] = 0xe006, -- NON-SPACING GRAVE ACCENT (ISO-IR-103 193) (character part)
     ["\"'"] = 0xe007, -- NON-SPACING ACUTE ACCENT (ISO-IR-103 194) (character part)
     ["\">"] = 0xe008, -- NON-SPACING CIRCUMFLEX ACCENT (ISO-IR-103 195) (character part)
     ["\"?"] = 0xe009, -- NON-SPACING TILDE (ISO-IR-103 196) (character part)
     ["\"-"] = 0xe00a, -- NON-SPACING MACRON (ISO-IR-103 197) (character part)
     ["\"("] = 0xe00b, -- NON-SPACING BREVE (ISO-IR-103 198) (character part)
     ["\"."] = 0xe00c, -- NON-SPACING DOT ABOVE (ISO-IR-103 199) (character part)
     ["\":"] = 0xe00d, -- NON-SPACING DIAERESIS (ISO-IR-103 200) (character part)
     ["\"0"] = 0xe00e, -- NON-SPACING RING ABOVE (ISO-IR-103 202) (character part)
    ["\"\""] = 0xe00f, -- NON-SPACING DOUBLE ACCUTE (ISO-IR-103 204) (character part)
     ["\"<"] = 0xe010, -- NON-SPACING CARON (ISO-IR-103 206) (character part)
     ["\","] = 0xe011, -- NON-SPACING CEDILLA (ISO-IR-103 203) (character part)
     ["\";"] = 0xe012, -- NON-SPACING OGONEK (ISO-IR-103 206) (character part)
     ["\"_"] = 0xe013, -- NON-SPACING LOW LINE (ISO-IR-103 204) (character part)
     ["\"="] = 0xe014, -- NON-SPACING DOUBLE LOW LINE (ISO-IR-38 217) (character part)
     ["\"/"] = 0xe015, -- NON-SPACING LONG SOLIDUS (ISO-IR-128 201) (character part)
     ["\"i"] = 0xe016, -- GREEK NON-SPACING IOTA BELOW (ISO-IR-55 39) (character part)
     ["\"d"] = 0xe017, -- GREEK NON-SPACING DASIA PNEUMATA (ISO-IR-55 38) (character part)
     ["\"p"] = 0xe018, -- GREEK NON-SPACING PSILI PNEUMATA (ISO-IR-55 37) (character part)
      [";;"] = 0xe019, -- GREEK DASIA PNEUMATA (ISO-IR-18 92)
      [",,"] = 0xe01a, -- GREEK PSILI PNEUMATA (ISO-IR-18 124)
      ["b3"] = 0xe01b, -- GREEK SMALL LETTER MIDDLE BETA (ISO-IR-18 99)
      ["Ci"] = 0xe01c, -- CIRCLE (ISO-IR-83 0294)
      ["f("] = 0xe01d, -- FUNCTION SIGN (ISO-IR-143 221)
      ["ed"] = 0xe01e, -- LATIN SMALL LETTER EZH (ISO-IR-158 142)
      ["am"] = 0xe01f, -- ANTE MERIDIAM SIGN (ISO-IR-149 0267)
      ["pm"] = 0xe020, -- POST MERIDIAM SIGN (ISO-IR-149 0268)
     ["Tel"] = 0xe021, -- TEL COMPATIBILITY SIGN (ISO-IR-149 0269)
     ["a+:"] = 0xe022, -- ARABIC LETTER ALEF FINAL FORM COMPATIBILITY (IBM868 144)
      ["Fl"] = 0xe023, -- DUTCH GUILDER SIGN (IBM437 159)
      ["GF"] = 0xe024, -- GAMMA FUNCTION SIGN (ISO-10646-1DIS 032/032/037/122)
      [">V"] = 0xe025, -- RIGHTWARDS VECTOR ABOVE (ISO-10646-1DIS 032/032/038/046)
      ["!*"] = 0xe026, -- GREEK VARIA (ISO-10646-1DIS 032/032/042/164)
      ["?*"] = 0xe027, -- GREEK PERISPOMENI (ISO-10646-1DIS 032/032/042/165)
      ["J<"] = 0xe028 -- LATIN CAPITAL LETTER J WITH CARON (lowercase: 000/000/001/240)
}

setup()
