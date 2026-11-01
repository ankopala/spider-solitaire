-- tests/seed_smoke.lua —— M12「种子输入」的格式化与缓冲（终端验证，不需要 LÖVE）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/seed_smoke.lua
--
-- 这里守的是同一件事的两端：显示必须补零（"42" ≠ "0000000042" 会让同种子变两局），
-- 输入必须挡脏（空格、字母、超位数、小数点都不该进缓冲）。
--
-- ⚠ 所有期望值都由 seed.DIGITS 推导，不写死位数。
--   以前这里写死了 "000042" / "1234567"，改位数时得逐行找出来改，漏一处就假绿。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local seed = require("src.seed")

-- ===== 由 DIGITS 推导的构造器 =====
local D = seed.DIGITS
local function zeros(n) return string.rep("0", n) end
local function rep(ch, n) return string.rep(ch, n) end
local NINES = rep("9", D)

-- ===== 断言小工具 =====
local passed, failed = 0, 0

local function check(name, cond)
  if cond then
    passed = passed + 1
    print("  [PASS] " .. name)
  else
    failed = failed + 1
    print("  [FAIL] " .. name)
  end
end

local function section(title)
  print("")
  print(title)
  print(string.rep("-", 62))
end

-- ===== 1. format：补零与越界 =====
section("1. format")

check("42 -> 补到 DIGITS 位", seed.format(42) == zeros(D - 2) .. "42")
check("0 -> 全零", seed.format(0) == zeros(D))
check("MAX 原样（满位）", seed.format(seed.MAX) == NINES)
check("MAX+1 越界 -> nil", seed.format(seed.MAX + 1) == nil)
check("负数 -> nil", seed.format(-1) == nil)
check("小数 -> nil", seed.format(1.5) == nil)
check("字符串 -> nil", seed.format("12") == nil)
check("nil -> nil", seed.format(nil) == nil)

-- ===== 2. parse：玩家输入 =====
section("2. parse")

check("\"42\" -> 42", seed.parse("42") == 42)
check("前导零不影响身份", seed.parse(zeros(D - 2) .. "42") == 42)
check("\"0\" -> 0", seed.parse("0") == 0)
check("全零 -> 0", seed.parse(zeros(D)) == 0)
check("空串 -> nil", seed.parse("") == nil)
check("含字母 -> nil", seed.parse("12a") == nil)
check("DIGITS+1 位 -> nil", seed.parse(rep("1", D + 1)) == nil)
check("前导空格 -> nil", seed.parse(" 42") == nil)
check("nil -> nil", seed.parse(nil) == nil)

-- 老 6 位种子：身份是数值不是字符串，所以它仍然是同一局。
-- 这条断言的作用是【防止有人为了"兼容旧种子"去写一段转换代码】——那才是引 bug 的地方。
check("6 位老种子仍是同一个数值", seed.parse("123456") == 123456)
check("老种子显示时补到 DIGITS 位", seed.format(123456) == zeros(D - 6) .. "123456")

-- ===== 3. digit / push / pop：输入缓冲 =====
section("3. 输入缓冲")

check("digit \"7\"", seed.digit("7") == "7")
check("digit \"kp7\"", seed.digit("kp7") == "7")
check("digit \"10\" -> nil", seed.digit("10") == nil)
check("digit \"a\" -> nil", seed.digit("a") == nil)

check("空缓冲 + 1 -> \"1\"", seed.push("", "1") == "1")
check("满 DIGITS 位再按 -> 不变", seed.push(rep("1", D), "9") == rep("1", D))
check("非数字键 -> 不变", seed.push("12", "a") == "12")
check("kp 键也能输入", seed.push("12", "kp3") == "123")

check("退格 123 -> 12", seed.pop("123") == "12")
check("退格一位 -> 空", seed.pop("1") == "")
check("空串退格 -> 空", seed.pop("") == "")

-- ===== 4. display：输入框占位 =====
section("4. display")

check("空 -> 全是占位符", seed.display("") == rep("-", D))
check("两位 -> 两位 + 占位符", seed.display("12") == "12" .. rep("-", D - 2))
check("满 -> 原样", seed.display(rep("1", D)) == rep("1", D))
check("超长先截断", seed.display(rep("1", D + 1)) == rep("1", D))

-- ===== 5. 往返 =====
section("5. format 与 parse 往返")

