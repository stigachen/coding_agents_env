# Merge this repo's [ui.status_line] type and command into a TOML file.
# Recognizes spaced or quoted headers, quoted keys, inline tables, dotted keys,
# and multiline strings. A root inline table ui = { ... } is rewritten in place;
# appending [ui.status_line] after it is illegal. Strings are opaque. On input
# this script cannot merge safely it exits 2 and prints nothing, so the caller
# can keep the original.
# STATUSLINE_TOML is the command already escaped for a TOML basic string.
# POSIX awk (macOS nawk and Git Bash). LC_ALL=C keeps this byte-oriented.

BEGIN {
  cmd = ENVIRON["STATUSLINE_TOML"]
  marker = "/grok/statusline/statusline.sh"
  SL = "ui\034status_line"
  if (cmd == "") {
    print "Grok config.toml 无法安全合并 [ui.status_line]：缺少命令。原文件未修改" > "/dev/stderr"
    failed = 1
    exit 2
  }
  n = 0
  use_cr = 0
  ours = 0
  saw_type = 0
  saw_command = 0
  sl_defined = ""
  sl_existed = 0
  header_insert_line = 0
  dotted_prefix = ""
  dotted_anchor = 0
  np = 0
  ni = 0
  strict_inline = 0
  root_ui_inline = 0
  root_ui_dotted = 0
  ui_header = 0
}

function fail(msg) {
  printf "Grok config.toml 无法安全合并 [ui.status_line]：第 %d 行，%s。原文件未修改\n", (L < 1 ? 1 : L), msg > "/dev/stderr"
  failed = 1
  exit 2
}

function ch() {
  if (L > n) return ""
  if (C > length(text[L])) return "\n"
  return substr(text[L], C, 1)
}

function adv() {
  if (L > n) return
  if (C > length(text[L])) { L++; C = 1 }
  else C++
}

function slice(l1, c1, l2, c2,    s, i) {
  if (l1 == l2) return substr(text[l1], c1, c2 - c1)
  s = substr(text[l1], c1)
  for (i = l1 + 1; i < l2; i++) s = s "\n" text[i]
  if (l2 <= n) s = s "\n" substr(text[l2], 1, c2 - 1)
  return s
}

function skip_hs() {
  while (ch() == " " || ch() == "\t") adv()
}

function skip_comment(    c) {
  while (1) {
    c = ch()
    if (c == "" || c == "\n") return
    adv()
  }
}

function skip_gap(    c) {
  while (1) {
    c = ch()
    if (c == "") return
    if (c == " " || c == "\t" || c == "\n") { adv(); continue }
    if (c == "#") {
      if (strict_inline) fail("inline table 含有注释，为避免丢掉注释已停止")
      skip_comment()
      continue
    }
    return
  }
}

function skip_top(    c) {
  while (1) {
    c = ch()
    if (c == "") return
    if (c == " " || c == "\t" || c == "\n") { adv(); continue }
    if (c == "#") { skip_comment(); continue }
    return
  }
}

function hexval(h,    i, d, v) {
  v = 0
  for (i = 1; i <= length(h); i++) {
    d = index("0123456789abcdef", tolower(substr(h, i, 1)))
    if (d == 0) fail("非法十六进制转义")
    v = v * 16 + d - 1
  }
  return v
}

function read_hex(count,    i, h, c) {
  h = ""
  for (i = 1; i <= count; i++) {
    c = ch()
    if (c !~ /[0-9A-Fa-f]/) fail("非法十六进制转义")
    h = h c
    adv()
  }
  return hexval(h)
}

function simple_escape(e) {
  if (e == "b") return "\b"
  if (e == "t") return "\t"
  if (e == "n") return "\n"
  if (e == "f") return "\f"
  if (e == "r") return "\r"
  if (e == "\"") return "\""
  if (e == "\\") return "\\"
  fail("无法识别的转义")
}

