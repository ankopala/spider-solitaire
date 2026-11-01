-- const.lua —— 全局常量（纯数据 + 两个坐标函数，不含游戏逻辑）
-- 本项目所有绘制与命中检测都基于这套「虚拟坐标」：1280 x 720

local const = {}

-- ===== 虚拟分辨率 =====
const.VW, const.VH = 1280, 720

-- ===== HUD 顶栏 =====
const.HUD_H    = 64
const.MSG_Y    = 676            -- 牌桌底部提示文字（HUD 之外，单列一行）

-- ===== 牌桌 tableau：10 列 =====
const.COLS       = 10
const.CARD_W     = 100
const.CARD_H     = 140          -- 宽高比 0.714，接近真实扑克牌
const.CARD_R     = 8            -- 圆角半径
const.COL_GAP    = 20
const.COL_LEFT   = 50           -- 第 1 列左上角 x
const.COL_STRIDE = 120          -- = CARD_W + COL_GAP
const.TABLEAU_Y  = 90           -- 列的起始 y（HUD 之下留出间隔）

-- 叠压步长：背面牌只露一条边（小），翻开牌露更多（大，能看清 rank/suit）
const.STEP_DOWN = 8
const.STEP_UP   = 22

-- ===== 底部区域：stock（牌库）与 foundation（完成区）=====
const.BOTTOM_Y = 530

const.STOCK_X = 1130
const.STOCK_Y = 530
const.STOCK_W = 100
const.STOCK_H = 140
-- 最多叠 5 张，每张向右错开这么多。render 与测试共用，别再写字面量 4。
-- ⚠ 4px 时 5 张只错开 16px，条带太窄，1px 的层间暗缝在正常观看距离下分辨不出
-- （用户反馈"像没有边界"）。7px 是"看得出独立卡片"与"不占太多横向空间"的折中：
-- 5 张合计 100+28=128，右沿 1258，仍留 22px。
const.STOCK_STACK_DX = 7
const.STOCK_STACK_MAX = 5       -- 一叠最多显示几张（= 剩余轮数上限）

const.FOUND_COUNT = 8
const.FOUND_W     = 60
const.FOUND_H     = 84
const.FOUND_GAP   = 12
const.FOUND_X0    = 50
const.FOUND_Y     = 558

-- ===== 撤销按钮（M7）=====
-- 放在底部空白区：与 foundation 槽同一条视觉基线（558..642）里垂直居中，
-- 左边界避开第 8 个槽（右沿 614），右边界离 stock（1130）还很远。
const.UNDO_X = 690
const.UNDO_Y = 572
const.UNDO_W = 200
const.UNDO_H = 56

-- ===== 提示按钮（只在 settings.hintMode == "button" 时出现）=====
-- 排在 Undo 右边：Undo 右沿 890，这里留 20px 间隙；右边离 stock(1130) 还有 40px。
-- y 与 Undo 同一条基线，且全程在 BAND_BOTTOM(520) 之下 —— 否则点它会被当成"落到某列"。
const.HINT_X = 910
const.HINT_Y = 572
const.HINT_W = 180
const.HINT_H = 56

-- 点 Hint 之后高亮存活多久（秒）。前 HOLD-FADE 秒全亮，最后 FADE 秒线性淡出。
const.HINT_HOLD = 3.0
const.HINT_FADE = 0.5

-- ===== 认输按钮（HUD 右上角，M10）=====
-- 放在 HUD 里而不是底部：底部已经被 Undo / Hint / stock 占满，
-- 而 resign 是个低频操作，不该和"每步都会用"的按钮抢位置。
-- 右边界留出 130px 给 HUD 右侧那句 "esc: menu" 说明（它右对齐在 VW-20）。
const.RESIGN_X = 1020
const.RESIGN_Y = 14
const.RESIGN_W = 96
const.RESIGN_H = 36

-- ===== 动画（M8）=====
-- 全部是秒。数值偏小是有意的：这个游戏的节奏靠"连续出牌"，
-- 动画一旦拖过 0.3s，玩家就会开始觉得在等它。
const.ANIM_DEAL_CARD     = 0.24    -- 开局单张牌从顶部落到列里
const.ANIM_DEAL_STAGGER  = 0.017   -- 相邻两张的间隔（54 张 ≈ 0.9s 发完）
const.ANIM_MOVE          = 0.15    -- 移动一段牌
const.ANIM_STOCK         = 0.26    -- 补牌：单张飞到位的时间
const.ANIM_STOCK_STAGGER = 0.035   -- 补牌：10 张从左到右依次出发
const.ANIM_COLLECT       = 0.42    -- 收组：13 张飞进 foundation

-- 拖拽：鼠标移动超过这个距离才算是"拖"，否则仍然按"点一下选中"处理。
-- 太小会导致手一抖就把牌甩出去，太大又会觉得拖不动。
const.DRAG_START = 6

