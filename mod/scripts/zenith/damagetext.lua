-- 泰拉瑞亚式伤害数字（CombatText）：字体由 tools/build_assets.mjs 从泰拉 Combat_Text / Combat_Crit 转换而来。
-- 运动规则照搬泰拉：初速度向上 7，每帧 ×0.92 减速（暴击再 ×0.92）；横向 ×0.93；
-- 透明度在 0.6～1 之间呼吸；出现时从 0 放大，寿命结束后缩小消失；暴击寿命和初速度翻倍。
-- 泰拉逻辑每秒 60 帧，这里每个以撒逻辑帧推进 2 步。

local C = include("scripts.zenith.config")
include("scripts.zenith.settings") -- 全局 ZenithSettings（伤害数字开关）

local DamageText = {}

local TERRARIA_STEPS = 2

-- Font:Load 不会在 mod 的 resources 里查找，需要绝对路径（做法同 EID）
local function modPath()
    local _, err = pcall(require, "")
    if type(err) ~= "string" then
        return nil
    end
    local _, first = string.find(err, "no file '", 1)
    local _, start = string.find(err, "no file '", first or 1)
    local stop = start and string.find(err, ".lua'", start)
    if not stop then
        return nil
    end
    local path = string.sub(err, start + 1, stop - 1)
    path = string.gsub(path, "\\", "/")
    path = string.gsub(path, "//", "/")
    path = string.gsub(path, ":/", ":\\")
    return path
end

local function loadFont(file)
    local font = Font()
    local base = modPath()
    if base then
        font:Load(base .. "resources/font/" .. file, "")
    end
    if not font:IsLoaded() then
        font:Load("font/" .. file, "")
    end
    if not font:IsLoaded() then
        Isaac.DebugString("[Zenith] damage text font not loaded: " .. file)
        return nil
    end
    return font
end

local normalFont = loadFont("zenith_combat.fnt")
local critFont = loadFont("zenith_combat_crit.fnt")

local texts = {}

-- 泰拉显示整数；以撒伤害常带小数，小于 10 时保留一位小数
local function format(damage)
    if damage >= 10 then
        return tostring(math.floor(damage + 0.5))
    end
    local s = string.format("%.1f", damage)
    return (string.gsub(s, "%.0$", ""))
end

function DamageText.Add(entity, damage, crit, rng)
    if not C.DAMAGE_TEXT or not ZenithSettings.Get("damageText") or not normalFont then
        return
    end
    -- 泰拉：在受击者碰撞框内随机位置出现
    local spread = math.max(4, entity.Size)
    local t = {
        anchor = entity.Position,
        x = (rng:RandomFloat() * 2 - 1) * spread * 0.5,
        y = -entity.Size * 0.5,
        vx = 0,
        vy = -7,
        life = 60,
        alpha = 1,
        alphaDir = -1,
        scale = 0,
        text = format(damage),
        crit = crit,
    }
    if crit then
        t.life = t.life * 2
        t.vy = t.vy * 2
        t.vx = (rng:RandomInt(51) - 25) * 0.05
    end
    texts[#texts + 1] = t
    if #texts > C.DAMAGE_TEXT_MAX then
        table.remove(texts, 1)
    end
end

function DamageText.Update()
    for i = #texts, 1, -1 do
        local t = texts[i]
        local alive = true
        for _ = 1, TERRARIA_STEPS do
            t.alpha = t.alpha + t.alphaDir * 0.05
            if t.alpha <= 0.6 then
                t.alphaDir = 1
            end
            if t.alpha >= 1 then
                t.alpha = 1
                t.alphaDir = -1
            end
            t.vy = t.vy * 0.92
            if t.crit then
                t.vy = t.vy * 0.92
            end
            t.vx = t.vx * 0.93
            t.x = t.x + t.vx
            t.y = t.y + t.vy
            t.life = t.life - 1
            if t.life <= 0 then
                t.scale = t.scale - 0.1
                if t.scale < 0.1 then
                    alive = false
                    break
                end
            elseif t.scale < 1 then
                t.scale = math.min(1, t.scale + 0.1)
            end
        end
        if not alive then
            table.remove(texts, i)
        end
    end
end

function DamageText.Clear()
    texts = {}
end

local function drawCentered(font, text, x, y, scale, r, g, b, a)
    local w = font:GetStringWidth(text) * scale
    local h = font:GetLineHeight() * scale
    x, y = x - w * 0.5, y - h * 0.5
    -- 泰拉的描边：黑字在上下左右各偏移一下再画彩色字
    local black = KColor(0, 0, 0, a)
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        font:DrawStringScaled(text, x + o[1], y + o[2], scale, scale, black, 0, false)
    end
    font:DrawStringScaled(text, x, y, scale, scale, KColor(r, g, b, a), 0, false)
end

function DamageText.Render()
    if #texts == 0 then
        return
    end
    local base = C.DAMAGE_TEXT_SCALE
    -- 泰拉的位移单位是 1080p 像素，这里按字体缩放同比换算到以撒屏幕
    for _, t in ipairs(texts) do
        local font = (t.crit and critFont) or normalFont
        local color = t.crit and C.DAMAGE_TEXT_CRIT_COLOR or C.DAMAGE_TEXT_COLOR
        local pos = Isaac.WorldToScreen(t.anchor) + Vector(t.x, t.y) * base
        drawCentered(font, t.text, pos.X, pos.Y, base * t.scale,
            color[1] / 255, color[2] / 255, color[3] / 255, t.alpha)
    end
end

return DamageText