function utf8_cp(cp) {
  if (cp < 128) return sprintf("%c", cp)
  # Non-ASCII key text only needs to stay distinct from ui/status_line.
  return "\001"
}

# want=1 decodes a key. want=0 only finds the closing delimiter.
function parse_string_contents(q, ml, want,    out, c, e) {
  out = ""
  while (1) {
    c = ch()
    if (c == "") fail("未闭合字符串")
    if (!ml && c == "\n") fail("字符串里有裸换行")
    if (q == "\"" && c == "\\") {
      adv()
      e = ch()
      if (e == "") fail("未闭合转义")
      adv()
      if (want && (e == "u" || e == "U")) out = out utf8_cp(read_hex(e == "U" ? 8 : 4))
      else if (want) out = out simple_escape(e)
      continue
    }
    if (c == q) {
      if (ml) {
        if (substr(text[L], C, 3) == q q q) {
          adv(); adv(); adv()
          return out
        }
        if (want) out = out c
        adv()
        continue
      }
      adv()
      return out
    }
    if (want) out = out c
    adv()
  }
}

function parse_string_value(    q) {
  q = ch()
  if (q != "\"" && q != "'") fail("缺少字符串")
  if (substr(text[L], C, 3) == q q q) {
    adv(); adv(); adv()
    parse_string_contents(q, 1, 0)
  } else {
    adv()
    parse_string_contents(q, 0, 0)
  }
}

function parse_seg(    s, c) {
  c = ch()
  if (c == "\"") {
    if (substr(text[L], C, 3) == "\"\"\"") fail("键不能使用多行字符串")
    adv()
    return parse_string_contents("\"", 0, 1)
  }
  if (c == "'") {
    if (substr(text[L], C, 3) == "'''") fail("键不能使用多行字符串")
    adv()
    return parse_string_contents("'", 0, 1)
  }
  if (c !~ /[A-Za-z0-9_-]/) fail("无法识别的键")
  s = ""
  while (ch() ~ /[A-Za-z0-9_-]/) {
    s = s ch()
    adv()
  }
  return s
}

function strip_key_prefix(pre,    t) {
  t = pre
  sub(/[ \t]+$/, "", t)
  sub(/\.$/, "", t)
  sub(/[ \t]+$/, "", t)
  return t
}

function parse_key(allow_nl,    canon, seg, segL, segC, segEndL, segEndC, ksL, ksC) {
  # Headers and inline tables may have space before the first segment.
  # Key text starts after that space; leading indent stays with the caller.
  if (allow_nl) skip_gap()
  else skip_hs()
  NSEG = 0
  canon = ""
  ksL = L
  ksC = C
  while (1) {
    NSEG++
    if (NSEG > 1) {
      if (allow_nl) skip_gap()
      else skip_hs()
    }
    segL = L
    segC = C
    seg = parse_seg()
    segEndL = L
    segEndC = C
    SEG_CANON[NSEG] = seg
    SEG_RAW[NSEG] = slice(segL, segC, segEndL, segEndC)
    if (canon != "") canon = canon "\034"
    canon = canon seg
    if (allow_nl) skip_gap()
    else skip_hs()
    if (ch() == ".") { adv(); continue }
    break
  }
  key_canon = canon
  key_raw = slice(ksL, ksC, segEndL, segEndC)
  if (NSEG == 1) key_prefix_raw = ""
  else key_prefix_raw = strip_key_prefix(slice(ksL, ksC, segL, segC))
}

function parse_atom(    c) {
  c = ch()
  if (c == "" || c == "\n" || c == "#" || c == "," || c == "]" || c == "}" || c == "=")
    fail("缺少值")
  while (1) {
    c = ch()
    if (c == "" || c == " " || c == "\t" || c == "\n" || c == "#" || c == "," || c == "]" || c == "}")
      return
    adv()
  }
}