for _, n in ipairs({ 0, 7, 42, 123456, 1234567890, seed.MAX }) do
  local text = seed.format(n)
  check(tostring(n) .. " 往返不变", seed.parse(text) == n)
end

-- 逐位输入满 DIGITS 位后，缓冲就是那串数字（顺手验证小键盘）
check("逐位输入满 DIGITS 位", (function()
  local want = "1" .. rep("2", D - 1)
  local buf = ""
  for i = 1, #want do
    local k = string.sub(want, i, i)
    if i == 3 then k = "kp" .. k end
    buf = seed.push(buf, k)
  end
  return buf == want and seed.parse(buf) == tonumber(want)
end)())

-- ===== 6. 取值区间：常量自洽与 wrap =====
section("6. 取值区间与 wrap")

check("MAX 与 DIGITS 同步", seed.MAX == tonumber(NINES))
check("FLOOR 是 10^(DIGITS-1)", seed.FLOOR == tonumber("1" .. zeros(D - 1)))
check("SPAN = MAX - FLOOR + 1", seed.SPAN == seed.MAX - seed.FLOOR + 1)
check("#format(MAX) 正好 DIGITS 位", #seed.format(seed.MAX) == D)

check("wrap(0) -> FLOOR", seed.wrap(0) == seed.FLOOR)
check("wrap(SPAN-1) -> MAX", seed.wrap(seed.SPAN - 1) == seed.MAX)
check("wrap(SPAN) -> FLOOR", seed.wrap(seed.SPAN) == seed.FLOOR)
check("wrap(MAX+1) 仍落在区间内", (function()
  local v = seed.wrap(seed.MAX + 1)
  return v >= seed.FLOOR and v <= seed.MAX
end)())
check("wrap 以 SPAN 为周期", (function()
  for _, n in ipairs({ 0, 7, 123456, 233000000000, seed.MAX }) do
    if seed.wrap(n + seed.SPAN) ~= seed.wrap(n) then return false end
  end
  return true
end)())
check("wrap(非数字) -> nil", seed.wrap("1") == nil)

check("wrap 结果恒为满位数", (function()
  local probes = { 0, 1, 42, 123456, 233000000000, seed.MAX, seed.MAX + 1, seed.SPAN }
  for _, n in ipairs(probes) do
    local s = seed.format(seed.wrap(n))
    if not s or #s ~= D then return false end
  end
  return true
end)())

-- makeSeed 用的就是这个公式：同一时刻连开多局，种子必须两两不同
check("连开 200 局种子不撞", (function()
  local seen, dup = {}, 0
  for k = 1, 200 do
    local s = seed.wrap(1780000000 * 131 + 123456789 + k * 7919)
    if seen[s] then dup = dup + 1 end
    seen[s] = true
  end
  return dup == 0
end)())

-- ===== 粘贴（M19）=====
-- 面板上复制出来的种子是拿去粘回来的，所以 paste 要同时干两件事：
-- 剥掉非数字（"seed 42"、空格、回车都可能连在一起被复制走），
-- 再按【剩余位数】截断（粘出 12 位就等于粘进一个非法种子）。
--
-- 语义刻意是"补齐"而不是"替换"：这一屏本来就是一位一位往里敲，
-- 想重来有 delete 键。替换会让"敲了 5 位、粘一下前 5 位没了"。

check("空缓冲直接吃下整串数字", seed.paste("", "1234") == "1234")
check("空格 / 字母 / 制表符 / 回车全被剥掉",
  seed.paste("", "  1 2a3\t4\n") == "1234")
check("带 seed 前缀的整句也能用", seed.paste("", "seed 42") == "42")
check("一个数字都没有就原样返回", seed.paste("", "abc") == "")
check("nil 缓冲当作空串", seed.paste(nil, "42") == "42")
check("nil 剪贴板不改缓冲", seed.paste("12", nil) == "12")
check("非字符串剪贴板不改缓冲", seed.paste("12", 42) == "12")

local half = math.floor(D / 2)
local head = rep("1", half)
check("已有内容时是补齐而不是覆盖",
  seed.paste(head, rep("7", D)) == head .. rep("7", D - half))

check("超出剩余位数就截断", seed.paste("", rep("9", D + 5)) == NINES)
check("缓冲满了再粘不动", seed.paste(NINES, "8") == NINES)

-- ===== 汇总 =====
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
