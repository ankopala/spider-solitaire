-- src/text.lua —— 界面文案集中处（纯数据，不引用 love）
--
-- 为什么单独一个文件？
--   当前字体 DejaVu Sans 不含 CJK，界面只能先用英文。等 M6 之后决定中文方案时，
--   **只需要改这一个文件**（外加给 render 换一套字体），不用满项目找字符串。
--
-- 说明：牌局过程提示（"moved 3 cards ..."）仍在 src/game.lua 里，
-- 它们更像日志而不是界面文案，等做中文时再一起收编。

local M = {}

-- ===== 菜单 =====
M.title      = "Spider Solitaire"
M.tagline    = "104 cards  -  build eight runs from K down to A"
M.start_game = "Start"
M.quit       = "Quit"
M.nav_hint   = "arrow keys + enter, or click"

-- 菜单第三项：进去输入种子，重玩某一局
M.menu_seed_btn = "Play a seed"
-- 菜单上那行"上一局的种子"。参数：种子字符串, 难度文案
M.menu_seed     = "last seed %s  (%s)"

-- ===== 设置（难度 + 提示方式）=====
M.settings_title = "Settings"
M.settings_hint  = "difficulty, and how much the game helps you"
M.sec_difficulty = "DIFFICULTY"
M.sec_hints      = "HINTS"

M.diff = {
  [1] = { name = "1 suit",  sub = "easy    - every card is a spade" },
  [2] = { name = "2 suits", sub = "medium  - spades and hearts" },
  [4] = { name = "4 suits", sub = "hard    - all four suits" },
}

-- 提示方式：
--   auto   每次牌桌变化后自己判一次，无路可走时底部出提示条
--   button 不自动提示，底部多一个 Hint 按钮（H 键同效），点了才高亮答案
M.hint_mode = {
  auto   = { name = "Auto",        sub = "says when you're stuck" },
  button = { name = "Hint button", sub = "press H, or click Hint" },
}
M.hint_button = "Hint"
M.hint_key    = "H"

M.settings_keys_hint = "1 / 2 / 4 difficulty,  h hints,  esc back"
M.back = "Back"

-- ===== 游戏 HUD =====
-- 参数顺序：花色数文案, sets, total sets, stock, 剩余轮数文案, moves, score
M.hud = "%s   sets %d/%d   stock %d (%s)   moves %d   score %d"
M.hud_menu_hint = "esc: menu"

-- "1 suit" / "2 suits" —— 英文单复数，别让界面出现 "1 suits"
function M.suitCount(n)
  return string.format("%d suit%s", n, n == 1 and "" or "s")
end

-- "1 deal" / "5 deals" —— 同理
function M.dealCount(n)
  return string.format("%d deal%s", n, n == 1 and "" or "s")
end

-- ===== 撤销 =====
M.undo     = "Undo"
M.undo_key = "Z"        -- 按钮右侧的键位提示（Ctrl+Z 也行，见 playing.lua）

-- ===== 底部提示条（auto 模式下替代上一步的 message）=====
-- "moves" 不显示任何东西，所以这里只有三条。
M.notice_deal  = "nothing to move - deal a round from the stock (%d left)"
M.notice_stuck = "out of moves - Z to undo, Esc for the menu"
-- stall：还有牌可动，但没有一手能翻开新牌（也就没有任何新信息可能进来）。
-- 措辞刻意不说 "dead"：这需要搜索才能断言，静态判定说不准。
M.notice_stall = "no move turns over a new card - undo, or resign"

-- 连按 H 循环候选时的定位（M14）。参数：第几个, 一共几个
M.hint_count = "hint %d / %d  -  H for the next"

-- ===== 认输（M10）=====
M.resign         = "Resign"
M.resign_title   = "Resign?"
M.resign_lede    = "give up this deal - the score and move count will be lost"
M.resign_restart = { name = "Restart this deal", sub = "the same 104 cards, laid out the same way" }
M.resign_new     = { name = "New deal",          sub = "shuffle a fresh deck" }
M.resign_cancel  = { name = "Keep playing",      sub = "back to the table" }

-- ===== 胜利 =====
M.won_title = "You win!"
M.won_runs  = "%d of %d runs completed"
M.won_stats = "score %d     moves %d"
-- 一局的身份。难度要一起显示，否则玩家会疑惑"同种子怎么不是同一局"
M.won_seed  = "seed %s  (%s)"

-- ===== 统计行：最高分 + 胜率（M11 / M12）=====
-- 两种信息挤在一行，是因为结算面板 py+184 之后到按钮只剩 48px，
-- 拆两行必然压到按钮上。
M.stats_both = "best %d   won %d/%d (%d%%)"
M.stats_new  = "new best! %d   won %d/%d (%d%%)"
M.stats_won  = "won %d/%d (%d%%)"
M.stats_best = "best %d"

-- 按可用信息挑模板；什么都没有就返回 nil，界面据此决定不画。
-- 四档对应：有纪录有局数 / 没纪录有局数 / 只有纪录 / 全空。
function M.stats(best, wins, games, pct, isNew)
  if games and games > 0 then
    if best and best > 0 then
      return string.format(isNew and M.stats_new or M.stats_both,
        best, wins, games, pct)
    end
    return string.format(M.stats_won, wins, games, pct)
  end

  if best and best > 0 then
    return string.format(M.stats_best, best)
  end
  return nil
end
M.play_again = "Play again"
M.main_menu  = "Main menu"

-- ===== 种子输入屏（M12）=====
M.seed_title = "Play a seed"
M.seed_lede  = "same seed, same 104 cards"
M.seed_hint  = "0-9 type   backspace delete   enter deal   esc back"
M.seed_will  = "will play %s"
M.seed_last  = "last seed %s   (%s)"
M.seed_empty = "type at least one digit"
M.seed_play  = "Deal"
M.seed_back  = "Back"

-- 认输面板的说明。带种子：玩家想在放弃前记下这一局，还有机会。
-- 长度控制：面板 660 宽。10 位种子时整行约 578px（tiny 字号、每位数字 11.45px），
-- 两侧各余约 41px —— 这是全项目最挤的一行，加词之前先量宽度。
M.resign_lede_seed = "give up this deal (seed %s) - score and moves are lost"

return M
