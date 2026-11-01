-- src/seed.lua —— 种子的格式化与输入缓冲（纯逻辑，不引用 love）
--
-- 【为什么单独一个模块】
--   种子要干三件互不相干的事：显示（补零）、解析（玩家输入）、编辑缓冲
--   （按键追加 / 退格）。菜单、结算页、认输面板、种子输入屏都要用；
--   散在四个界面里，迟早有一处忘了补零，于是 "42" 和 "000042" 变成两局。
--
-- 【种子的定义】
--   M.MIN .. M.MAX（现在 0 .. 9999999999）的整数。
--   发牌时交给 love.math.newRandomGenerator(seed) —— 单参版本能精确表示到 2^53
--   （约 9.0e15），10 位十进制（1e10）离上限还有四个数量级，不需要 low/high 双参。
--   注意一局的身份是 (seed, difficulty)：同一个种子配不同难度不是同一局。
--
-- 【为什么是 10 位而不是 6 位（M14）】
--   牌局空间约 1e150，任何位宽都"覆盖不了全部" —— 那不是目标。
--   真正的指标是撞车率：6 位时 makeSeed 只产 90 万个值，生日问题下
--   1000 局内撞到重复牌局的概率是 42.6%；10 位（90 亿个值）降到 0.0055%。
--   ⚠ 种子身份是【数值】不是字符串，所以老的 "123456" 仍然解析成 123456，
--     发出的牌一模一样，只是显示时补成 "0000123456"。不需要任何兼容代码。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local M = {}

-- ⚠ DIGITS > 10 时，src/states/seed.lua 的 400px 输入面板装不下：
--   DejaVuSans 每位数字 1303/2048 em，54px 字号下每位 34.35px
--   → 10 位 344px（放得下）、12 位 412px（溢出）。要改就得先加宽那块面板。
M.DIGITS = 10
M.MIN    = 0            -- 保留：既有的 format(0)/parse("0") 行为，别动

-- MAX = 10^DIGITS - 1。用循环而不是 10^DIGITS - 1：
--   ^ 在 Lua 5.3+ 永远返回 float，MAX 会变成 9999999999.0，
--   之后的比较、math.type、日志输出都会变得意外。
local max = M.MIN
for _ = 1, M.DIGITS do max = max * 10 + 9 end
M.MAX = max

-- 最小的 DIGITS 位种子（首位非 0）与它的可选值个数。
-- makeSeed 只在这个区间里取 → 界面上永远是满位数，
-- 不会出现 "00000xxxxx" 这种看着像出错的串。
local floor = 1
for _ = 2, M.DIGITS do floor = floor * 10 end
M.FLOOR = floor
M.SPAN  = M.MAX - M.FLOOR + 1

-- 模块级格式串：菜单每帧都调 format，不必每次现拼。
local FORMAT = "%0" .. M.DIGITS .. "d"

-- 42 -> "0000000042"。非数字 / 非整数 / 越界一律 nil，由调用方决定怎么兜。
function M.format(n)
  if type(n) ~= "number" then return nil end
  if n ~= math.floor(n) then return nil end
  if n < M.MIN or n > M.MAX then return nil end
  return string.format(FORMAT, n)
end

-- "42" / "0000000042" -> 42。空串、含字母、超过 DIGITS 位一律 nil。
-- 不足位数照样能用（左补零），所以玩家抄 10 位种子时可以省掉前导零。
function M.parse(s)
  if type(s) ~= "string" then return nil end
  if #s < 1 or #s > M.DIGITS then return nil end
  if not string.match(s, "^%d+$") then return nil end

  local n = tonumber(s)
  if not n or n < M.MIN or n > M.MAX then return nil end
  return n
end

-- 把按键名翻译成一个数字字符。"7" 与 "kp7" 都算，其它一律 nil。
function M.digit(key)
  if type(key) ~= "string" then return nil end

  local d = string.match(key, "^%d$")
  if d then return d end
  return string.match(key, "^kp(%d)$")
end

-- 往缓冲末尾追加一位；满了就不动（不报错，玩家的感受只是"按了没反应"）。
function M.push(buf, key)
  if type(buf) ~= "string" then buf = "" end
  local d = M.digit(key)
  if not d then return buf end
  if #buf >= M.DIGITS then return buf end
  return buf .. d
end

function M.pop(buf)
  if type(buf) ~= "string" or #buf == 0 then return "" end
  return string.sub(buf, 1, #buf - 1)
end

-- 把剪贴板文本里的数字补到缓冲末尾（M19）。
--
-- 为什么是"补"而不是"替换"：这一屏的语义就是"一位一位往里敲"，粘贴只是把
-- 一次敲很多位变成一个事件。想重来有 delete 键，不至于要靠粘贴去清空。
-- 剥掉非数字是必须的：从别处粘一句 "seed 1234567890" 时，全塞进去会变成非法输入。
function M.paste(buf, clip)
  if type(buf) ~= "string" then buf = "" end
  if type(clip) ~= "string" then return buf end

  local digits = string.gsub(clip, "%D", "")
  if digits == "" then return buf end

  local room = M.DIGITS - #buf
  if room <= 0 then return buf end
  return buf .. string.sub(digits, 1, room)
end

-- 输入框里显示的样子：没填的位置用 "-" 占位，玩家能看出还差几位。
function M.display(buf)
  if type(buf) ~= "string" then buf = "" end
  if #buf > M.DIGITS then buf = string.sub(buf, 1, M.DIGITS) end
  return buf .. string.rep("-", M.DIGITS - #buf)
end

-- 把任意整数折进 [FLOOR, MAX]。
--
-- 【为什么放在这里而不是 main.lua】
--   种子的"取值范围"必须只有一个来源。以前 main.lua 里写的是
--   `% 900000 + 100000`，独立于 seed.MAX 的第二套上限 —— 改了一处忘了另一处，
--   界面显示 10 位而新局仍然只发 6 位，终端测试还全绿（main.lua 不被测）。
--   搬进这个纯逻辑模块之后，取值范围可以在终端被断言。
function M.wrap(n)
  if type(n) ~= "number" then return nil end
  return math.floor(n) % M.SPAN + M.FLOOR
end

return M