function parse_array(    c) {
  if (ch() != "[") fail("缺少数组")
  adv()
  while (1) {
    skip_gap()
    c = ch()
    if (c == "") fail("未闭合数组")
    if (c == "]") { adv(); return }
    parse_value(0)
    skip_gap()
    c = ch()
    if (c == ",") { adv(); continue }
    if (c == "]") { adv(); return }
    fail("数组语法无法识别")
  }
}

function skip_inline(record,    c) {
  while (1) {
    c = ch()
    if (c == "") return
    if (c == " " || c == "\t" || c == "\n") { adv(); continue }
    if (c == "#") {
      if (record || strict_inline) fail("inline table 含有注释，为避免丢掉注释已停止")
      skip_comment()
      continue
    }
    return
  }
}

function parse_value(capture,    sL, sC, c) {
  sL = L
  sC = C
  c = ch()
  if (c == "\"" || c == "'") { parse_string_value(); val_kind = "string" }
  else if (c == "[") { parse_array(); val_kind = "array" }
  else if (c == "{") { parse_inline(0); val_kind = "inline" }
  else { parse_atom(); val_kind = "atom" }
  if (capture) val_raw = slice(sL, sC, L, C)
}

function parse_inline(record,    sc, sr, capture) {
  if (ch() != "{") fail("缺少 inline table")
  adv()
  if (record == 1) np = 0
  else if (record == 2) ni = 0
  capture = (record == 1 || record == 2)
  while (1) {
    skip_inline(record)
    if (ch() == "") fail("未闭合 inline table")
    if (ch() == "}") { adv(); return }
    parse_key(1)
    sc = key_canon
    sr = key_raw
    skip_inline(record)
    if (ch() != "=") fail("inline table 缺少等号")
    adv()
    skip_inline(record)
    parse_value(capture)
    if (record == 1) {
      np++
      Pcanon[np] = sc
      Pkey[np] = sr
      Pval[np] = val_raw
    } else if (record == 2) {
      ni++
      Icanon[ni] = sc
      Ikey[ni] = sr
      Ival[ni] = val_raw
    }
    skip_inline(record)
    if (ch() == ",") { adv(); continue }
    if (ch() == "}") { adv(); return }
    fail("inline table 语法无法识别")
  }
}

function finish_statement() {
  skip_hs()
  if (ch() == "#") skip_comment()
  if (ch() != "" && ch() != "\n") fail("同一行出现多条语句")
}

function drop_range(a, b,    i) {
  for (i = a; i <= b; i++) if (action[i] != "replace") action[i] = "drop"
}

function schedule_replace(start_line, vL, vC, endL, endC, new_value, indent, kraw,    suffix, line) {
  suffix = ""
  if (endL >= 1 && endL <= n && endC <= length(text[endL]))
    suffix = substr(text[endL], endC)
  if (vL == start_line && endL == start_line)
    line = substr(text[start_line], 1, vC - 1) new_value suffix
  else {
    line = indent kraw " = " new_value suffix
    if (endL > start_line) drop_range(start_line + 1, endL)
  }
  replace[start_line] = line
  action[start_line] = "replace"
}

function note_command_raw(raw) {
  if (index(raw, marker) > 0 || index(raw, "coding_agents_env-statusline.cmd") > 0)
    ours = 1
}

function note_form(form) {
  if (sl_defined == "") sl_defined = form
  else if (sl_defined != form)
    fail("同一份配置里用了多种 ui.status_line 写法")
}

function set_cur(path,    i, count) {
  cur = path
  if (path == "") { cur_n = 0; return }
  count = 1
  for (i = 1; i <= length(path); i++) if (substr(path, i, 1) == "\034") count++
  cur_n = count
}

function join_path(a, b) {
  if (a == "") return b
  if (b == "") return a
  return a "\034" b
}

function inside_sl() {
  if (cur == SL) return 1
  if (length(cur) > length(SL) && substr(cur, 1, length(SL) + 1) == SL "\034") return 1
  return 0
}