-- ===== 计分（微软经典规则）=====
-- 初始 500、每成功移动一次 -1、每完成一组 K→A 入 foundation +100、每次撤销 -1。
-- 注意撤销的 -1 是叠加在"回滚到快照分数"之上的：撤销不会把移动扣的那 1 分退回来。
const.SCORE_START    = 500
const.SCORE_PER_MOVE = 1
const.SCORE_PER_SET  = 100
const.SCORE_PER_UNDO = 1

-- ===== 颜色 =====
-- 注意：love.graphics 的颜色是 0..1 的浮点，不是 0..255！
local function rgb(r, g, b)
  return { r, g, b }
end

const.COLOR_BG        = rgb(0.13, 0.13, 0.15)   -- 牌桌底色
const.COLOR_HUD       = rgb(0.18, 0.18, 0.20)   -- 顶栏
const.COLOR_SLOT_FILL = rgb(0.16, 0.16, 0.18)   -- 空槽填充
const.COLOR_SLOT_LINE = rgb(0.35, 0.35, 0.38)   -- 空槽描边
const.COLOR_CARD_FACE      = rgb(0.95, 0.95, 0.95)   -- 牌正面底色
const.COLOR_CARD_LINE      = rgb(0.20, 0.20, 0.22)   -- 牌边框
const.COLOR_CARD_BACK      = rgb(0.25, 0.25, 0.30)   -- 牌背面底色
const.COLOR_CARD_BACK_LINE = rgb(0.45, 0.45, 0.52)   -- 牌背面内框
const.COLOR_CARD_BACK_ICON = rgb(0.35, 0.35, 0.40)   -- 牌背面蜘蛛线稿（比内框暗一档）
const.COLOR_CARD_BACK_EDGE = rgb(0.31, 0.31, 0.36)   -- 叠压时露出的"纸边"接缝
const.COLOR_CARD_BACK_SHADE = rgb(0.175, 0.175, 0.215) -- stock 层间暗缝（卡片之间的阴影）
const.COLOR_SUIT_BLACK     = rgb(0.10, 0.10, 0.12)   -- ♠ ♣
const.COLOR_SUIT_RED       = rgb(0.78, 0.15, 0.15)   -- ♥ ♦
const.COLOR_TEXT           = rgb(0.90, 0.90, 0.90)
const.COLOR_TEXT_DIM       = rgb(0.55, 0.55, 0.60)

-- 选中高亮：牌面是接近纯白 (0.95)，所以不能用"更亮的描边"（白描边在白牌上看不见）。
-- 改为在牌【底下】垫一圈浅灰底，四周各露出 SELECT_PAD 像素 —— 在深色桌面上清晰可见，
-- 且完全不引入新色相，仍然守着黑白灰。
const.COLOR_SELECT = rgb(0.88, 0.88, 0.92)
const.SELECT_PAD   = 7

-- ===== 界面零件（菜单按钮 / 面板）=====
-- M8 之前这套颜色单独写在 src/ui.lua 里，牌桌自己又另算一套，两边灰度慢慢漂了。
-- 现在统一收到这里：所有"深底浅字 / 浅底深字"的界面零件都从这几个值取。
const.COLOR_PANEL            = rgb(0.18, 0.18, 0.20)   -- 面板底
const.COLOR_BTN_FILL         = rgb(0.17, 0.17, 0.19)   -- 按钮：普通
const.COLOR_BTN_FILL_HOT     = rgb(0.88, 0.88, 0.92)   -- 按钮：悬停（反色）
const.COLOR_BTN_FILL_ACTIVE  = rgb(0.26, 0.26, 0.29)   -- 按钮：当前选中
const.COLOR_BTN_LINE         = rgb(0.32, 0.32, 0.36)
const.COLOR_BTN_LINE_HOT     = rgb(0.95, 0.95, 0.97)
const.COLOR_BTN_LINE_ACTIVE  = rgb(0.85, 0.85, 0.90)
const.COLOR_TEXT_HOT         = rgb(0.10, 0.10, 0.12)   -- 悬停时的深色字
const.COLOR_TEXT_ACTIVE      = rgb(0.97, 0.97, 0.98)

-- ===== 落点提示 =====
-- 选中一段牌之后，把「能落的列」描一圈浅边 → 用户不用猜哪里能放。
-- 被拒绝的落点描一圈暗红 → 明确告诉用户"这一列不行"（暗红是功能色，不是为了好看）。
const.COLOR_TARGET = rgb(0.82, 0.82, 0.88)
const.COLOR_REJECT = rgb(0.78, 0.34, 0.34)
const.TARGET_ALPHA = 0.38
const.REJECT_ALPHA = 0.85
const.HINT_PAD     = 6      -- 落点外框相对列的额外留白

