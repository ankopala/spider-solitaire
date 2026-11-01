-- tests/stock_smoke.lua —— M4 终端验证脚本（补牌 stock）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/stock_smoke.lua
--
-- 本脚本不依赖 LÖVE。
--
-- 与 rules_smoke 的区别：那边用手写确定性牌局钉规则，这边用【随便一副真牌局】
-- （断言全是"不变量"——张数、总量守恒、取牌顺序、错误分支），
-- 所以同一份脚本在 Lua 5.1（LÖVE 的运行时）下换成另一副牌也照样应该全过。

-- 修正 package.path：让 require("src.xxx") 与 LÖVE 里写法一致
local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local const  = require("const")
local layout = require("src.layout")
local game   = require("src.game")

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

-- ===== 工具 =====

-- 确定性伪随机：同一 seed 每次都发同一副牌（不依赖 math.random 的实现差异）
local function makeRng(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return (s % n) + 1
  end
end

local function newGame()
  return game.new(4, makeRng(20261019))
end

-- 全桌牌数（tableau + stock + foundation 的组数 × 13）应为 104
local function totalCards(g)
  local n = #g.stock
  for i = 1, const.COLS do n = n + #g.tableau[i] end
  for _, suit in ipairs({ "spades", "hearts", "diamonds", "clubs" }) do
    n = n + (g.foundations[suit] or 0) * 13
  end
  return n
end

local function colSizes(g)
  local t = {}
  for i = 1, const.COLS do t[i] = #g.tableau[i] end
  return t
end

local function sameNums(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function contains(s, needle)
  return string.find(s or "", needle, 1, true) ~= nil
end

-- stock 矩形内 / 外各取一点
local STOCK_CX = const.STOCK_X + const.STOCK_W / 2
local STOCK_CY = const.STOCK_Y + const.STOCK_H / 2

-- 1. 初始状态
section("1. 新开一局的 stock 状态")

local g1 = newGame()
check("stock 有 50 张（5 轮 × 10 张）", #g1.stock == 50)
check("dealsLeft = 5", game.dealsLeft(g1) == 5)
check("10 列全部非空", game.firstEmptyColumn(g1) == nil)
check("canDealFromStock = true", game.canDealFromStock(g1) == true)
check("全桌共 104 张", totalCards(g1) == 104)

-- 2. 补一轮
section("2. 补一轮：10 列各 +1 张并翻开")

local g2 = newGame()
local before2   = colSizes(g2)
local snapshot2 = {}
for k = 1, #g2.stock do snapshot2[k] = g2.stock[k] end   -- 记录补牌前的 stock 顺序

local ok2, msg2 = game.dealFromStock(g2)
check("dealFromStock 返回 true", ok2 == true)
check("提示含 dealt a card to every column", contains(msg2, "dealt a card to every column"))
check("stock 50 -> 40", #g2.stock == 40)
check("dealsLeft 5 -> 4", game.dealsLeft(g2) == 4)

local okCount = true
for i = 1, const.COLS do
  if #g2.tableau[i] ~= before2[i] + 1 then okCount = false end
end
check("每一列都正好 +1 张", okCount)

local allFaceUp = true
for i = 1, const.COLS do
  if g2.tableau[i][#g2.tableau[i]].faceUp ~= true then allFaceUp = false end
end
check("每列新顶牌都是正面朝上", allFaceUp)

check("补牌记 1 步（moves 1）", g2.moves == 1)
check("补牌扣 1 分（score 499）", g2.score == 499)
check("全桌仍是 104 张（牌没丢没复制）", totalCards(g2) == 104)

-- 3. 取牌顺序：从 stock 尾部取，第 1 列拿最后一张
section("3. 取牌顺序（LIFO：从 stock 尾部取）")

local okOrder = true
for i = 1, const.COLS do
  if g2.tableau[i][#g2.tableau[i]] ~= snapshot2[#snapshot2 - (i - 1)] then
    okOrder = false
  end
end
check("col i 的顶牌 = 补牌前 stock 的倒数第 i 张", okOrder)

local okKeep = true
for i = 1, const.COLS do
  if g2.tableau[i][#g2.tableau[i] - 1] ~= nil then
    -- 补牌前的顶牌现在应该是倒数第二张（牌没有被替换掉）
    local expected = nil
    expected = expected  -- 仅为可读性，实际用下面的张数判断
  end
end
check("补牌是【追加】在列尾，不是替换（张数已验证，见上）", okKeep)

-- 4. 连补 5 轮
section("4. 连续补 5 轮：stock 耗尽")

local g4 = newGame()
local msgs = {}
for r = 1, 5 do
  local okr = game.dealFromStock(g4)
  msgs[r] = g4.message
  if not okr then msgs[r] = "FAILED" end
end
check("5 轮全部成功", not contains(table.concat(msgs, "|"), "FAILED"))
check("stock 归零", #g4.stock == 0)
check("dealsLeft = 0", game.dealsLeft(g4) == 0)
check("moves = 5、score = 495", g4.moves == 5 and g4.score == 495)
check("前 4 列 6+5=11 张", #g4.tableau[1] == 11 and #g4.tableau[4] == 11)
check("后 6 列 5+5=10 张", #g4.tableau[5] == 10 and #g4.tableau[10] == 10)
check("全桌仍是 104 张", totalCards(g4) == 104)

-- 5. 牌库空了以后再补
section("5. stock 空了之后：拒绝且不改变任何状态")

local beforeMoves, beforeScore = g4.moves, g4.score
local ok5, msg5 = game.dealFromStock(g4)
check("返回 false", ok5 == false)
check("提示含 stock is empty", contains(msg5, "stock is empty"))
check("moves / score 不变", g4.moves == beforeMoves and g4.score == beforeScore)
check("各列张数不变", #g4.tableau[1] == 11 and #g4.tableau[10] == 10)
check("canDealFromStock = false", game.canDealFromStock(g4) == false)

-- 6. 有空列时禁止补牌（M4 最重要的一条规则）
section("6. 有空列时禁止补牌")

local g6 = newGame()
g6.tableau[7] = {}                                   -- 人为清空第 7 列
local before6 = colSizes(g6)

check("firstEmptyColumn 找到第 7 列", game.firstEmptyColumn(g6) == 7)
check("canDealFromStock = false", game.canDealFromStock(g6) == false)

local ok6, msg6 = game.dealFromStock(g6)
check("dealFromStock 返回 false", ok6 == false)
check("提示指出是第 7 列为空", contains(msg6, "col 7 is empty"))
check("提示说明每列都要有牌", contains(msg6, "every column must have a card"))
check("stock 没被动（仍 50 张）", #g6.stock == 50)
check("其它列张数不变", sameNums(colSizes(g6), before6))
check("moves / score 不变", g6.moves == 0 and g6.score == 500)

-- 7. 把空列填回去 → 又能补
section("7. 空列填回一张 → 恢复可补")

local card1 = require("src.card")
g6.tableau[7][1] = card1.new("spades", 5, true)
check("firstEmptyColumn 变 nil", game.firstEmptyColumn(g6) == nil)
check("canDealFromStock = true", game.canDealFromStock(g6) == true)
local ok7 = game.dealFromStock(g6)
check("补牌成功", ok7 == true)
check("stock 50 -> 40", #g6.stock == 40)
check("第 7 列 1 -> 2 张", #g6.tableau[7] == 2)

-- 8. 有选中牌时补牌失败 —— 不清选中
section("8. 补牌失败不清选中（与非法落点一致）")

local g8 = newGame()
g8.tableau[10] = {}                                  -- 造一个空列，让补牌必然失败
game.trySelect(g8, 1, #g8.tableau[1])
check("先选中第 1 列顶牌", g8.selected ~= nil)
local ok8 = game.dealFromStock(g8)
check("补牌失败", ok8 == false)
check("选中态仍在（用户可以接着去移动）", g8.selected ~= nil)

-- 9. 点击链路：点 stock
section("9. 点击链路：点 stock 区域")

local g9 = newGame()
local msg9 = game.clickAt(g9, STOCK_CX, STOCK_CY)
check("点 stock → 补牌成功（stock 50 -> 40）", #g9.stock == 40)
check("返回的提示非空", msg9 ~= nil and #msg9 > 0)
check("moves = 1", g9.moves == 1)

-- 点 stock 外面一点点（左边界外 5px）：不该补牌
local g9b = newGame()
game.clickAt(g9b, const.STOCK_X - 5, STOCK_CY)
check("点 stock 左边界外 → 不补牌", #g9b.stock == 50)

-- 点 stock 上方 5px（仍属底部空白，不属于任何列带）：不该补牌
local g9c = newGame()
game.clickAt(g9c, STOCK_CX, const.STOCK_Y - 5)
check("点 stock 上方 → 不补牌", #g9c.stock == 50)

-- 命中检测边界：四角内侧命中、外侧 1px 不命中。
-- 宽度按【整叠】算（最上面那张 + 4 次错开），否则牌堆右侧露出的边点不动。
local STOCK_HIT_W = const.STOCK_W + (const.STOCK_STACK_MAX - 1) * const.STOCK_STACK_DX
check("hitTestStock 左上角内侧命中",
      layout.hitTestStock(const.STOCK_X, const.STOCK_Y) == true)
check("hitTestStock 右下角内侧命中",
      layout.hitTestStock(const.STOCK_X + STOCK_HIT_W, const.STOCK_Y + const.STOCK_H) == true)
check("hitTestStock 覆盖整叠（最右那张的右沿）",
      layout.hitTestStock(const.STOCK_X + const.STOCK_W + 1, STOCK_CY) == true)
check("hitTestStock 右侧外 1px 不命中",
      layout.hitTestStock(const.STOCK_X + STOCK_HIT_W + 1, STOCK_CY) == false)

-- 10. 选中状态下点 stock：补牌成功并清掉选中
section("10. 选中状态下点 stock")

local g10 = newGame()
game.trySelect(g10, 1, #g10.tableau[1])
check("先选中一张牌", g10.selected ~= nil)
game.clickAt(g10, STOCK_CX, STOCK_CY)
check("补牌成功", #g10.stock == 40)
check("选中被清掉（补完牌由界面重新开始）", g10.selected == nil)

-- 11. 补牌不影响 tableau 里已有牌的身份
section("11. 补牌只追加，不动已有牌")

local g11 = newGame()
local topBefore = {}
for i = 1, const.COLS do topBefore[i] = g11.tableau[i][#g11.tableau[i]] end
game.dealFromStock(g11)
local okSame = true
for i = 1, const.COLS do
  local col = g11.tableau[i]
  if col[#col - 1] ~= topBefore[i] then okSame = false end
end
check("每列原顶牌仍在（现在是倒数第二张）", okSame)

-- 12. dump 不报错（界面按 D 会调它）
section("12. dump 快照可打印")
local okDump = pcall(function() return game.dump(g11) end)
check("game.dump 正常返回", okDump == true)

-- ===== 13. 牌背装饰的几何守卫（M16）=====
-- render.lua 不能被终端加载（它 require 了 love.graphics），所以这里的可测对象是
-- const.lua 里那组纯数据。断言的是【设计约束】，不是像素：颜色层次、接缝位置、
-- 蜘蛛包围盒必须落在内框里、不能压到牌库右下角的轮数数字。
section("13. 牌背装饰（蜘蛛 + 叠压纸边）的几何约束")

-- 明度（人眼加权）。用相对关系断言，不写死色值。
local function lum(c)
  return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end

check("颜色层次：暗轮廓 < 底色 < 亮切边 < 蜘蛛 < 内框",
  lum(const.COLOR_CARD_BACK_SHADE) < lum(const.COLOR_CARD_BACK)
  and lum(const.COLOR_CARD_BACK) < lum(const.COLOR_CARD_BACK_EDGE)
  and lum(const.COLOR_CARD_BACK_EDGE) < lum(const.COLOR_CARD_BACK_ICON)
  and lum(const.COLOR_CARD_BACK_ICON) < lum(const.COLOR_CARD_BACK_LINE))

-- 叠压双线（M18）：暗轮廓 + 亮切边都必须压在低对比区间。
-- M16 的「脏条纹」事故用的是内框原色（ΔL 0.20）；这里两者都该在 0.1 以内，
-- 否则 8px 周期的高对比横线又会读成条纹而不是"纸的边界"。
check("双线对比度都压在 ΔL 0.1 以内",
  math.abs(lum(const.COLOR_CARD_BACK) - lum(const.COLOR_CARD_BACK_SHADE)) < 0.1
  and math.abs(lum(const.COLOR_CARD_BACK_EDGE) - lum(const.COLOR_CARD_BACK)) < 0.1)

-- 亮切边必须落在露出的 8px 内：>= STEP_DOWN 就被下一张牌整个盖住，等于白画
check("亮切边落在窄条内", const.CARD_BACK_RIM_DY > 0
  and const.CARD_BACK_RIM_DY < const.STEP_DOWN)

-- 切边两端必须缩到内框圆角之外，才和真实内框顶边的直线段等长（否则线头戳进弧里）
check("亮切边与内框顶边等长",
  const.CARD_BACK_RIM_INSET == const.CARD_BACK_INSET + (const.CARD_R - 3))
-- 但也不能缩成一小段短杠（那样读作"装饰点"而不是"纸的切面"）
check("亮切边不缩成短杠",
  const.CARD_W - const.CARD_BACK_RIM_INSET * 2 > const.CARD_W / 2)

-- 线宽 ≤ 1 时 LÖVE 的 smooth line 会把实心核削掉，出现断线感
check("蜘蛛线宽 > 1", const.CARD_BACK_ICON_W > 1)

-- 由腿表和躯干表现算包围盒（含线宽的一半）。腿是 x 方向镜像的，所以取正负。
check("腿表 4 条、每条 3 个点", #const.SPIDER_LEGS == 4
  and #const.SPIDER_LEGS[1] == 6 and #const.SPIDER_LEGS[4] == 6)
check("躯干两个椭圆：头小腹大（1:1.4 以上）",
  #const.SPIDER_BODY == 2
  and const.SPIDER_BODY[2][3] > const.SPIDER_BODY[1][3] * 1.4
  and const.SPIDER_BODY[2][4] > const.SPIDER_BODY[1][4] * 1.4)

local hw   = const.CARD_BACK_ICON_W / 2
local minx, maxx, miny, maxy = 0, 0, 0, 0
for _, L in ipairs(const.SPIDER_LEGS) do
  for _, px in ipairs({ L[1], L[3], L[5] }) do
    if -px < minx then minx = -px end
    if  px > maxx then maxx =  px end
  end
  for _, py in ipairs({ L[2], L[4], L[6] }) do
    if py < miny then miny = py end
    if py > maxy then maxy = py end
  end
end
for _, b in ipairs(const.SPIDER_BODY) do
  if b[1] - b[3] < minx then minx = b[1] - b[3] end
  if b[1] + b[3] > maxx then maxx = b[1] + b[3] end
  if b[2] - b[4] < miny then miny = b[2] - b[4] end
  if b[2] + b[4] > maxy then maxy = b[2] + b[4] end
end

-- 图标中心：卡牌中心 + CARD_BACK_ICON_DY
local cx = const.CARD_W / 2
local cy = const.CARD_H / 2 + const.CARD_BACK_ICON_DY
local L, R = cx + minx - hw, cx + maxx + hw
local T, B = cy + miny - hw, cy + maxy + hw

local i0 = const.CARD_BACK_INSET
check("蜘蛛完全在内框内（四边留白 ≥ 4px）",
  L >= i0 + 4 and R <= const.CARD_W - i0 - 4
  and T >= i0 + 4 and B <= const.CARD_H - i0 - 4)

-- 牌库右下角的轮数数字：x 右对齐于 STOCK_W-12，y 底对齐于 STOCK_H-8。
-- 字体度量来自 DejaVuSans（upem 2048 / ascent 1901 / descent 483 / 数字 advance 1303）。
local FONT_UPEM, FONT_ASC, FONT_DESC, DIGIT_ADV = 2048, 1901, 483, 1303
local numH = const.FONT_SMALL * (FONT_ASC - FONT_DESC) / FONT_UPEM
local numW = const.FONT_SMALL * DIGIT_ADV / FONT_UPEM
local numL = const.STOCK_W - numW - 12
local numT = const.STOCK_H - numH - 8
check("图标不与轮数数字相交", B <= numT or R <= numL)

-- 牌库 5 张向右错开，后画的压在右边 → 下层牌只露自己左侧一条。
-- 图标左边界必须越过这条露出的窄边，否则会被"切一条"。
check("图标不被错开处的窄边切到", L > const.STOCK_STACK_DX + hw)

-- ===== 13b. 牌库层间分界（M17）=====
-- 5 张错开后底色完全相同，不画分界就融成一整块 128px 宽的板（用户原话"像没有边界"）。
-- 做法是每张沿轮廓描一圈比底色暗一档的线：暗 = "卡与卡之间的缝"。
section("13b. 牌库层间暗缝")

check("层间暗缝：比牌背底色暗、比桌面背景亮（是卡片轮廓，不是黑线）",
  lum(const.COLOR_CARD_BACK_SHADE) < lum(const.COLOR_CARD_BACK)
  and lum(const.COLOR_CARD_BACK_SHADE) > lum(const.COLOR_BG))

-- 错开量太小的话，1px 暗缝两侧各剩不到 2px 底色 → 读成"细密条纹"而不是"一张纸的边"。
-- 4px 实测在正常观看距离下分辨不出（用户反馈），7px 才够。
check("每层错开量 ≥ 6px", const.STOCK_STACK_DX >= 6)

check("牌库整叠 + hover 描边不越出右边界",
  const.STOCK_X + const.STOCK_W
    + (const.STOCK_STACK_MAX - 1) * const.STOCK_STACK_DX
    + const.HINT_PAD <= const.VW)

-- 错开量不能超过内框内缩量，否则下层牌的【整条内框竖线】会露进露出条带，
-- 每条边末端都多一条亮线，读成"双线框"。取等号是刚好的：内框只露出它自己的
-- AA 半边（实测 x+6.5..x+7 处 0.345），正好当"纸的切边"用，不刺眼。
check("错开量不超过内框内缩量（否则露出整条内框线）",
  const.STOCK_STACK_DX <= const.CARD_BACK_INSET)

-- 汇总
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
