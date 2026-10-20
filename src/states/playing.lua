-- src/states/playing.lua —— 游戏中这一屏：输入 → game/rules → render
--
-- 原先这一坨逻辑直接在 main.lua 里（M3–M5）。M6 引入状态机后搬到这里，
-- main.lua 只负责窗口、缩放、把事件转发给状态机。
--
-- 键盘：
--   Esc  有选中 → 取消选中；没有选中 → 回主菜单
--   Z    撤销（Ctrl+Z 也走这里；底部还有个可点的 Undo 按钮）
--   H    要一次提示（两种模式都有效；button 模式下底部也有个 Hint 按钮）
--   R    重新发牌（调试用）      D 终端打印牌桌      F1 调试浮层
--
-- 鼠标：
--   点一下牌 = 选中，再点落点 = 放下（老手感，一直保留）
--   按住牌拖走 = 这一段牌跟着鼠标飞，松手落在哪一列就放哪一列（M8）

local const  = require("const")
local anim   = require("src.anim")
local card   = require("src.card")
local dev    = require("src.dev")          -- M13：只在 ctx.dev 为真时用到
local game   = require("src.game")
local hint   = require("src.hint")
local layout  = require("src.layout")
local persist = require("src.persist")
local render  = require("src.render")
local text   = require("src.text")

local M = {}

-- 胜利后稍等一会儿再切到结算屏：让玩家看清最后那一组被收走
local WIN_DELAY = 0.8

-- ===== 发牌的唯一入口（M12）=====
--
-- 以前 game.new 在两个地方各调一次，随机源是 ctx.rng（LÖVE 的全局生成器）。
-- 全局生成器只前进不回退，所以"同一个种子发回同一副牌"根本无从谈起。
--
-- 现在统一走这里：种子 -> 一个独立的生成器 -> 一副牌。谁想开局都只能走这条路，
-- 否则同种子复现就不成立了。
local function newDeal(ctx, seed)
  local sd = seed
  if sd == nil then sd = ctx.makeSeed() end

  local g = game.new(ctx.settings.difficulty, ctx.newRng(sd), sd)
  ctx.lastSeed     = sd            -- 菜单 / 种子屏要显示"上一局的种子"
  ctx.lastSeedDiff = g.difficulty
  return g
end