-- ===== 列的「落点带」范围 =====
-- 一整列从牌顶一直到牌桌底部都算这一列的可落区，而不是"只有牌身才算"。
-- 原因：一列看起来就是一个牌堆，用户很自然会点在牌【下方】的空处；
-- 老版本那里会被判定成"点空"并取消选中，用户只会觉得"点了落点没反应"。
const.BAND_TOP    = const.TABLEAU_Y - 8    -- 上方也容错几像素
const.BAND_BOTTOM = const.BOTTOM_Y - 10    -- 下沿到牌库那一行之上
const.BAND_PAD_X  = const.COL_GAP / 2      -- 左右各向外扩半个列间距 → 点在列缝里也归最近那列

-- ===== 字体 =====
-- DejaVu Sans：含 ♠♥♦♣ 字形，Bitstream Vera 许可（可再分发）。
-- 注意：它【不含 CJK】，中文界面文字无法用它渲染。
const.FONT_PATH   = "assets/fonts/DejaVuSans.ttf"
const.FONT_TINY   = 18           -- 菜单说明、HUD 里的小字
const.FONT_SMALL  = 22           -- 牌面角标、正文
const.FONT_BIG    = 54           -- 菜单标题、You win

-- ===== 牌背装饰（M16）=====
-- 全是纯数据。绘制在 src/render.lua 的 drawSpider 里 —— 放到这里是因为
-- render.lua 不能被终端测试加载，几何只有放在 const 才能被断言守住。

const.CARD_BACK_INSET      = 7     -- 内框向内缩进

-- 叠压时的「亮切边」（M18）：位置落在内框顶边上，两端缩到内框圆角之外，
-- 才和真实内框的直线段等长。两者都从 CARD_BACK_INSET 派生，改内框会自动跟随。
const.CARD_BACK_RIM_DY     = const.CARD_BACK_INSET                              -- 7
const.CARD_BACK_RIM_INSET  = const.CARD_BACK_INSET + (const.CARD_R - 3)         -- 12
const.CARD_BACK_ICON_W     = 1.8   -- 蜘蛛线宽（≤1 会被 smooth 削掉 core，出现断线感）
const.CARD_BACK_ICON_DY    = -4    -- 蜘蛛相对牌中心上移 4px，给 stock 右下角轮数让位

-- 蜘蛛：以 (0,0) 为图标中心，只写【右半边】，左半边由 drawSpider 镜像（x 取负）。
-- 每条腿 3 点：腿根 → 膝盖 → 脚尖。腿根一律落在 x=0 的躯干内部（必被身体填充盖住，
-- 永远看不到线头）；膝盖沿一条下降弧线排开（-30 → -17 → 0 → 12），8 条腿才张得开。
const.SPIDER_LEGS = {
  { 0, -14,  16, -31,  28, -22 },   -- 前腿：膝抬最高、脚尖略回收
  { 0, -10,  23, -19,  35,  -8 },
  { 0,  -6,  25,   1,  35,  13 },
  { 0,  -1,  20,  14,  27,  29 },   -- 后腿：膝和脚尖都往下外侧走，别做垂直段（会像椅子腿）
}

-- 头胸部 + 腹部：cx, cy, rx, ry。两椭圆重叠 3px 形成"腰"，头小腹大（1 : 1.7）。
-- 绘制顺序就是表中顺序：腹部后画，用底色填充把头胸的下半弧擦掉。
const.SPIDER_BODY = {
  { 0, -12,  8,  9 },
  { 0,  12, 14, 16 },
}

-- ===== 种子复制控件（M19）=====
-- 尺寸必须在【常量】里定死：面板的 mousepressed 要判定按钮矩形，而那一刻
-- 不能去量字体宽度（事件处理里不许碰 love）。所以方框/按钮宽度是写死的，
-- 「文字装不装得下」只能靠两条守卫：这里的注释宽度估算 + 探针截图目测。
--
-- 宽度依据（tiny = 18px，DejaVu Sans 每位数字 1303/2048 em ≈ 11.45px）：
--   "seed 1234567890"              ≈ 163px  → 方框 200 两侧各留 18
--   "seed 1234567890  (4 suits)"   ≈ 248px  → 结算屏单独用 270（见 SEEDBOX_CHIP_W_LONG）
--   "Copied"                       ≈  55px  → 按钮 76 够
const.SEEDBOX_H          = 28
const.SEEDBOX_CHIP_W     = 200
const.SEEDBOX_CHIP_W_LONG = 270   -- 结算屏那行还带难度，得单独加宽
const.SEEDBOX_GAP        = 8
const.SEEDBOX_BTN_W      = 76
const.SEEDBOX_HOLD       = 1.2    -- 复制后 "Copied" 停留秒数

-- ===== 派生坐标：用函数算，避免手抄 10 个数出错 =====

-- 第 i 列（1..10）左上角的 x
function const.colX(i)
  return const.COL_LEFT + (i - 1) * const.COL_STRIDE
end

-- 第 i 个 foundation 槽（1..8）左上角的 x
function const.foundSlotX(i)
  return const.FOUND_X0 + (i - 1) * (const.FOUND_W + const.FOUND_GAP)
end

return const
