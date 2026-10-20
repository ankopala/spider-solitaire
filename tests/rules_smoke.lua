-- tests/rules_smoke.lua —— M3 终端验证脚本（规则判定 + 点击链路）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/rules_smoke.lua
--
-- 本脚本不依赖 LÖVE。
--
-- 关键设计：这里**不用随机发牌**，而是手写每张牌拼出「确定性牌局」。
-- 因为随机发牌几乎不可能撞上边界情况（混花色序列、背面顶牌、点数差 1 边界），
-- 用手写牌局才能把每条规则都钉死。

-- 修正 package.path：让 require("src.xxx") 与 LÖVE 里写法一致
local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local const  = require("const")
local card   = require("src.card")
local layout = require("src.layout")
local rules  = require("src.rules")
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

-- ===== 手写牌局的工具 =====

local SUIT_OF = { S = "spades", H = "hearts", D = "diamonds", C = "clubs" }

-- spec 形如 { {"S", 13, true}, {"H", 12, false} } —— 从列底写到列顶
local function col(spec)
  local t = {}
  for _, e in ipairs(spec) do
    t[#t + 1] = card.new(SUIT_OF[e[1]], e[2], e[3])
  end
  return t
end

-- 用 10 列（或更少）的 spec 拼一个牌局；没给的列补空
local function makeGame(colSpecs)
  local tableau = {}
  for i = 1, 10 do tableau[i] = {} end
  for i, spec in ipairs(colSpecs or {}) do
    tableau[i] = col(spec)
  end
  return {
    tableau     = tableau,
    stock       = {},
    foundations = { spades = 0, hearts = 0, diamonds = 0, clubs = 0 },
    difficulty  = 4,
    score       = 500,
    moves       = 0,
    selected    = nil,
    message     = "",
  }
end

-- 命中第 i 列第 k 张牌时该点的虚拟坐标（+4 保证落在「露出那条」里面）
local function pointOf(g, i, k)
  return const.colX(i) + const.CARD_W / 2, layout.cardY(g.tableau[i], k) + 4
end

-- 空列可点的位置
local function emptyPointOf(i)
  return const.colX(i) + const.CARD_W / 2, const.TABLEAU_Y + 20
end

-- 点击封装：返回 game.clickAt 的返回消息
local function click(g, x, y)
  return game.clickAt(g, x, y)
end

local function clickCard(g, i, k)
  local x, y = pointOf(g, i, k)
  return click(g, x, y)
end

local function countCards(g)
  local n = 0
  for i = 1, 10 do n = n + #g.tableau[i] end
  return n + #g.stock
end

-- ============================================================
-- 1. canPickUp：什么序列能整组拿起
-- ============================================================
section("1. rules.canPickUp —— 整组移动的资格")

local g1 = makeGame({
  { { "S", 13, true }, { "S", 12, true }, { "S", 11, true } },        -- 同花连续降序
  { { "S", 13, true }, { "H", 12, true }, { "S", 11, true } },        -- 混花色
  { { "S", 13, true }, { "S", 11, true } },                            -- 点数不连续
  { { "S", 13, true }, { "S", 12, false } },                           -- 后面藏背面牌
  { { "S", 13, false }, { "S", 12, true } },                           -- 起点是背面
})

local c1, c2, c3, c4, c5 = g1.tableau[1], g1.tableau[2], g1.tableau[3], g1.tableau[4], g1.tableau[5]

check("同花连续降序（K-Q-J）→ 可拿起",       rules.canPickUp(c1, 1) == true)
check("同花连续降序，从中间拿起（Q-J）也合法", rules.canPickUp(c1, 2) == true)
check("单张翻开牌总是可拿起",                 rules.canPickUp(c1, 3) == true)
check("⚠ 混花色序列 K♠-Q♥-J♠ → 不可整组拿起", rules.canPickUp(c2, 1) == false)
check("⚠ 混花色序列，从第 2 张起 Q♥-J♠ 也不可", rules.canPickUp(c2, 2) == false)
check("混花色里的单张 J♠ → 仍可拿起",          rules.canPickUp(c2, 3) == true)
check("点数差 2（K-9）→ 不可拿起",             rules.canPickUp(c3, 1) == false)
check("点数差 2，从第 2 张起单张 → 可拿起",     rules.canPickUp(c3, 2) == true)
check("序列里夹着背面牌 → 不可拿起",           rules.canPickUp(c4, 1) == false)
check("起点是背面牌 → 不可拿起",               rules.canPickUp(c5, 1) == false)
check("起点是背面，其后单张翻开 → 可拿起",     rules.canPickUp(c5, 2) == true)
check("index 越界（0 / 超列长）→ false",       rules.canPickUp(c5, 0) == false
                                             and rules.canPickUp(c5, 99) == false)

-- ============================================================
-- 2. canDrop：能落在哪里
-- ============================================================
section("2. rules.canDrop —— 落点是否合法")

local empty  = {}
local tenH   = col({ { "H", 10, true } })
local tenDown = col({ { "H", 10, false } })

check("空列 → 任意牌都能放",                   rules.canDrop(empty, 13) == true)
check("⚠ 目标顶牌 H10，移动底牌 9♥（异色）→ 可以（单张不限花色）",
                                                rules.canDrop(tenH, 9) == true)
check("目标顶牌 H10，移动底牌 9♣（同色异花）→ 可以",
                                                rules.canDrop(tenH, 9) == true)
check("目标顶牌 H10，移动底牌 10 → 不行（必须大 1，不是大或等）",
                                                rules.canDrop(tenH, 10) == false)
check("目标顶牌 H10，移动底牌 8 → 不行（差 2）", rules.canDrop(tenH, 8) == false)
check("目标顶牌是背面 → 不行",                  rules.canDrop(tenDown, 9) == false)

-- ============================================================
-- 3. 命中检测：点在哪张牌上
-- ============================================================
section("3. layout.hitTestTableau —— 点击命中哪张牌")

local g3 = makeGame({
  { { "C", 5, false }, { "D", 4, false }, { "H", 3, false },
    { "S", 2, false }, { "C", 7, false }, { "S", 9, true } },      -- 5 背面 + 1 翻开
  {},                                                              -- 第 2 列空
})

local hitCol, hitIdx = layout.hitTestTableau(g3, pointOf(g3, 1, 1))
check("点最下面那张（只露 8px 缝）→ 命中第 1 张", hitCol == 1 and hitIdx == 1)

hitCol, hitIdx = layout.hitTestTableau(g3, pointOf(g3, 1, 4))
check("点中间那张 → 命中第 4 张", hitCol == 1 and hitIdx == 4)

hitCol, hitIdx = layout.hitTestTableau(g3, pointOf(g3, 1, 6))
check("点顶牌 → 命中第 6 张", hitCol == 1 and hitIdx == 6)

local px, py = pointOf(g3, 1, 1)
check("点在第 1 列左侧外面 → 不命中任何牌",
      layout.hitTestTableau(g3, px - const.CARD_W, py) == nil)
check("空列 → 不命中任何牌",
      layout.hitTestTableau(g3, emptyPointOf(2)) == nil)
check("空列的槽位能被 columnSlotAt 认出（用作落点）",
      layout.columnSlotAt(emptyPointOf(2)) == 2)

-- ============================================================
-- 4. 完整链路：选中 → 移动 → 自动翻牌 → 计分
-- ============================================================
section("4. 点击链路 —— 选中 + 合法移动 + 自动翻牌")

local g4 = makeGame({
  { { "C", 5, false }, { "S", 9, true }, { "S", 8, true } },      -- col1：移走后可翻牌
  { { "H", 10, true } },                                          -- col2：H10 接 S9（异色，合法）
})

local before = countCards(g4)

local msg = clickCard(g4, 1, 2)
check("点可移动的序列 → 选中 col1 第 2 张", g4.selected ~= nil
       and g4.selected.col == 1 and g4.selected.index == 2)
check("提示文字说明拿了 2 张（picked 2 cards）",
      string.find(msg or "", "picked 2 cards", 1, true) ~= nil)

msg = clickCard(g4, 2, 1)
check("点到 H10 上 → 移动成功",      string.find(msg or "", "moved 2 cards", 1, true) ~= nil)
check("源列只剩 1 张",               #g4.tableau[1] == 1)
check("目标列变成 3 张",             #g4.tableau[2] == 3)
check("移动后顺序保持（H10 → S9 → S8）",
      g4.tableau[2][1].rank == 10
      and g4.tableau[2][2].rank == 9 and g4.tableau[2][2].suit == "spades"
      and g4.tableau[2][3].rank == 8 and g4.tableau[2][3].suit == "spades")
check("移走后暴露的背面顶牌自动翻开", g4.tableau[1][1].faceUp == true)
check("选中态被清空",                 g4.selected == nil)
check("步数 = 1",                     g4.moves == 1)
check("分数 = 499（每移动 -1）",       g4.score == 499)
check("移动前后总牌数不变（104 张不丢不重）", countCards(g4) == before)

-- ============================================================
-- 5. 非法移动必须被拒绝
-- ============================================================
section("5. 非法移动 —— 必须原地不动")

local g5 = makeGame({
  { { "S", 7, true } },          -- col1：S7
  { { "H", 5, true } },          -- col2：H5 —— S7 接不上（需要 8）
})

clickCard(g5, 1, 1)
msg = clickCard(g5, 2, 1)
check("接不上的落点 → 不移动", #g5.tableau[1] == 1 and #g5.tableau[2] == 1)
check("提示说明需要 8（can't drop）", string.find(msg or "", "can't drop", 1, true) ~= nil)
check("失败不扣分不加步数",            g5.moves == 0 and g5.score == 500)
check("⚠ 失败后【保留】选中态（可以立刻换个落点重试）", g5.selected ~= nil
      and g5.selected.col == 1 and g5.selected.index == 1)
check("失败时记下被拒的列（给界面描红用）", g5.rejectCol == 2)

-- ============================================================
-- 5b. 落点带：点在目标列"牌下方的空白"也算落到那一列
--     （老版本这里会被判成"点空"→ 取消选中，用户以为"点了落点没反应"）
-- ============================================================
section("5b. 落点带 —— 牌下方空白也算落点")

local g5b = makeGame({
  { { "S", 7, true } },             -- col1：S7，要移到 col3
  {},                               -- col2 空
  { { "S", 8, true } },             -- col3：S8 能接 S7
})

-- 手工确认这个点不在任何牌身上，但在第 3 列的落点带里
local bx = const.colX(3) + const.CARD_W / 2
local by = 420                       -- 牌下方一大片空白
check("该点在牌身上命中不到（hitTestTableau = nil）",
      layout.hitTestTableau(g5b, bx, by) == nil)
check("该点落在第 3 列的落点带里（columnBandAt = 3）",
      layout.columnBandAt(bx, by) == 3)

clickCard(g5b, 1, 1)
msg = click(g5b, bx, by)
check("点空白落点 → S7 成功移到 col3", #g5b.tableau[1] == 0 and #g5b.tableau[3] == 2)
check("移动后清空选中", g5b.selected == nil)

-- 列缝里的点也要归到某一列（左右各外扩半个列间距）
check("两列之间的缝隙 → 归到前一列",
      layout.columnBandAt(const.colX(1) + const.CARD_W + const.COL_GAP / 2 - 1, 300) == 1)
check("落点带下界之外（牌库那一行）→ nil",
      layout.columnBandAt(bx, const.BOTTOM_Y) == nil)
check("落点带上界之外（HUD 里）→ nil",
      layout.columnBandAt(bx, const.HUD_H / 2) == nil)

-- ============================================================
-- 5c. 落点提示：能落到哪些列（界面靠它描边）
-- ============================================================
section("5c. game.legalTargets —— 能落到哪些列")

local g5c = makeGame({
  { { "S", 7, true } },             -- col1 选它
  {},                               -- col2 空（可落）
  { { "S", 8, true } },             -- col3 S8（可落）
  { { "H", 13, true } },            -- col4 K（不可落）
})

check("没选中时 → 空表", #game.legalTargets(g5c) == 0)
clickCard(g5c, 1, 1)
local tg = game.legalTargets(g5c)
local inTargets = {}
for _, j in ipairs(tg) do inTargets[j] = true end
check("S7 能落到第 3 列（S8 接得上）", inTargets[3] == true)
check("S7 能落到第 4 列以外的其它空列（空列随便放）",
      inTargets[2] == true and inTargets[5] == true and inTargets[10] == true)
check("⚠ 第 4 列顶牌是 K → 不是合法落点", inTargets[4] == nil)
check("不含自己所在的第 1 列", inTargets[1] == nil)
check("合法落点数 = 8（1 个空列 + 能接上的 S8 列 + 6 个空列）", #tg == 8)
check("legalTargets 与 canDrop 结论一致",
      rules.canDrop(g5c.tableau[3], 7) == true and rules.canDrop(g5c.tableau[4], 7) == false)

local info = game.selectionInfo(g5c)
check("selectionInfo 报出 1 张、底牌 S7",
      info ~= nil and info.count == 1 and info.card.rank == 7)

-- ============================================================
-- 6. 空列可以接收
-- ============================================================
section("6. 空列 —— 任何牌都能放")

local g6 = makeGame({
  { { "S", 7, true } },          -- col1
  {},                            -- col2 空
})

clickCard(g6, 1, 1)
msg = click(g6, emptyPointOf(2))
check("点空槽 → S7 移入空列", #g6.tableau[1] == 0 and #g6.tableau[2] == 1)
check("移入空列的是 S7",      g6.tableau[2][1].rank == 7 and g6.tableau[2][1].suit == "spades")
check("空列移动也计步数",     g6.moves == 1)

-- ============================================================
-- 7. 混花色序列点不动；但能退而选单张
-- ============================================================
section("7. 混花色序列 —— 点它不选中")

local g7 = makeGame({
  { { "S", 9, true }, { "H", 8, true } },     -- col1：混花色
})

msg = clickCard(g7, 1, 1)
check("点混花色的底牌 → 不选中", g7.selected == nil)
check("提示说明不是同花降序序列",
      string.find(msg or "", "same-suit", 1, true) ~= nil)

msg = clickCard(g7, 1, 2)
check("改点顶牌 H8（单张）→ 能选中", g7.selected ~= nil and g7.selected.index == 2)

-- ============================================================
-- 8. 取消 / 更换选择
-- ============================================================
section("8. 取消选择 与 同列换选")

local g8 = makeGame({
  { { "S", 13, true }, { "S", 12, true } },   -- col1：K♠-Q♠ 可整组拿起
  { { "S", 11, true } },                      -- col2
})

clickCard(g8, 1, 2)
check("点第 2 张 → 选中 Q♠", g8.selected ~= nil and g8.selected.index == 2)

local msg8 = clickCard(g8, 1, 2)
check("再点同一张 → 取消选中", g8.selected == nil)
check("提示为 deselected", string.find(msg8 or "", "deselected", 1, true) ~= nil)

msg8 = clickCard(g8, 1, 1)
check("同列改点第 1 张 → 换成选中 K♠-Q♠ 两张",
      g8.selected ~= nil and g8.selected.index == 1)
check("提示 picked 2 cards", string.find(msg8 or "", "picked 2 cards", 1, true) ~= nil)

-- 同列里点到"拿不起来"的那张 → 保留原选择（老版本会直接取消，手感很差）
local g8b = makeGame({
  { { "S", 13, false }, { "S", 12, true } },   -- col1：第 1 张背面、第 2 张 Q♠
})
clickCard(g8b, 1, 2)
check("先选中第 2 张 Q♠", g8b.selected ~= nil and g8b.selected.index == 2)
msg8 = clickCard(g8b, 1, 1)
check("同列点到背面牌 → 保留原选择", g8b.selected ~= nil and g8b.selected.index == 2)
check("提示 face-down", string.find(msg8 or "", "face-down", 1, true) ~= nil)

click(g8, 640, 700)
check("点空白处 → 取消选中", g8.selected == nil)
check("点空白处提示 deselected",
      string.find(g8.message or "", "deselected", 1, true) ~= nil)

-- 下一次点击要把上次的"被拒"标记清掉，否则界面会一直描红
local g8c = makeGame({
  { { "S", 7, true } },
  { { "H", 5, true } },              -- 接不上 → 被拒
})
clickCard(g8c, 1, 1)
clickCard(g8c, 2, 1)
check("非法落点后 rejectCol = 2", g8c.rejectCol == 2)
clickCard(g8c, 1, 1)
check("下一次点击清掉 rejectCol", g8c.rejectCol == nil)

-- ============================================================
-- 9. 点背面牌不会被选中
-- ============================================================
section("9. 背面牌 —— 不能拿")

local g9 = makeGame({
  { { "C", 5, false }, { "S", 9, true } },
})

msg = clickCard(g9, 1, 1)
check("点背面牌 → 不选中", g9.selected == nil)
check("提示 face-down", string.find(msg or "", "face-down", 1, true) ~= nil)

-- ============================================================
-- 10. 与真实发牌串联
-- ============================================================
section("10. 真实发牌（game.new）+ ASCII 快照")

math.randomseed(20261016)
local gN = game.new(2, math.random)

check("新局分数 = 500",       gN.score == 500)
check("新局步数 = 0",         gN.moves == 0)
check("新局无选中态",         gN.selected == nil)
check("新局总牌数 = 104",     countCards(gN) == 104)
check("新局 stock = 50",      #gN.stock == 50)

-- 不变量：刚发完牌时，每列的背面牌都不能被拿起
local anyPickableDown = false
for i = 1, 10 do
  for k = 1, #gN.tableau[i] - 1 do
    if rules.canPickUp(gN.tableau[i], k) then anyPickableDown = true end
  end
end
check("刚发牌时，所有背面牌都拿不起来", anyPickableDown == false)

-- 不变量：每列顶牌（翻开）都能单独拿起
local allTopPickable = true
for i = 1, 10 do
  if not rules.canPickUp(gN.tableau[i], #gN.tableau[i]) then allTopPickable = false end
end
check("每列顶牌都能拿起", allTopPickable)

local dumpText = game.dump(gN)
check("dump 输出 10 列", string.find(dumpText, "col  1", 1, true) ~= nil
                      and string.find(dumpText, "col 10", 1, true) ~= nil)
check("dump 里能看出背面牌标记 *", string.find(dumpText, "*", 1, true) ~= nil)
check("dump 里带 moves/score", string.find(dumpText, "moves=", 1, true) ~= nil)

print("")
print("--- game.dump 样例（难度 2 的真实发牌）---")
print(dumpText)

-- ============================================================
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then
  os.exit(1)
end
