-- src/render.lua —— 绘制层（只读数据，绝不修改游戏状态）
--
-- 本文件使用 love.graphics，只能被 LÖVE 加载；纯逻辑模块（card/deck）不得引用它。

local const  = require("const")
local card   = require("src.card")
local layout = require("src.layout")   -- 叠压坐标与命中检测共用同一套算法
local game   = require("src.game")     -- 只读：查"当前能落到哪些列"（game 不反向依赖 render）
local text   = require("src.text")     -- 界面文案集中处
local anim   = require("src.anim")     -- 动画偏移（M8，纯逻辑）

local M = {}

local fontTiny, fontSmall, fontBig

-- 字体只在 love.load 里建一次并复用（每帧 newFont 会内存泄漏）
function M.load()
  fontTiny  = love.graphics.newFont(const.FONT_PATH, const.FONT_TINY)
  fontSmall = love.graphics.newFont(const.FONT_PATH, const.FONT_SMALL)
  fontBig   = love.graphics.newFont(const.FONT_PATH, const.FONT_BIG)
end

-- 给 src/ui.lua 与 states/* 取字体用：ui 自己不去 newFont，免得重复建
function M.font(name)
  if name == "big" then return fontBig end
  if name == "tiny" then return fontTiny end
  return fontSmall
end

-- 【坑】love.graphics.setColor 只传 3 个参数时【不会】把 alpha 重置成 1！
-- 一旦某处设过半透明，后面所有绘制都会跟着变透明。
-- 所以统一在这里显式带上 alpha = 1；要半透明就用 setColorA。
local function setColor(c)
  love.graphics.setColor(c[1], c[2], c[3], 1)
end

local function setColorA(c, a)
  love.graphics.setColor(c[1], c[2], c[3], a)
end

-- 空槽（虚线感由浅色描边代替）
local function drawSlot(x, y, w, h, r)
  setColor(const.COLOR_SLOT_FILL)
  love.graphics.rectangle("fill", x, y, w, h, r, r)
  setColor(const.COLOR_SLOT_LINE)
  love.graphics.rectangle("line", x, y, w, h, r, r)
end

-- 牌正面：白底 + 边框 + 左上角 rank+suit + 中央大花色
--
-- compact = 这张牌大部分被下一张盖住（列里叠压）。
--   【为什么需要它】STEP_UP = 22，而 22px 的角标连字本身都放不下：
--   字印在 y+6，字高约 22 → 下半截正好被下一张牌切掉，"Q" 看起来像 "O"、
--   "J" 像 "l"、"4" 像 "A"。一列长牌看上去像印歪了。
--   所以叠压时只画一行 18px 的角标（墨迹落在 22px 之内），
--   中央大花色反正被完全盖住，直接不画 —— 顺带省掉 10×N 次绘制。
local function drawCardFace(c, x, y, compact)
  local w, h, r = const.CARD_W, const.CARD_H, const.CARD_R

  setColor(const.COLOR_CARD_FACE)
  love.graphics.rectangle("fill", x, y, w, h, r, r)
  setColor(const.COLOR_CARD_LINE)
  love.graphics.rectangle("line", x, y, w, h, r, r)

  local ink = card.isRed(c.suit) and const.COLOR_SUIT_RED or const.COLOR_SUIT_BLACK
  setColor(ink)

  local label = card.rankText(c.rank) .. card.suitGlyph(c.suit)

  if compact then
    love.graphics.setFont(fontTiny)
    love.graphics.print(label, x + 7, y + 2)
    return
  end

  -- 左上角：rank + 花色
  love.graphics.setFont(fontSmall)
  love.graphics.print(label, x + 8, y + 6)

  -- 中央：大花色
  love.graphics.setFont(fontBig)
  local g = card.suitGlyph(c.suit)
  local gw = fontBig:getWidth(g)
  local gh = fontBig:getHeight()
  love.graphics.print(g, x + (w - gw) / 2, y + (h - gh) / 2 + 4)
end

-- 牌背蜘蛛（M16）：纯线稿，只用 line + ellipse。
--
-- 【为什么不开 MSAA 也干净】LÖVE 11.5 默认 lineStyle = "smooth"，会在线两侧各补
-- 一圈 1 物理像素宽的 alpha 渐变裙边（Polyline.cpp 的 overdraw + fill_color_array）。
-- 这是几何级 AA，不依赖 multisample buffer，所以 conf.lua 里不用加 msaa。
--
-- 【为什么躯干要先填一遍底色】躯干只描边时，腿根会"插"在空心的身体里露出线头。
-- 用牌背底色（与底同色，画面结果仍是线稿、不可见）填一遍就能擦掉腿根与交叠弧线。
-- 顺序必须是 头胸(填+描) → 腹部(填+描)，腹部才会把头胸的下半弧裁成"腰"。
local function drawSpider(cx, cy, color)
  love.graphics.setLineWidth(const.CARD_BACK_ICON_W)
  setColor(color)

  for i = 1, #const.SPIDER_LEGS do
    local l = const.SPIDER_LEGS[i]
    love.graphics.line(cx + l[1], cy + l[2], cx + l[3], cy + l[4], cx + l[5], cy + l[6])
    love.graphics.line(cx - l[1], cy + l[2], cx - l[3], cy + l[4], cx - l[5], cy + l[6])
  end

  for i = 1, #const.SPIDER_BODY do
    local b = const.SPIDER_BODY[i]
    setColor(const.COLOR_CARD_BACK)                     -- 遮挡色：不可见，只用来擦线
    love.graphics.ellipse("fill", cx + b[1], cy + b[2], b[3], b[4])
    setColor(color)
    love.graphics.ellipse("line", cx + b[1], cy + b[2], b[3], b[4])
  end

  love.graphics.setLineWidth(1)   -- 【必须】否则下一张牌的内框会变成 1.8px
end

-- 层间暗缝：沿整张牌轮廓画一圈比底色暗的线。
--
-- 它读作【卡片的边】而不是「画上去的黑线」，因为 SHADE(0.175) 比牌背底色(0.25) 暗、
-- 却比桌面(0.13) 亮 —— 落在两者之间，眼睛自然把它归到「物体与物体之间的缝」。
--
-- 两个调用方：
--   stock（M17）   5 张同色牌向右错开 STOCK_STACK_DX，相邻两张之间零明度差，
--                  不画这条线就融成一整块 128px 宽的平板。
--   列里叠压（M18）每张只露 8px，露出的部分只剩顶边 + 左右各一个 1/4 圆弧 ——
--                  那两个圆弧是「卡片侧边」的唯一线索。
--
-- x/y 各 +0.5：让 1px 线正好压在一整行像素上，不跨两行各半（那会摊成 2px 淡线）。
local function drawBackOutline(x, y)
  love.graphics.setLineWidth(1)
  setColor(const.COLOR_CARD_BACK_SHADE)
  love.graphics.rectangle("line", x + 0.5, y + 0.5,
    const.CARD_W - 1, const.CARD_H - 1, const.CARD_R, const.CARD_R)
end

-- 牌背面：深色底 + 内框 + 蜘蛛；叠压时画「暗轮廓 + 亮切边」两层纸边
--
-- 三个模式，由调用方选：
--   inner=nil  + shade=true   stock 的每一张（整张露出，画内框 + 蜘蛛 + 层间暗缝）
--   inner=true               整张露出但没有叠压的场合（目前没有调用方，留着以防）
--   inner=false               列里叠压，只露 8px 顶边 → 暗轮廓 + 亮切边（M18）
--
-- 【坑】内框和蜘蛛只该画在【整张露出】的背面牌上。
-- 列里叠压时每张只露 8px（STEP_DOWN），而内框上边在 +7 —— 整条内框线会完整落进
-- 这条窄缝，5 张叠下来就变成一排高对比横线，正是 M16 记录的「脏条纹」事故。
-- 所以由调用方用 inner=false 关掉内框，改用下面那套低对比的双线。
local function drawCardBack(x, y, inner, shade)
  local w, h, r = const.CARD_W, const.CARD_H, const.CARD_R
  local inset    = const.CARD_BACK_INSET

  setColor(const.COLOR_CARD_BACK)
  love.graphics.rectangle("fill", x, y, w, h, r, r)

  if inner ~= false then
    setColor(const.COLOR_CARD_BACK_LINE)
    love.graphics.rectangle("line",
      x + inset, y + inset, w - inset * 2, h - inset * 2, r - 3, r - 3)
    drawSpider(x + w / 2, y + h / 2 + const.CARD_BACK_ICON_DY, const.COLOR_CARD_BACK_ICON)
  else
    -- 列里叠压（M18）：每张只露顶部 STEP_DOWN(8px)。靠【两条线】读作「一张纸」：
    --
    --   ① 暗轮廓  沿整张牌的外轮廓（SHADE 0.175）—— 露出的 8px 里只看得见顶边，
    --              但左右各带一个 1/4 圆弧，那就是「这张卡的边」。
    --   ② 亮切边  落在内框顶边（EDGE 0.31）—— 下一张牌正好压在它下沿，读作「纸的切面」。
    --
    -- 【为什么是两条】M16 只在 y+1.5 画一条 0.31 亮线 → 读作「平板上画了条线」；
    -- 只留暗线 → 读作「缝」但看不出纸的厚度。一暗一亮才成"厚度"。
    --
    -- 【为什么轮廓要走整张牌】左右两个 1/4 圆弧是「卡片侧边」的唯一线索，
    -- 少了它就只剩下几条平行横线。副作用也很好：圆角自动处理线头，
    -- 不用再手算 y+1.5 处的内缩量（那是老方案里最容易被改坏的数）。
    --
    -- ⚠ 对比度必须压住：暗 0.175/底 0.247（ΔL .072）、亮 0.31/0.247（ΔL .063）。
    --   M16 那次「脏条纹」事故用的是内框原色 0.45（ΔL .20）+ 完整 1px 横线。
    --   ΔL 在 .07 量级读作「纸的边界」，拉到 .2 就变成条纹。
    --
    -- ⚠ 切边必须缩到内框圆角之外（INSET + r - 3 = 12），否则线头会戳进内框的弧里。
    drawBackOutline(x, y)

    setColor(const.COLOR_CARD_BACK_EDGE)
    love.graphics.line(
      x + const.CARD_BACK_RIM_INSET,     y + const.CARD_BACK_RIM_DY,
      x + w - const.CARD_BACK_RIM_INSET, y + const.CARD_BACK_RIM_DY)
  end

  -- stock 的层间暗缝（M17）：只给 stock 传 shade=true。
  --
  -- 列里叠压走的是上面 inner=false 的分支，那里已经画过同一条轮廓线（M18），
  -- 再叠一遍没有意义。
  --
  -- 两个数值是互相咬合的：STOCK_STACK_DX(7) == CARD_BACK_INSET(7)，于是下层牌
  -- 的内框竖线正好落在露出条带的边界上，只露出自己的 AA 半边（0.345）——
  -- 正好当"纸的切边"用。DX 再大就会整条内框线露出来（双线框），再小则条带太窄。
  if shade then
    drawBackOutline(x, y)
  end

  setColor(const.COLOR_TEXT)   -- 复位，和本文件其它 draw* 的收尾惯例一致
end

-- 选中高亮：在整段牌【底下】垫一块浅灰底，四周露出 SELECT_PAD 像素 → 形成一圈亮边
-- 注意两点：
--   1) 不能改成"亮边描边"——牌面本身已是 0.95 白，白描边在白牌上根本看不见；
--   2) 外框要按【整段】画一块，而不是每张牌各画一块，否则碎片拼起来会很糊。
local function drawSelectHalo(x, yTop, yBottom, alpha)
  local p = const.SELECT_PAD
  setColorA(const.COLOR_SELECT, alpha or 1)
  love.graphics.rectangle("fill",
    x - p, yTop - p,
    const.CARD_W + p * 2, (yBottom - yTop) + p * 2,
    const.CARD_R + p, const.CARD_R + p)
end

-- 画一张牌（按 faceUp 分流）
--   full    这张牌是否整张露出（背面牌靠它决定画不画内框）
--   compact 正面牌是否被下一张盖住大半（只画小角标）
local function drawOne(c, x, y, full, compact)
  if c.faceUp then
    drawCardFace(c, x, y, compact)
  else
    drawCardBack(x, y, full)
  end
end

-- ===== 牌的实际绘制位置（M8）=====
--
-- 这是 render 里唯一允许"不按最终布局画"的地方，三件事按顺序叠加：
--   1. layout.cardY   → 最终位置（唯一真相）
--   2. 动画偏移        → 牌从哪滑过来的（开局发牌 / 补牌 / 移动）
--   3. 拖拽偏移        → 选中的那一段跟着鼠标走
--
-- 返回 nil 表示这张牌现在【不该出现】（开局发牌时还没轮到它）。
-- 命中检测完全不看这里 —— 点哪张牌永远以最终位置为准，不会因为牌在飞就点不准。
local function cardAt(ui, i, col, k)
  local x, y = const.colX(i), layout.cardY(col, k)

  local it = ui and ui.anim and ui.anim.items[1]
  local sh = anim.shiftFor(it, i, k)
  if sh then
    if sh.hide then return nil end
    x, y = x + sh.dx, y + sh.dy
  end

  local d = ui and ui.drag
  if d and d.col == i and k >= d.index then
    x, y = x + d.dx, y + d.dy
  end

  return x, y
end

-- 这一张能不能用「小角标」画？
--
-- 判据不是「它是不是列尾」，而是【下一张牌有没有紧贴在它下面】。
-- 只看索引是不够的：把上面几张拖走之后，原本被压住的那张其实整张露出来了，
-- 那时还按叠压画就会变成"一张大白卡上只有一行小字"，像坏掉了。
local function compactAt(ui, i, col, k)
  if k >= #col then return false end

  local _, y0 = cardAt(ui, i, col, k)
  local _, y1 = cardAt(ui, i, col, k + 1)
  if not y0 or not y1 then return false end       -- 下一张还没落地，别急着裁

  return math.abs((y1 - y0) - layout.stackStep(col[k])) < 0.5
end

-- 落点带的描边（选中时可落的列 / 被拒绝的列）
-- 画在牌【之前】，也就是压在牌下面，所以不会盖住牌面 —— 只露出四周一圈。
local function drawBandOutline(colIdx, color, alpha)
  local p = const.HINT_PAD
  setColorA(color, alpha)
  love.graphics.setLineWidth(3)
  love.graphics.rectangle("line",
    const.colX(colIdx) - p, const.BAND_TOP - p,
    const.CARD_W + p * 2, (const.BAND_BOTTOM - const.BAND_TOP) + p * 2,
    const.CARD_R + p, const.CARD_R + p)
  love.graphics.setLineWidth(1)
end

-- 选中一段牌之后，把「能落的列」全部描出来 —— 用户不用猜落点在哪。
function M.drawColumnHints(g)
  if not g then return end

  if g.selected then
    for _, j in ipairs(game.legalTargets(g)) do
      drawBandOutline(j, const.COLOR_TARGET, const.TARGET_ALPHA)
    end
  end

  if g.rejectCol then
    drawBandOutline(g.rejectCol, const.COLOR_REJECT, const.REJECT_ALPHA)
  end

  setColor(const.COLOR_TEXT)      -- 复位，免得半透明渗到后面的绘制
end

-- 10 列牌堆
function M.drawTableau(g, ui)
  local sel = g.selected

  for i, col in ipairs(g.tableau) do
    local selStart = (sel and sel.col == i) and sel.index or nil

    -- 1) 先画没被选中的那部分
    local stop = selStart and (selStart - 1) or #col
    for k = 1, stop do
      local x, y = cardAt(ui, i, col, k)
      -- 只有列尾那张是整张露出来的 → 其余用 compact 角标、背面不画内框
      if x then drawOne(col[k], x, y, k == #col, compactAt(ui, i, col, k)) end
    end

    -- 2) 选中段：先垫外框，再把牌盖上去（这样外框只露四周一圈）
    if selStart and selStart <= #col then
      local hx, yTop = cardAt(ui, i, col, selStart)
      local _, yLast = cardAt(ui, i, col, #col)
      if hx and yTop and yLast then
        drawSelectHalo(hx, yTop, yLast + const.CARD_H)
      end
      for k = selStart, #col do
        local x, y = cardAt(ui, i, col, k)
        if x then drawOne(col[k], x, y, k == #col, compactAt(ui, i, col, k)) end
      end
    end
  end
end

-- stock（牌库）：一轮 10 张，所以「叠几张」就等于「还能补几轮」（最多 5 张）
--
-- M4 起它还要表达三件事：
--   1. 还剩几轮（牌右下角的小数字）
--   2. 现在能不能补 —— 不能补（有空列 / 牌库已空）时整叠变灰
--   3. 鼠标悬停时可补描浅边、不可补描暗红（和落点提示同一套颜色语言）
local function drawStockOutline(color, alpha, extraW)
  local p = const.HINT_PAD
  setColorA(color, alpha)
  love.graphics.setLineWidth(3)
  love.graphics.rectangle("line",
    const.STOCK_X - p, const.STOCK_Y - p,
    const.STOCK_W + (extraW or 0) + p * 2, const.STOCK_H + p * 2,
    const.CARD_R + p, const.CARD_R + p)
  love.graphics.setLineWidth(1)
end

function M.drawStock(g, ui)
  local rounds   = game.dealsLeft(g)                     -- 50 张 → 5 轮
  local canDeal  = game.canDealFromStock(g)
  local hovered  = ui and ui.mouseX and layout.hitTestStock(ui.mouseX, ui.mouseY)

  local shown = math.min(rounds, const.STOCK_STACK_MAX)  -- 最多叠 5 张
  local stackW = (shown > 0) and (shown - 1) * const.STOCK_STACK_DX or 0
  for k = 1, shown do
    -- ⚠ 这里【必须】全部传 inner=nil（= 整张露出，画内框 + 蜘蛛）。
    -- 别为了省绘制把下层几张改成 inner=false —— 那会在窄缝里画出一排周期性的
    -- 横线，正是 drawCardBack 注释里记的"脏条纹"事故。
    drawCardBack(const.STOCK_X + (k - 1) * const.STOCK_STACK_DX, const.STOCK_Y, nil, true)
  end

  -- 不能补时「整叠变灰」。
  -- 【坑】不能给每张背面牌单独设 alpha —— 这 5 张是叠着画的，
  -- 半透明会一层层叠加：4 张 alpha 0.42 叠下来等效约 0.93，肉眼几乎看不出变灰。
  -- 正确做法是整叠画完之后，用【背景色】统一盖一层。
  if rounds > 0 and not canDeal then
    setColorA(const.COLOR_BG, 0.62)
    love.graphics.rectangle("fill", const.STOCK_X, const.STOCK_Y,
      const.STOCK_W + stackW, const.STOCK_H, const.CARD_R, const.CARD_R)
  end

  -- 剩余轮数（0 时牌库已空，空槽本身已经说明了，不再写 0）
  if rounds > 0 then
    love.graphics.setFont(fontSmall)
    local txt = tostring(rounds)
    local tw  = fontSmall:getWidth(txt)
    setColorA(const.COLOR_TEXT, canDeal and 1 or 0.45)
    love.graphics.print(txt,
      const.STOCK_X + const.STOCK_W - tw - 12,
      const.STOCK_Y + const.STOCK_H - fontSmall:getHeight() - 8)
  end

  if hovered then
    if canDeal then
      drawStockOutline(const.COLOR_TARGET, const.TARGET_ALPHA, stackW)
    else
      drawStockOutline(const.COLOR_REJECT, const.REJECT_ALPHA, stackW)
    end
  end

  setColor(const.COLOR_TEXT)                             -- 复位 alpha，别渗到后面的绘制
end

-- 完成区：每完成一组画一张该花色的 K（M5 起真正产生数据）
-- 按花色顺序填槽：先 ♠ 的几组，再 ♥ / ♦ / ♣ —— 槽位固定 8 个，收满即胜利。
--
-- M8：正在飞向某个槽的牌，那一槽【先不画】。
-- 不然会看到"槽里已经出现一张 K，而 13 张牌还在天上飞"——等于提前剧透。
function M.drawFoundations(g, ui)
  local inflight = {}
  if ui and ui.anim then
    for _, it in ipairs(ui.anim.items) do
      if it.kind == "collect" and it.slot then inflight[it.slot] = true end
    end
  end

  local idx = 0
  for _, suit in ipairs(card.SUITS) do
    for _ = 1, (g.foundations[suit] or 0) do
      idx = idx + 1
      if idx > const.FOUND_COUNT then return end

      if not inflight[idx] then
        local x, y = const.foundSlotX(idx), const.FOUND_Y
        local w, h = const.FOUND_W, const.FOUND_H

        setColor(const.COLOR_CARD_FACE)
        love.graphics.rectangle("fill", x, y, w, h, 6, 6)
        setColor(const.COLOR_CARD_LINE)
        love.graphics.rectangle("line", x, y, w, h, 6, 6)

        setColor(card.isRed(suit) and const.COLOR_SUIT_RED or const.COLOR_SUIT_BLACK)
        love.graphics.setFont(fontSmall)
        love.graphics.print("K" .. card.suitGlyph(suit), x + 9, y + h / 2 - 12)
      end
    end
  end
end

-- 收组动画（M8）：13 张牌从列尾飞进 foundation 槽，同时缩小、叠压间距收到 0。
--
-- 这里画的是【副本】：牌早就从 g.tableau 里删掉了，所以牌面数据是 collect 事件
-- 自己带过来的。缩放到 0.6（= 60/100）后正好和 foundation 槽一样大，
-- 落点也精确对准槽位，所以动画结束、真实槽牌接手的瞬间看不出接缝。
function M.drawCollectAnim(ui)
  local q = ui and ui.anim
  if not q then return end

  local it = q.items[1]
  if not it or it.kind ~= "collect" then return end

  local p    = anim.collectProgress(it)
  local step = anim.lerp(it.step0, it.step1, p)
  local s    = anim.lerp(1, it.s, p)
  local x    = anim.lerp(it.x0, it.x1, p)
  local y    = anim.lerp(it.y0, it.y1, p)

  -- 倒着画：K 最后画 → 压在最上面。收进 foundation 后代表这一组的就是 K。
  for j = #it.cards, 1, -1 do
    love.graphics.push()
      love.graphics.translate(x, y + (j - 1) * step)
      love.graphics.scale(s, s)
      drawCardFace(it.cards[j], 0, 0)
    love.graphics.pop()
  end

  setColor(const.COLOR_TEXT)
end

-- 撤销按钮（M7）：放在底部空白区，与 foundation 槽共用同一条视觉基线（垂直居中）
--
-- 三种状态沿用菜单按钮的语言：
--   可用   深底 + 中灰描边 + 浅灰字
--   悬停   浅底 + 深字（反色，和 src/ui.lua 的按钮一致）
--   不可用 底色比空槽还暗一档、字灰掉 —— 让玩家一眼看出"现在没得撤"
function M.drawUndoButton(g, ui)
  local can = game.canUndo(g)
  local hot = can and ui and ui.mouseX and layout.hitTestUndo(ui.mouseX, ui.mouseY)

  local x, y, w, h = const.UNDO_X, const.UNDO_Y, const.UNDO_W, const.UNDO_H
  local r = 10

  if hot then
    setColor(const.COLOR_SELECT)
  elseif can then
    setColor(const.COLOR_HUD)
  else
    setColor(const.COLOR_SLOT_FILL)
  end
  love.graphics.rectangle("fill", x, y, w, h, r, r)

  if hot then
    setColor(const.COLOR_SELECT)
  elseif can then
    setColor(const.COLOR_SLOT_LINE)
  else
    setColorA(const.COLOR_SLOT_LINE, 0.45)
  end
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x, y, w, h, r, r)
  love.graphics.setLineWidth(1)

  love.graphics.setFont(fontSmall)
  local label = text.undo
  local th    = fontSmall:getHeight()

  if hot then
    setColor(const.COLOR_BG)                 -- 浅底上用深字
  elseif can then
    setColor(const.COLOR_TEXT)
  else
    setColorA(const.COLOR_TEXT_DIM, 0.55)
  end
  love.graphics.print(label,
    x + (w - fontSmall:getWidth(label)) / 2,
    y + (h - th) / 2)

  -- 右侧一个小小的键位提示（Z）。Ctrl+Z 同样有效，这里只写最短的那个。
  -- 垂直居中而不是贴右下角：贴角会看着像掉出来的一颗字。
  love.graphics.setFont(fontTiny)
  setColorA(hot and const.COLOR_BG or const.COLOR_TEXT_DIM, hot and 0.75 or 0.7)
  love.graphics.print(text.undo_key,
    x + w - 16 - fontTiny:getWidth(text.undo_key),
    y + (h - fontTiny:getHeight()) / 2)

  setColor(const.COLOR_TEXT)                 -- 复位 alpha/颜色，别渗到后面的绘制
end

-- 提示按钮（M9）：只在 settings.hintMode == "button" 时画，排在 Undo 右边
--
-- 没有"不可用"态：即使已经无路可走，这个按钮也有活干 —— 它会指你去点 Undo。
function M.drawHintButton(g, ui)
  local hot = ui and ui.mouseX and layout.hitTestHint(ui.mouseX, ui.mouseY)

  local x, y, w, h = const.HINT_X, const.HINT_Y, const.HINT_W, const.HINT_H
  local r = 10

  setColor(hot and const.COLOR_SELECT or const.COLOR_HUD)
  love.graphics.rectangle("fill", x, y, w, h, r, r)

  setColor(hot and const.COLOR_SELECT or const.COLOR_SLOT_LINE)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x, y, w, h, r, r)
  love.graphics.setLineWidth(1)

  love.graphics.setFont(fontSmall)
  local label = text.hint_button
  setColor(hot and const.COLOR_BG or const.COLOR_TEXT)
  love.graphics.print(label,
    x + (w - fontSmall:getWidth(label)) / 2,
    y + (h - fontSmall:getHeight()) / 2)

  -- 右侧键位提示，和 Undo 按钮上的 Z 对齐同一套做法
  love.graphics.setFont(fontTiny)
  setColorA(hot and const.COLOR_BG or const.COLOR_TEXT_DIM, hot and 0.75 or 0.7)
  love.graphics.print(text.hint_key,
    x + w - 16 - fontTiny:getWidth(text.hint_key),
    y + (h - fontTiny:getHeight()) / 2)

  setColor(const.COLOR_TEXT)
end

-- 提示高亮（M9）：告诉玩家"这一步可以走"
--
-- 画在【牌之前】，所以源段那块浅垫子只露出四周一圈 —— 和选中高亮同一个理由。
-- 三种答案对应三种画法：
--   move  源段垫一块浅色 + 目标列描边
--   stock 描一下牌库（"能补牌"就是这个意思）
--   undo  描一下 Undo 按钮（"没路了，只能撤"）
function M.drawHintOverlay(g, ui)
  local hint = ui and ui.hint
  if not hint then return end

  local a = (ui.hintAlpha or 1)

  if hint.kind == "move" then
    local m   = hint.move
    local src = g.tableau[m.from]
    if not src or not src[m.index] then return end

    drawSelectHalo(const.colX(m.from),
      layout.cardY(src, m.index),
      layout.cardY(src, #src) + const.CARD_H,
      a)
    drawBandOutline(m.to, const.COLOR_TARGET, 0.55 * a)

  elseif hint.kind == "stock" then
    drawStockOutline(const.COLOR_TARGET, 0.55 * a)

  elseif hint.kind == "undo" then
    local p = 6
    setColorA(const.COLOR_TARGET, 0.55 * a)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line",
      const.UNDO_X - p, const.UNDO_Y - p,
      const.UNDO_W + p * 2, const.UNDO_H + p * 2, 16, 16)
    love.graphics.setLineWidth(1)
  end

  setColor(const.COLOR_TEXT)      -- 复位，免得半透明渗到后面的绘制
end

-- 底部提示条（M9）：auto 模式下无路可走时【替代】上一步的 message
--
-- 为什么直接替换而不是挤成两行：MSG_Y 到屏幕底部只剩 ~44px，放不下两行；
-- 而一旦进入"只能补牌 / 彻底没路"，上一步走了什么已经不重要了。
function M.drawNotice(notice)
  love.graphics.setFont(fontSmall)
  local s = notice.text
  local w = fontSmall:getWidth(s)
  local h = fontSmall:getHeight()
  local x = (const.VW - w) / 2
  local y = const.MSG_Y

  setColorA(const.COLOR_BG, 0.88)
  love.graphics.rectangle("fill", x - 16, y - 6, w + 32, h + 12, 9, 9)

  -- stuck 用功能色描边并轻微呼吸（这是个"要你动手"的信号）；
  -- stall 也用暖色，但呼吸更浅更慢 —— 它是"没新信息了"，不是"没路了"；
  -- deal 只是提示还能做什么，安静地描一道灰边就够。
  if notice.kind == "stuck" then
    local k = 0.55 + 0.28 * math.sin((notice.clock or 0) * 2.2)
    setColorA(const.COLOR_REJECT, k)
  elseif notice.kind == "stall" then
    local k = 0.50 + 0.14 * math.sin((notice.clock or 0) * 1.5)
    setColorA(const.COLOR_REJECT, k)
  else
    setColor(const.COLOR_SLOT_LINE)
  end
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x - 16, y - 6, w + 32, h + 12, 9, 9)
  love.graphics.setLineWidth(1)

  setColor(const.COLOR_TEXT)
  love.graphics.print(s, x, y)
  setColor(const.COLOR_TEXT)
end

-- 认输按钮（M10）：HUD 右上角一个小小的描边按钮
--
-- 常态刻意做得【很轻】（只有一圈细边 + 灰字）：这是个低频、且带破坏性的操作，
-- 不该和 Undo 那样每步都会看的按钮抢视线。悬停时才反色亮起来。
function M.drawResignButton(ui)
  local x, y, w, h = const.RESIGN_X, const.RESIGN_Y, const.RESIGN_W, const.RESIGN_H
  local hot = ui and ui.mouseX and layout.hitTestResign(ui.mouseX, ui.mouseY)

  love.graphics.setFont(fontTiny)
  local label = text.resign
  local tw, th = fontTiny:getWidth(label), fontTiny:getHeight()

  if hot then
    setColor(const.COLOR_SELECT)
    love.graphics.rectangle("fill", x, y, w, h, 7, 7)
    setColor(const.COLOR_BG)                 -- 浅底上用深字
  else
    setColorA(const.COLOR_SLOT_LINE, 0.75)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x, y, w, h, 7, 7)
    setColor(const.COLOR_TEXT_DIM)
  end

  love.graphics.print(label, x + (w - tw) / 2, y + (h - th) / 2)

  setColor(const.COLOR_TEXT)                 -- 复位，别渗到后面的绘制
end

-- HUD 顶栏文字
-- 文案在 src/text.lua（当前是英文：DejaVu Sans 不含 CJK，换中文要换字体）。
function M.drawHUD(g, ui)
  love.graphics.setFont(fontSmall)
  local ty = (const.HUD_H - fontSmall:getHeight()) / 2

  setColor(const.COLOR_TEXT)
  love.graphics.print(text.title, 20, ty)

  if g then
    setColor(const.COLOR_TEXT_DIM)
    love.graphics.print(string.format(text.hud,
      text.suitCount(g.difficulty), game.foundationTotal(g), const.FOUND_COUNT,
      #g.stock, text.dealCount(game.dealsLeft(g)), g.moves or 0, g.score or 0), 300, ty)

    -- 右下角提醒回菜单的键位（M6 起 Esc 不再直接退出游戏）
    love.graphics.setFont(fontTiny)
    local hint = text.hud_menu_hint
    love.graphics.print(hint,
      const.VW - 20 - fontTiny:getWidth(hint),
      (const.HUD_H - fontTiny:getHeight()) / 2 + 2)
  end

  -- 认输按钮（M10）：只有 playing 传了 ui.showResign 才画 ——
  -- won / resign 这两屏也会把牌桌当背景画一遍，那时它不该出现。
  if g and ui and ui.showResign then
    M.drawResignButton(ui)
  end
end

-- 底部提示条：显示上一步的结果（"moved 3 cards ..."）
-- 还是英文——原因同上（字体缺 CJK 字形）。
function M.drawMessage(g)
  if not g or not g.message or g.message == "" then return end

  love.graphics.setFont(fontSmall)
  local text = g.message
  local w    = fontSmall:getWidth(text)
  local h    = fontSmall:getHeight()
  local x    = (const.VW - w) / 2
  local y    = const.MSG_Y

  -- 垫一块半透明底：这条提示是"为什么不能放"的唯一说明，必须看得清
  setColorA(const.COLOR_BG, 0.78)
  love.graphics.rectangle("fill", x - 14, y - 5, w + 28, h + 10, 8, 8)

  -- 落点被拒时用暖色，其它提示用普通文字色
  if g.rejectCol then setColor(const.COLOR_REJECT) else setColor(const.COLOR_TEXT) end
  love.graphics.print(text, x, y)
  setColor(const.COLOR_TEXT)
end

-- ===== 调试浮层（F1 开关）=====
-- "点了没反应"时最需要它：直接打在屏幕上的窗口尺寸 / 缩放 / 鼠标虚拟坐标 /
-- 光标下是哪张牌 / 选中态 / 合法落点，一眼就能看出是坐标偏了还是规则拒了。
local debugLines = nil

function M.setDebug(lines)
  debugLines = lines
end

local function drawDebug()
  if not debugLines or #debugLines == 0 then return end

  love.graphics.setFont(fontSmall)
  local lh = fontSmall:getHeight()
  local wmax = 0
  for _, s in ipairs(debugLines) do
    local w = fontSmall:getWidth(s)
    if w > wmax then wmax = w end
  end

  local x, y = 16, const.HUD_H + 10
  setColorA(const.COLOR_BG, 0.88)
  love.graphics.rectangle("fill", x - 8, y - 6, wmax + 16, lh * #debugLines + 12, 8, 8)
  setColor(const.COLOR_TEXT)
  for i, s in ipairs(debugLines) do
    love.graphics.print(s, x, y + (i - 1) * lh)
  end
end

-- 总入口：底衬空槽 -> 落点提示 -> 牌 -> HUD
-- ui 可选（调试脚本/测试可以不传）：{ mouseX = 虚拟坐标 x, mouseY = y }
function M.draw(g, ui)
  setColor(const.COLOR_HUD)
  love.graphics.rectangle("fill", 0, 0, const.VW, const.HUD_H)

  for i = 1, const.COLS do
    drawSlot(const.colX(i), const.TABLEAU_Y, const.CARD_W, const.CARD_H, const.CARD_R)
  end
  drawSlot(const.STOCK_X, const.STOCK_Y, const.STOCK_W, const.STOCK_H, const.CARD_R)
  for i = 1, const.FOUND_COUNT do
    drawSlot(const.foundSlotX(i), const.FOUND_Y, const.FOUND_W, const.FOUND_H, 6)
  end

  if g then
    M.drawColumnHints(g)     -- 压在牌下面，只露四周一圈
    M.drawHintOverlay(g, ui) -- M9：提示高亮也垫在牌下面（源段那块浅底要压在牌下）
    M.drawTableau(g, ui)
    M.drawStock(g, ui)
    M.drawFoundations(g, ui)
    M.drawUndoButton(g, ui)  -- M7
    if ui and ui.hintMode == "button" then
      M.drawHintButton(g, ui)  -- M9：只在 button 模式下出现
    end
    M.drawCollectAnim(ui)    -- M8：收组的 13 张副本，压在牌桌之上
  end

  -- 顶栏底再盖一层（M8）：开局发牌的牌是从屏幕上方落下来的，会短暂经过顶栏。
  -- 不重盖的话牌会画在 HUD 上面，看起来像浮在界面之上；再盖一层就成了"从顶栏后面落下"。
  -- 牌列最低从 TABLEAU_Y(90) 起，所以这一层盖不到任何一张静止的牌。
  setColor(const.COLOR_HUD)
  love.graphics.rectangle("fill", 0, 0, const.VW, const.HUD_H)

  M.drawHUD(g, ui)
  if ui and ui.notice then
    M.drawNotice(ui.notice)  -- M9：无路可走时替代 message
  else
    M.drawMessage(g)
  end
  drawDebug()
end

return M