function is_direct_sl(path,    rest) {
  if (index(path, SL "\034") != 1) return 0
  rest = substr(path, length(SL) + 2)
  return rest != "" && index(rest, "\034") == 0
}

# Raw dotted prefix, relative to the current table, that names ui.status_line.
function sl_rel_prefix(    need, i, s) {
  need = 2 - cur_n
  if (need < 1 || need > NSEG) fail("无法定位 status_line 键前缀")
  s = SEG_RAW[1]
  for (i = 2; i <= need; i++) s = s "." SEG_RAW[i]
  return s
}

function remember_dotted(prefix, anchor) {
  if (prefix == "") fail("无法定位 status_line 键前缀")
  if (dotted_prefix == "") dotted_prefix = prefix
  else if (dotted_prefix != prefix) fail("ui.status_line 点号键前缀不一致")
  if (anchor > dotted_anchor) dotted_anchor = anchor
}

function rebuild_inline(    i, out) {
  out = "{ type = \"command\", command = \"" cmd "\""
  for (i = 1; i <= np; i++) {
    if (Pcanon[i] == "command") note_command_raw(Pval[i])
    if (Pcanon[i] == "type" || Pcanon[i] == "command") continue
    out = out ", " Pkey[i] " = " Pval[i]
  }
  out = out " }"
  return out
}

function append_piece(out, piece) {
  if (out == "{") return out " " piece
  return out ", " piece
}

function rebuild_inner_sl(    i, out) {
  out = "{ type = \"command\", command = \"" cmd "\""
  for (i = 1; i <= ni; i++) {
    if (Icanon[i] == "command") note_command_raw(Ival[i])
    if (Icanon[i] == "type" || Icanon[i] == "command") continue
    if (index(Icanon[i], "type\034") == 1 || index(Icanon[i], "command\034") == 1)
      fail("ui.status_line 里混用了 type 或 command 的写法")
    out = out ", " Ikey[i] " = " Ival[i]
  }
  return out " }"
}

# Root `ui = { ... }` is closed, so a later [ui.status_line] header is illegal.
# Rewrite the inline table instead. A new status_line does not count as a takeover.
function parse_root_ui_value(    sc, sr) {
  if (ch() != "{") fail("缺少 inline table")
  adv()
  np = 0
  strict_inline = 1
  while (1) {
    skip_inline(1)
    if (ch() == "") fail("未闭合 inline table")
    if (ch() == "}") { adv(); strict_inline = 0; return }
    parse_key(1)
    sc = key_canon
    sr = key_raw
    skip_inline(1)
    if (ch() != "=") fail("inline table 缺少等号")
    adv()
    skip_inline(1)
    np++
    Pcanon[np] = sc
    Pkey[np] = sr
    if (sc == "status_line") {
      if (ch() != "{") fail("ui.status_line 的值不是 inline table")
      parse_inline(2)
      Psl[np] = 1
      Pval[np] = ""
    } else {
      parse_value(1)
      Psl[np] = 0
      Pval[np] = val_raw
    }
    skip_inline(1)
    if (ch() == ",") { adv(); continue }
    if (ch() == "}") { adv(); strict_inline = 0; return }
    fail("inline table 语法无法识别")
  }
}