function M.new(ctx)
  local s = {
    ctx       = ctx,
    g         = nil,
    press     = nil,        -- { col = n } 鼠标按下时在哪一列（支持拖拽落点）
    drag      = nil,        -- M8：正在拖的那一段（见 mousepressed）
    anim      = anim.queue(),
    showDebug = false,
    winTimer  = 0,

    hint      = nil,        -- M9 button 模式：{ kind = "move"|"stock"|"undo", move, t }
    hintKind  = "moves",    -- M9 auto 模式：当前三档状态 moves / deal / stuck
    hintDirty = true,       -- 牌桌变过 → 等动画播完就重算一次
    clock     = 0,          -- 累计时间，给提示条的描边呼吸用

    -- M14：连按 H 在候选之间循环。这四项必须一起失效。
    hintList      = nil,    -- 当前牌桌的全部候选（hint.findMoves 的结果）
    hintIndex     = 0,      -- 0 = 还没开始；1..#hintList 是正在显示第几个
    hintListDirty = true,   -- 牌桌【真的】变了 → 下次按 H 重算并回到第 1 个
    hintListGame  = nil,    -- 这份列表属于哪个 g（防直接换 g 造成的串台）
  }

  -- F1 浮层内容（每帧重算）
  local function buildDebug(vx, vy)
    if not s.showDebug or not s.g then
      render.setDebug(nil)
      return
    end

    local g = s.g
    local lines = {
      string.format("virtual mouse (%.1f, %.1f)   state = playing", vx, vy),
    }

    local col, k = layout.hitTestTableau(g, vx, vy)
    if col then
      lines[#lines + 1] = string.format("cursor on: col %d card %d of %d  (%s)",
        col, k, #g.tableau[col], card.label(g.tableau[col][k]))
    elseif layout.hitTestStock(vx, vy) then
      lines[#lines + 1] = "cursor on: stock (click to deal a round)"
    else
      local band = layout.columnBandAt(vx, vy)
      lines[#lines + 1] = band
        and string.format("cursor on: empty area of col %d (still a valid drop target)", band)
        or  "cursor on: outside the tableau"
    end

    local canDeal, why = game.canDealFromStock(g)
    lines[#lines + 1] = string.format("stock: %d card(s), %d deal(s) left, dealable=%s%s",
      #g.stock, game.dealsLeft(g),
      canDeal and "yes" or "no",
      canDeal and "" or ("  (" .. why .. ")"))

    lines[#lines + 1] = string.format("foundations: %d/%d  (S%d H%d D%d C%d)   won=%s",
      game.foundationTotal(g), const.FOUND_COUNT,
      g.foundations.spades, g.foundations.hearts,
      g.foundations.diamonds, g.foundations.clubs,
      game.isWon(g) and "YES" or "no")

    lines[#lines + 1] = string.format("undo: %d step(s) in history, canUndo=%s   (Z / ctrl+Z / button)",
      game.undoDepth(g), game.canUndo(g) and "yes" or "no")

    local head = anim.active(s.anim)
    lines[#lines + 1] = string.format("anim: %s   input %s",
      head and string.format("%s %.2f/%.2f", head.kind, head.t, head.total or head.dur) or "(idle)",
      anim.busy(s.anim) and "BLOCKED" or "ready")

    -- M9：提示方式与当前判定结果（不论哪种模式都算一次，方便对比）
    local hs, hm = hint.status(g)
    lines[#lines + 1] = string.format("hint(%s): %s%s", s:mode(), hs,
      hm and string.format("  col %d card %d -> col %d", hm.from, hm.index, hm.to) or "")

    local info = game.selectionInfo(g)
    if info then
      local tg = game.legalTargets(g)
      lines[#lines + 1] = string.format("selected: col %d card %d  (%d card(s), %s)   legal: %s",
        info.col, info.index, info.count, card.label(info.card),
        #tg > 0 and table.concat(tg, ", ") or "(none)")
    else
      lines[#lines + 1] = "selected: (none)"
    end

    if g.rejectCol then
      lines[#lines + 1] = "rejected drop target: col " .. g.rejectCol
    end
    lines[#lines + 1] = "last message: " .. (g.message ~= "" and g.message or "-")

    render.setDebug(lines)
  end

  -- opts.resume（M10）：从认输面板回来。牌局必须原样保留 ——
  -- 选 "Restart this deal" 时 game.restart 已经把 g 就地重置过了，
  -- 这里要是再 game.new 一次，玩家选的那个选项就白选了。
  function s:enter(opts)
    self.anim      = anim.queue()     -- 换局时把上一局的动画全部丢掉
    self.press     = nil
    self.drag      = nil
    self.winTimer  = 0
    self.hint      = nil
    self.hintKind  = "moves"
    self.hintDirty = true
    self:invalidateHintList()

    if not (opts and opts.resume) or not self.g then
      -- opts.seed：从种子屏进来时带着一个指定种子；否则现抽一个
      self.g = newDeal(self.ctx, opts and opts.seed)
      -- 新的一局：允许记一次结果（赢 / 认输各一次）
      self.resultRecorded = false
      self.winBest, self.winIsNew = nil, nil
      self.devWin = nil          -- 调试假的结算数据不能漏到下一局
    end

    print(string.format("[state] playing (difficulty=%d, stock=%d, hints=%s)",
      self.ctx.settings.difficulty, #self.g.stock, self.ctx.settings.hintMode or "auto"))
  end

  -- ===== 提示（M9）=====
  --
  -- 两种模式共用 hint.findMove / hint.status，差别只在"什么时候把答案给出去"：
  --   auto   每次牌桌变化后自己算，无路可走时底部出提示条
  --   button 不算（除 F1 调试），等玩家按 H 或点 Hint 按钮

  function s:mode()
    return self.ctx.settings.hintMode or "auto"
  end

  -- 牌桌真的变了：候选列表作废，下一次按 H 从第 1 个重新开始。
  --
  -- ⚠ 不要复用 hintDirty 当这个判据。mousepressed 对【每一次】左键都把它置 true
  --   （包括只是选中一张牌、点空白处），button 模式下第一次按 H 清成 false 之后，
  --   随便点一下又会把它打回 true —— 循环就永远停在第一个。
  function s:invalidateHintList()
    self.hintList      = nil
    self.hintIndex     = 0
    self.hintListGame  = nil
    self.hintListDirty = true
  end

  -- 一步操作之后调用：只有 moves 真的动了才作废。
  -- 单纯"选中 / 取消选中"不算牌桌变化，不该把循环打回第 1 个。
  --
  -- ⚠ 反过来不成立：moves 相同 ≠ 牌桌相同（undo 会把 moves 恢复成快照值），
  --   所以这个比较只能判断"刚才这一步有没有动牌"，绝不能当缓存键/版本号。
  function s:afterBoardOp(movesBefore)
    if self.g and self.g.moves ~= movesBefore then
      self.hint = nil                 -- 旧高亮指向的牌可能已经不在原位了
      self:invalidateHintList()
    end
  end

  -- 主动要一次提示：高亮答案，什么都不改牌局。
  -- 连按时在候选之间循环：牌桌没变就前进一个，转完一圈回到第一个。
  function s:requestHint()
    local g = self.g
    if not g then return end

    -- 先取消选中：否则"选中外框"和"提示外框"两套高亮会叠在一起，看不出哪是哪
    game.deselect(g)
    self.drag = nil

    -- ① 只在牌桌真的变过（或换了 g）时重算。这一行就是
    --    "连按前进"和"牌桌一变回到第 1 个"的分界线。
    if self.hintListDirty or not self.hintList or self.hintListGame ~= g then
      self.hintList      = hint.findMoves(g)
      self.hintListGame  = g
      self.hintListDirty = false
      self.hintIndex     = 0
    end

    local list  = self.hintList
    local total = #list
    local status = hint.status(g, list)   -- 传表，避免重复扫描

    if total > 0 then
      -- ⚠ 必须先判 total > 0 再取模：0 % 0 在 Lua 里是运行时错误。
      --   列表为空时走下面的 stock / undo 分支。
      local i = self.hintIndex % total + 1
      self.hintIndex = i
      local m = list[i]
      self.hint = { kind = "move", move = m, t = 0, index = i, total = total }
      print(string.format("[hint] %d/%d  move col %d card %d -> col %d (%d card(s))",
        i, total, m.from, m.index, m.to, m.count))
    elseif status == "deal" then
      self.hint = { kind = "stock", t = 0, index = 0, total = 0 }
      print("[hint] no card moves - deal a round from the stock")
    else
      self.hint = { kind = "undo", t = 0, index = 0, total = 0 }
      print("[hint] no moves and no deals - undo is the way out")
    end
  end

  -- 高亮淡出：前 HOLD-FADE 秒全亮，最后 FADE 秒线性收到 0
  function s:hintAlpha()
    local h = self.hint
    if not h then return 1 end
    local left = const.HINT_HOLD - h.t
    if left >= const.HINT_FADE then return 1 end
    return math.max(0, left / const.HINT_FADE)
  end

  -- 底部提示条要说什么（nil = 照常显示上一步的 message）
  function s:notice()
    local g = self.g
    if not g or game.isWon(g) then return nil end

    -- 手上还拿着牌时不弹：选中外框 + 落点描边已经在表达信息了，
    -- 再叠一句"无路可走"是自相矛盾的噪音。
    if g.selected then return nil end

    -- 玩家刚按过 H：这是对"直接提问"的回答，优先级高于 auto 的常驻提示。
    -- 只在还有别的候选时显示计数 —— 1 / 1 对玩家没有信息量，
    -- 按第二下发现"没变化"比看一行字更直接。
    local h = self.hint
    if h and h.kind == "move" and (h.total or 0) > 1 then
      return { kind = "hint", text = string.format(text.hint_count, h.index, h.total) }
    end

    if self:mode() == "auto" then
      if self.hintKind == "deal" then
        return { kind = "deal", text = string.format(text.notice_deal, game.dealsLeft(g)) }
      elseif self.hintKind == "stall" then
        -- stall：还能走，但一手都翻不了新牌 —— 也就是不会再有任何新信息进来。
        return { kind = "stall", text = text.notice_stall, clock = self.clock }
      elseif self.hintKind == "stuck" then
        return { kind = "stuck", text = text.notice_stuck, clock = self.clock }
      end
      return nil
    end

    -- button 模式平时什么都不弹；只有"问了一句、答案是撤销"时才短暂说那句话
    if self.hint and self.hint.kind == "undo" then
      return { kind = "stuck", text = text.notice_stuck }
    end
    return nil
  end

  function s:update(dt)
    if not self.g then return end

    self.clock = self.clock + dt

    -- 提示高亮会自己过期（M9）
    if self.hint then
      self.hint.t = self.hint.t + dt
      if self.hint.t >= const.HINT_HOLD then self.hint = nil end
    end

    -- 把 game 层刚产生的事件搬进动画队列（M8）。
    -- game 只管"记下发生了什么"，什么时候演、演多久全在这里决定。
    if self.g.events then
      for _, e in ipairs(self.g.events) do
        anim.push(self.anim, e)
      end
      self.g.events = {}
    end
    anim.update(self.anim, dt)

    -- M9 auto 模式：牌桌变了就重算一次。
    -- ⚠ 要等动画播完再算 —— 逻辑上牌桌在移动瞬间就定型了，但 13 张牌还在飞的时候
    -- 就弹出"无路可走"，看起来像游戏提前宣布你输了。
    if self:mode() == "auto" and self.hintDirty
       and not anim.busy(self.anim) and not game.isWon(self.g) then
      self.hintKind  = hint.status(self.g)
      self.hintDirty = false
    end

    -- 胜利判定放在 update 而不是 tryMove 里：
    -- 这样不管账是"移动收组"还是"补牌收组"还是"外部改了 foundations"，都能被捕捉到。
    --
    -- M8：收组动画还在播的时候不开始倒数。玩家正看着 13 张牌飞进 foundation，
    -- 0.8 秒的等待应该从【动画结束】算起，否则最后一组还没落槽就切屏了。
    if game.isWon(self.g) then
      -- 赢的那一刻就记账，不等 0.8 秒的展示延迟。
      -- 否则玩家在这段时间里按 Esc 回菜单，这一局赢了却什么都不记。
      self:recordWin()

      if not anim.collecting(self.anim) then
        self.winTimer = self.winTimer + dt
        if self.winTimer >= WIN_DELAY then
          -- 切状态之前把摘要拼好：切过去之后 self 就不在 playing 里了。
          self.ctx.sm:set("won", self:winSummary())
        end
      end
    else
      self.winTimer = 0
    end
  end

  -- 拼结算摘要。update 的 0.8s 到点、以及 dev 的 J 键都走这里 ——
  -- 字段只写一遍，不会出现"两条路径字段慢慢漂"。
  function s:winSummary()
    local g = self.g

    if self.devWin then
      -- 调试造局：用假数据，完全不读 settings（假成绩绝不该和真实纪录混在一起）
      local v = self.devWin
      return {
        game       = g,
        difficulty = g.difficulty,
        score      = g.score,
        moves      = g.moves,
        best       = v.best,
        isNewBest  = v.isNewBest,
        wins       = v.wins,
        games      = v.games,
        pct        = v.pct,
      }
    end

    -- 胜负统计要在这里取一次快照：切过去之后 settings 还可能被改。
    -- ⚠ statsFor 的第一个返回值是 best，这里【故意丢掉】：
    --   真正的 best 是 recordWin 里存下的 self.winBest（可能就是这次刚刷新的）。
    --   若误用第一个返回值，会出现"存档里的旧 best 配这次的新胜率"。
    local _, winsNow, gamesNow, pctNow = persist.statsFor(
      self.ctx.settings, g.difficulty)

    return {
      game       = g,
      difficulty = g.difficulty,
      score      = g.score,
      moves      = g.moves,
      best       = self.winBest,
      isNewBest  = self.winIsNew,
      wins       = winsNow,
      games      = gamesNow,
      pct        = pctNow,
    }
  end

  -- ===== 开发调试跳关（M13）=====
  --
  -- 只有 main.lua 读到 SPIDER_DEV=1、把 ctx.dev 设成 true 时才会被调用。
  -- 两个键都先走这里把牌桌改成"真实终局"的样子，区别只在于要不要等那 0.8 秒。

  -- 把牌桌改成刚通关的终局：10 列全空、stock 空、8 个槽填满。
  function s:devMakeWon()
    local g = self.g
    if not g then return end

    -- ⚠ 必须是第一句：先关掉记账闸，再改 foundations。
    -- 顺序反了，recordWin（update 每帧调，leave 里还会兜一次）就会把假成绩写进存档。
    self.resultRecorded = true

    for i = 1, const.COLS do g.tableau[i] = {} end
    g.stock = {}

    -- 2/2/2/2 而不是 8/0/0/0：drawFoundations 是按花色顺序逐个填槽的，
    -- 8/0/0/0 会画出 8 张 ♠K —— 真实终局每种花色最多 2 组。
    g.foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 }

    -- 清掉会画在背景上的残留：选中描边、被拒落点的暗红框、底部那句 message
    g.selected, g.rejectCol, g.message = nil, nil, ""
    g.history, g.events, g.lastMove = {}, {}, nil

    -- 固定假值，且自洽：500 + 8×100 − 96 步 = 1204。
    -- 用固定值而不是当前真值，是为了同一个布局连调十次时数字不变，截图可比对。
    g.score, g.moves = 1204, 96

    -- ⚠ 不清动画会【永久卡死】：收组动画还在飞时 anim.collecting 恒为 true，
    -- winTimer 永远不前进，画面就停在胜利牌桌上一动不动。
    -- 而"刚收完最后一组就按 W"恰恰是最自然的时机，所以这一步不能省。
    anim.clear(self.anim)

    self.drag, self.press   = nil, nil
    self.hint, self.hintDirty = nil, true
    self:invalidateHintList()       -- 假终局也是一副新牌桌
    self.winTimer = 0
    self.devWin   = dev.variant(self.ctx)
  end

  -- 造局 + 跳过 0.8 秒，立刻出现在结算屏
  function s:devJumpWin()
    if not self.g then return end

    -- 必须先造局：won.lua 的 "N of 8 runs completed" 是从牌桌现算的，
    -- 直接把开局牌桌传过去，面板会堂堂正正写着 "0 of 8"。
    self:devMakeWon()

    self.ctx.sm:set("won", self:winSummary())
    -- ⚠ 到此为止：leave 已经把 g 交给 won 当背景了，别再动 self / g。
  end

  -- 记一次胜利（幂等）。只在"这局真的赢了"时才动手：
  --   · 最高分（recordBest）
  --   · 局数 +1、胜局 +1（recordResult）
  --   · 落盘
  -- 返回是否真的记了，方便测试断言"第二次 update 不会重复记"。
  function s:recordWin()
    if self.resultRecorded or not self.g then return false end
    if not game.isWon(self.g) then return false end

    self.resultRecorded = true
    local best, isNew = persist.recordBest(
      self.ctx.settings, self.g.difficulty, self.g.score)
    persist.recordResult(self.ctx.settings, self.g.difficulty, true)
    self.winBest, self.winIsNew = best, isNew

    if self.ctx.saveSettings then self.ctx.saveSettings() end
    return true
  end

  -- 离开时兜一次：极端情况下 update 还没来得及跑就切走了
  function s:leave()
    self:recordWin()          -- 幂等，重复调用没有副作用
  end

  function s:draw(u)
    local vx = u and u.mouseX or -1
    local vy = u and u.mouseY or -1

    buildDebug(vx, vy)

    -- 交给 render 的两份"临时偏移"：动画队列 + 拖拽位移。
    -- ui 表是每帧新建的，状态不会被 render 反过来改。
    local ui = {
      mouseX    = vx,
      mouseY    = vy,
      anim      = self.anim,
      drag      = self:dragOffset(),
      showResign = true,            -- M10：只有 playing 才在 HUD 上画 Resign
      hintMode  = self:mode(),      -- button 模式才画 Hint 按钮
      hint      = self.hint,        -- 提示高亮（源段 + 目标列 / stock / Undo）
      hintAlpha = self:hintAlpha(),
      notice    = self:notice(),    -- 非 nil 时替代底部的 message
    }
    render.draw(self.g, ui)
  end

  -- 拖拽位移（M8）。render 只关心"整段牌整体挪多少"，所以这里算一次就够。
  -- 用「当前鼠标 - 按下时鼠标」而不是「鼠标 - 牌左上角」：拖拽时手指和牌的
  -- 相对位置必须保持不变，否则牌会在手心里滑。
  function s:dragOffset()
    local d = self.drag
    if not d or not d.moved or not self.g then return nil end

    local col = self.g.tableau[d.col]
    if not col or not col[d.index] then return nil end

    return {
      col   = d.col,
      index = d.index,
      dx    = d.x - d.gx,
      dy    = d.y - d.gy,
    }
  end

  function s:mousepressed(x, y, button)
    local g = self.g
    if not g then return end

    if button == 2 then                       -- 右键 = 取消选择
      if g.selected then
        game.deselect(g)
        self.drag = nil
        print("[mouse] deselect (right button)")
      end
      return
    end
    if button ~= 1 then return end
    if anim.busy(self.anim) then return end   -- 发牌 / 收组动画期间不接受操作

    -- 已经赢了：只放行认输按钮之外的一切都不接（赢局不该再被鼠标改动）。
    if game.isWon(g) then return end

    -- 认输按钮（M10）：在 HUD 里。它必须在 clickAt 之前拦下来 ——
    -- HUD 不在任何一列的落点带里，clickAt 会把它当"点了桌外"而取消选中。
    if layout.hitTestResign(x, y) then
      self.drag = nil
      self.ctx.sm:set("resign", { game = g })
      return
    end

    -- 提示按钮（M9）：它不在牌桌落点带里，但必须在 clickAt 之前拦下来，
    -- 否则会被当成"点了桌外 → 取消选中"。
    if self:mode() == "button" and layout.hitTestHint(x, y) then
      self:requestHint()
      return
    end

    self.hint      = nil      -- 点别处就收起提示高亮
    self.hintDirty = true     -- 牌桌可能变了，下次允许时重算（auto 模式用）

    self.press = { col = layout.columnBandAt(x, y) }
    local movesBefore = g.moves
    local msg = game.clickAt(g, x, y)
    self:afterBoardOp(movesBefore)          -- 真的动了牌才作废候选列表
    if msg and msg ~= "" then print("[click] " .. msg) end

    -- 这一下如果点成了「选中一组牌」，就进入"可拖"状态。
    -- 注意这里【不】宣布开始拖 —— 要等鼠标真的移动超过阈值（见 mousemoved）。
    -- 否则"点一下选中"会被当成"拖了 0 像素然后放回原处"。
    local sel = g.selected
    if sel then
      local col = g.tableau[sel.col]
      local cx, cy = const.colX(sel.col), layout.cardY(col, sel.index)
      if x >= cx and x <= cx + const.CARD_W and y >= cy and y <= cy + const.CARD_H then
        self.drag = { col = sel.col, index = sel.index,
                      gx = x, gy = y, x = x, y = y, moved = false }
      end
    end
  end

  -- 拖拽跟手：只记位置，不动牌局。牌局要到松手时才会变。
  function s:mousemoved(x, y)
    local d = self.drag
    if not d then return end

    d.x, d.y = x, y
    if not d.moved then
      local dx, dy = x - d.gx, y - d.gy
      if dx * dx + dy * dy >= const.DRAG_START * const.DRAG_START then
        d.moved = true
      end
    end
  end

  -- 松手。两条路径，互不干扰：
  --   · 真拖过（moved）→ 落在哪一列就放哪一列；落回原列 / 桌外则保持选中
  --   · 没拖过        → 维持老的"按下选了、松开不动"语义（什么都不做）
  function s:mousereleased(x, y, button)
    if button ~= 1 then return end

    local p = self.press
    local d = self.drag
    self.press = nil
    self.drag  = nil
    if not p or not self.g then return end

    local rel = layout.columnBandAt(x, y)

    if d and d.moved then
      if rel and rel ~= d.col then
        local movesBefore = self.g.moves
        local msg = game.dropAt(self.g, rel)
        self:afterBoardOp(movesBefore)      -- 拖拽落点也算牌桌变化
        if msg and msg ~= "" then print("[drag] " .. msg) end
      end
      return
    end

    if self.g.selected and rel and p.col and rel ~= p.col then
      local movesBefore = self.g.moves
      local msg = game.dropAt(self.g, rel)
      self:afterBoardOp(movesBefore)        -- 点选后落点，同款
      if msg and msg ~= "" then print("[drag] " .. msg) end
    end
  end

  function s:keypressed(key)
    local g = self.g
    if not g then return end

    -- ===== DEV（M13）：必须排在 anim.busy / isWon 两道闸【之前】 =====
    -- 开局发牌动画约 1.15 秒、收组动画期间 anim.busy 也都是 true，
    -- 而"刚进游戏"和"刚收完最后一组"正是最想立刻看结算屏的两个时机。
    if self.ctx.dev then
      if key == "w" then
        self:devMakeWon()
        print("[dev] faked a finished deal - the real 0.8s countdown will run")
        return
      elseif key == "j" then
        self:devJumpWin()
        return
      end
    end

    -- 发牌 / 收组动画期间：游戏操作一律不接，但允许离开和看调试
    if anim.busy(self.anim) then
      if key == "escape" then
        self.ctx.sm:set("menu")
      elseif key == "f1" then
        self.showDebug = not self.showDebug
        print("debug overlay: " .. (self.showDebug and "ON" or "OFF"))
      end
      return
    end

    -- 已经赢了：这局就结束了，只放行离开和看调试。
    -- 否则玩家能在 0.8 秒的展示期里按 Z 撤销，变成"记了一次赢，牌局又退回未赢"。
    if game.isWon(g) then
      if key == "escape" then
        self.ctx.sm:set("menu")
      elseif key == "f1" then
        self.showDebug = not self.showDebug
      end
      return
    end

    if key == "escape" then
      if g.selected then
        game.deselect(g)
        print("[key] deselect")
      else
        self.ctx.sm:set("menu")
      end
    elseif key == "r" then
      anim.clear(self.anim)                 -- 旧局还在飞的牌立刻作废
      self.g = newDeal(self.ctx)            -- 换一个新种子（不是重放上一局）
      self.resultRecorded = false
      self.winBest, self.winIsNew = nil, nil
      self.devWin = nil
      self.drag = nil
      self.winTimer = 0
      self.hint = nil
      self.hintDirty = true
      self:invalidateHintList()
      print(string.format("[key] re-dealt (seed=%s, stock=%d)",
        tostring(self.g.seed), #self.g.stock))
    elseif key == "z" or key == "u" then
      -- Ctrl+Z 也会走到这里：main.lua 只转发 key，不转发修饰键。
      -- 这里也不吃修饰键的状态 —— 游戏里没有文本输入，单独的 z 不会和别的东西冲突。
      local msg = game.undo(g)
      self.drag = nil
      self.hint = nil
      self.hintDirty = true
      self:invalidateHintList()
      if msg and msg ~= "" then print("[undo] " .. msg) end
    elseif key == "h" then
      -- 要一次提示。两种模式都有效：auto 是"它自己会说"，button 是"问了才说"。
      self:requestHint()
    elseif key == "d" then
      print(game.dump(g))
    elseif key == "f1" then
      self.showDebug = not self.showDebug
      print("debug overlay: " .. (self.showDebug and "ON" or "OFF"))
    end
  end

  return s
end

return M