function rebuild_root_ui(    i, out, piece, saw_inline, saw_dotted, ntype, ncmd, rest) {
  out = "{"
  saw_inline = 0
  saw_dotted = 0
  ntype = 0
  ncmd = 0
  for (i = 1; i <= np; i++) {
    if (Pcanon[i] == "status_line") {
      if (!Psl[i]) fail("ui.status_line 的值不是 inline table")
      saw_inline++
    } else if (index(Pcanon[i], "status_line\034") == 1) {
      saw_dotted++
    }
  }
  if (saw_inline > 1) fail("inline ui 里重复定义了 status_line")
  if (saw_inline && saw_dotted) fail("inline ui 里混用了 status_line 写法")
  for (i = 1; i <= np; i++) {
    if (Pcanon[i] == "status_line") {
      sl_existed = 1
      piece = rebuild_inner_sl()
      out = append_piece(out, "status_line = " piece)
    } else if (index(Pcanon[i], "status_line\034") == 1) {
      sl_existed = 1
      rest = substr(Pcanon[i], length("status_line") + 2)
      if (index(rest, "\034") == 0 && rest == "type") {
        ntype++
        if (ntype > 1) fail("inline ui 里重复定义了 status_line")
        out = append_piece(out, Pkey[i] " = \"command\"")
      } else if (index(rest, "\034") == 0 && rest == "command") {
        ncmd++
        if (ncmd > 1) fail("inline ui 里重复定义了 status_line")
        note_command_raw(Pval[i])
        out = append_piece(out, Pkey[i] " = \"" cmd "\"")
      } else {
        out = append_piece(out, Pkey[i] " = " Pval[i])
      }
    } else {
      out = append_piece(out, Pkey[i] " = " Pval[i])
    }
  }
  if (saw_dotted) {
    if (!ntype) out = append_piece(out, "status_line.type = \"command\"")
    if (!ncmd) out = append_piece(out, "status_line.command = \"" cmd "\"")
  }
  if (!saw_inline && !saw_dotted) {
    piece = "{ type = \"command\", command = \"" cmd "\" }"
    out = append_piece(out, "status_line = " piece)
  }
  return out " }"
}

function parse_header(    is_arr, path, header_end) {
  adv()
  is_arr = 0
  if (ch() == "[") { is_arr = 1; adv() }
  parse_key(1)
  path = key_canon
  if (ch() != "]") fail("表头未闭合")
  adv()
  if (is_arr) {
    if (ch() != "]") fail("数组表头未闭合")
    adv()
  }
  skip_hs()
  if (ch() == "#") skip_comment()
  if (ch() != "" && ch() != "\n") fail("表头同一行还有别的内容")
  header_end = L
  if (ch() == "\n") adv()
  if (path == SL) {
    if (is_arr) fail("不支持 [[ui.status_line]]")
    if (sl_defined == "header") fail("重复的 [ui.status_line]")
    note_form("header")
    sl_existed = 1
    header_insert_line = header_end
  }
  if (root_ui_inline && (path == "ui" || index(path, "ui\034") == 1))
    fail("根级 inline ui 不能再声明子表")
  if (path == "ui" || index(path, "ui\034") == 1)
    ui_header = 1
  set_cur(path)
}

function parse_keyval(    start_line, start_col, kv_indent, kv_key_raw, path, vL, vC, endL, endC, newv, prefix) {
  start_line = L
  start_col = C
  kv_indent = ""
  if (start_col > 1) kv_indent = substr(text[start_line], 1, start_col - 1)
  parse_key(1)
  kv_key_raw = key_raw
  path = join_path(cur, key_canon)

  if (ch() != "=") fail("缺少等号")
  adv()
  skip_gap()
  if (ch() == "") fail("缺少值")

  # A dotted `ui.*` at root defines table ui. Do not also accept `ui = { ... }`.
  if (cur == "" && index(path, "ui\034") == 1) {
    if (root_ui_inline) fail("根级 inline ui 不能再使用点号键扩展")
    root_ui_dotted = 1
  }

  if (path == "ui") {
    if (ch() != "{") fail("根级 ui 不是 inline table，无法写入 status_line")
    if (ui_header || root_ui_dotted) fail("根级 ui 已有其他定义，无法按 inline table 合并")
    if (root_ui_inline) fail("重复的根级 ui")
    root_ui_inline = 1
    note_form("inline")
    vL = L
    vC = C
    parse_root_ui_value()
    endL = L
    endC = C
    schedule_replace(start_line, vL, vC, endL, endC, rebuild_root_ui(), kv_indent, kv_key_raw)
    finish_statement()
    return
  }

  if (path == SL) {
    if (ch() != "{") fail("status_line 的值不是 inline table")
    note_form("inline")
    sl_existed = 1
    vL = L
    vC = C
    parse_inline(1)
    endL = L
    endC = C
    schedule_replace(start_line, vL, vC, endL, endC, rebuild_inline(), kv_indent, kv_key_raw)
    finish_statement()
    return
  }

  if (!inside_sl() && index(path, SL "\034") == 1) {
    note_form("dotted")
    sl_existed = 1
    prefix = sl_rel_prefix()
    vL = L
    vC = C
    if (path == SL "\034type" || path == SL "\034command") {
      parse_value(1)
      endL = L
      endC = C
      if (path == SL "\034command") {
        note_command_raw(val_raw)
        newv = "\"" cmd "\""
        saw_command = 1
      } else {
        newv = "\"command\""
        saw_type = 1
      }
      schedule_replace(start_line, vL, vC, endL, endC, newv, kv_indent, kv_key_raw)
      remember_dotted(prefix, start_line)
    } else {
      parse_value(0)
      endL = L
      remember_dotted(prefix, endL)
    }
    finish_statement()
    return
  }

  if (cur == SL && (path == SL "\034type" || path == SL "\034command")) {
    vL = L
    vC = C
    parse_value(1)
    endL = L
    if (path == SL "\034command") note_command_raw(val_raw)
    drop_range(start_line, endL)
    finish_statement()
    return
  }

  parse_value(0)
  finish_statement()
}

function parse_doc(    c) {
  L = 1
  C = 1
  set_cur("")
  while (1) {
    skip_top()
    c = ch()
    if (c == "") return
    if (c == "[") parse_header()
    else parse_keyval()
  }
}

function finish_edits(    block) {
  if (sl_defined == "header") {
    if (header_insert_line < 1) fail("找不到 [ui.status_line] 表头")
    insert_after[header_insert_line] = "type = \"command\"\ncommand = \"" cmd "\""
  } else if (sl_defined == "dotted" && (!saw_type || !saw_command)) {
    if (dotted_prefix == "" || dotted_anchor < 1)
      fail("无法补齐 ui.status_line 的 type 或 command")
    block = ""
    if (!saw_type) block = block dotted_prefix ".type = \"command\"\n"
    if (!saw_command) block = block dotted_prefix ".command = \"" cmd "\"\n"
    insert_after[dotted_anchor] = insert_after[dotted_anchor] block
  }
  if (sl_existed && !ours)
    print "ℹ️  config.toml [ui.status_line] 原有配置已被仓库的 command 状态栏接管" > "/dev/stderr"
}

function print_block(block, cr,    k, m, parts) {
  m = split(block, parts, "\n")
  if (m > 0 && parts[m] == "") m--
  for (k = 1; k <= m; k++) printf "%s%s\n", parts[k], cr
}

function emit(    i, cr) {
  cr = use_cr ? "\r" : ""
  for (i = 1; i <= n; i++) {
    if (action[i] == "replace") printf "%s%s\n", replace[i], cr
    else if (action[i] != "drop") printf "%s\n", raw[i]
    if (insert_after[i] != "") print_block(insert_after[i], cr)
  }
  if (sl_defined == "") {
    if (n > 0 && text[n] != "") printf "%s\n", cr
    printf "%s%s\n", "[ui.status_line]", cr
    printf "%s%s\n", "type = \"command\"", cr
    printf "%s%s\n", "command = \"" cmd "\"", cr
  }
}

{
  n++
  raw[n] = $0
  text[n] = $0
  if (text[n] ~ /\r$/) {
    sub(/\r$/, "", text[n])
    use_cr = 1
  }
}

END {
  if (failed) exit 2
  parse_doc()
  if (failed) exit 2
  finish_edits()
  if (failed) exit 2
  emit()
}
