-- 绘制准星、拖尾条带、粒子、剑身残影、主剑和刀尖星闪，绘制顺序和透明度曲线照搬泰拉原版。
-- 拖尾条带用 REPENTOGON 的 Beam 渲染器，并设为叠加混合（发光）；没装 REPENTOGON 时只画残影。

local C = include("scripts.zenith.config")
local Settings = include("scripts.zenith.settings") -- 拖尾开关、发光效果
local Sword = include("scripts.zenith.sword")

local Render = {}

local HALF_PI, QUARTER_PI = math.pi / 2, math.pi / 4
local PX_TO_SCREEN = 0.5 * C.SWORD_SCALE -- 泰拉像素 → 以撒屏幕像素
local TRAIL_W, TRAIL_H = 64, 128          -- 与 tools/build_assets.mjs 保持一致
local SPARKLE_SCALE = 0.5 * C.SWORD_SCALE

local lerpValue, clamp01 = Sword.LerpValue, Sword.Clamp01

local function loadSprite(anm2, anim)
    local s = Sprite()
    s:Load(anm2, true)
    s:Play(anim or "Idle", true)
    return s
end

-- 叠加混合（发光）需要 REPENTOGON；失败时保持普通混合。可在设置里关掉，改设置时立即对所有登记过的精灵生效
local glowSprites = {}
local function applyGlow(entry)
    if BlendType == nil then
        return
    end
    local on = C.ADDITIVE_GLOW and Settings.Get("glow")
    pcall(function()
        entry[1]:GetLayer(entry[2]):GetBlendMode():SetMode(on and BlendType.ADDITIVE or BlendType.NORMAL)
    end)
end
local function makeAdditive(sprite, layerId)
    local entry = { sprite, layerId }
    glowSprites[#glowSprites + 1] = entry
    applyGlow(entry)
end
Settings.OnChange(function(key)
    if key == "glow" then
        for _, entry in ipairs(glowSprites) do
            applyGlow(entry)
        end
    end
end)

local swordSprites = {}
local function swordSprite(profile)
    local s = swordSprites[profile.id]
    if not s then
        s = loadSprite(profile.anm2, profile.model and profile.model.anim)
        swordSprites[profile.id] = s
    end
    return s
end

local sparkleSprite = loadSprite("gfx/zenith/sparkle.anm2")
local dustSprite = loadSprite("gfx/zenith/dust.anm2")
makeAdditive(sparkleSprite, 0)
makeAdditive(dustSprite, 0)

-- 两条 Beam：亮边分别在贴图右侧 / 左侧，按剑的旋转方向挑选，保证亮边在刀尖（外侧）
local beamRight, beamLeft
if Beam ~= nil and Point ~= nil then
    -- Beam 只复制这张精灵的动画数据，原精灵要一直保留引用，避免被垃圾回收后共享的资源被释放
    Render.TrailSprite = loadSprite("gfx/zenith/trail.anm2")
    local trailSprite = Render.TrailSprite
    beamRight = Beam(trailSprite, 0, false, false)
    beamLeft = Beam(trailSprite, 1, false, false)
    makeAdditive(beamRight:GetSprite(), 0)
    makeAdditive(beamLeft:GetSprite(), 1)
end
Render.HasTrail = beamRight ~= nil

local function drawSword(sprite, screenPos, rot, spriteDir, scale, color, model)
    if model then
        -- 原版模型（妈刀、英灵剑、剑气）：刀尖方向 = rot - π/2，精灵旋转 = 刀尖角度 + 模型的旋转偏移；
        -- 中心点不在刀身中点的（英灵剑在剑柄）沿刀尖反方向挪回去
        local tip = rot - HALF_PI
        sprite.FlipX = false
        sprite.Rotation = math.deg(tip) + model.rotation
        scale = model.scale * scale / C.SWORD_SCALE
        if model.tipOffset ~= 0 then
            screenPos = screenPos - Vector(math.cos(tip), math.sin(tip)) * (model.tipOffset * scale)
        end
    else
        sprite.FlipX = spriteDir == -1
        sprite.Rotation = math.deg(rot - QUARTER_PI * spriteDir)
    end
    sprite.Scale = Vector(scale, scale)
    sprite.Color = color
    sprite:Render(screenPos)
end

local function drawTrail(s, progress, ox, oy)
    local profile = s.profile
    local color = s.color or profile -- 硫磺火联动的血光
    -- 实测：Beam 把贴图右边缘画在行进方向的左侧，所以刀尖在右侧时要用“亮边在左”的贴图
    local useLeft = s.tipRight
    if C.TRAIL_SIDE_FLIP then
        useLeft = not useLeft
    end
    local beam = useLeft and beamLeft or beamRight
    local width = profile.blade * PX_TO_SCREEN * s.size / TRAIL_W
    -- 先算出有几个点：刚出手、还没更新过的剑只有 1 个点，Beam 少于 2 个点渲染会报错，
    -- 而且报错后残留的点会混进下一把剑的拖尾。点直接用 beam:Add(位置, 坐标, 宽度, 颜色) 加入，
    -- 不创建 Point 对象（同屏剑多时每帧要加几千个点，尽量少造原生对象）
    local last = math.min(C.TRAIL_POINTS, math.floor(progress / (C.TRAIL_CACHE * s.rate) * C.TRAIL_POINTS))
    if last < 1 then
        return
    end
    for i = 0, last do
        local f = i / C.TRAIL_POINTS
        local x, y = Sword.Pose(s, progress - f * C.TRAIL_CACHE * s.rate, ox, oy)
        local alpha = (1 - lerpValue(0, 0.98, f)) * C.TRAIL_ALPHA
        beam:Add(Isaac.WorldToScreen(Vector(x, y)), f * TRAIL_H, width, Color(color.r, color.g, color.b, alpha), false)
    end
    beam:Render()
end

local function drawSparkle(s, progress, screenPos, rot)
    local strength = lerpValue(15, 30, progress) * lerpValue(45, 30, progress)
    if strength <= 0 then
        return
    end
    local tip = Vector(math.cos(rot - HALF_PI), math.sin(rot - HALF_PI)) * (s.profile.blade * 0.5 * PX_TO_SCREEN * s.size)
    local pos = screenPos + tip
    local k = strength * SPARKLE_SCALE * s.size
    local p = s.color or s.profile
    for _, layer in ipairs({ { Color(p.r, p.g, p.b, 0.5 * strength), 1 }, { Color(1, 1, 1, 0.5 * strength), 0.6 } }) do
        sparkleSprite.Color = layer[1]
        sparkleSprite.Rotation = 90
        sparkleSprite.Scale = Vector(0.5, 5) * (k * layer[2])
        sparkleSprite:Render(pos)
        sparkleSprite.Rotation = 0
        sparkleSprite.Scale = Vector(0.5, 2) * (k * layer[2])
        sparkleSprite:Render(pos)
    end
end

-- 剑身颜色：硫磺火联动时整体偏红并叠一层红色（血光），否则原色
local function swordColor(s, alpha)
    if s.color then
        return Color(1, 0.55, 0.55, alpha, s.color.r * 0.35, 0, 0)
    end
    return Color(1, 1, 1, alpha)
end

local function drawSwordWithAfterimages(s, progress, ox, oy)
    local sprite = swordSprite(s.profile)

    -- 剑身残影：60、45、30、15 次更新之前的位置，越早越淡
    for i = C.TRAIL_CACHE, C.AFTERIMAGE_STEP, -C.AFTERIMAGE_STEP do
        local past = progress - i * s.rate
        if past >= 0 then
            local t = progress - i
            local fade = lerpValue(0, C.TRAIL_CACHE, C.TRAIL_CACHE - i) * lerpValue(0, 20, t) * lerpValue(68, 60, t)
            if fade > 0 then
                local x, y, rot, dir = Sword.Pose(s, past, ox, oy)
                drawSword(sprite, Isaac.WorldToScreen(Vector(x, y)), rot, dir, C.SWORD_SCALE * s.size, swordColor(s, fade), s.profile.model)
            end
        end
    end

    -- 主剑：淡入后在回到角色身边时（进度 60～68）淡出
    local visible = lerpValue(0, 20, progress) * lerpValue(68, 60, progress)
    local opacity = lerpValue(0, 5, progress) * lerpValue(C.LIFE_END, C.LIFE_END - 5, progress)
    local x, y, rot, dir = Sword.Pose(s, progress, ox, oy)
    local screenPos = Isaac.WorldToScreen(Vector(x, y))
    if visible > 0 then
        drawSword(sprite, screenPos, rot, dir, C.SWORD_SCALE * (s.profile.model and 1 or 1.25) * s.size, swordColor(s, 0.9 * visible * opacity), s.profile.model)
    end
    drawSparkle(s, progress, screenPos, rot)
end

local function drawParticles(particles, frac)
    for _, d in ipairs(particles) do
        local fade = d.life / d.maxLife
        local speed = math.sqrt(d.vx * d.vx + d.vy * d.vy)
        dustSprite.Color = Color(d.r, d.g, d.b, fade)
        dustSprite.Rotation = math.deg(math.atan(d.vy, d.vx)) - 90
        dustSprite.Scale = Vector(0.45, 0.45 + speed * 0.2) * (0.5 + 0.5 * fade)
        dustSprite:Render(Isaac.WorldToScreen(Vector(d.x + d.vx * frac, d.y + d.vy * frac)))
    end
end

function Render.Draw(effect, state, player)
    if Game():GetRoom():GetRenderMode() == RenderMode.RENDER_WATER_REFLECT then
        return
    end

    -- 逻辑每秒 30 帧、渲染 60 帧：两次逻辑更新之间按比例插值，让飞剑和拖尾更顺滑（准星是实体，由引擎插值）
    local frac = clamp01((Isaac.GetFrameCount() - (state.renderFrame or 0)) / 2)

    local playerOrigin = player.Position + player.Velocity * frac + C.ORIGIN_OFFSET
    -- 每把剑的原点：角色的剑用角色位置，跟班的剑用跟班位置
    -- 卢多维科联动绕圈的剑以准星为原点（准星也按比例插值）
    local target = state.crosshair
    local center = (target and target:Exists()) and (target.Position + target.Velocity * frac) or nil
    local origins = {}
    for i, s in ipairs(state.swords) do
        origins[i] = Sword.Origin(s, playerOrigin, frac, center)
    end

    -- 先画所有光带，再画粒子和剑，避免光带盖住别的剑
    if beamRight and Settings.Get("trail") then
        for i, s in ipairs(state.swords) do
            drawTrail(s, s.progress + s.rate * C.UPDATES_PER_FRAME * frac, origins[i].X, origins[i].Y)
        end
    end
    drawParticles(state.particles, frac)
    for i, s in ipairs(state.swords) do
        drawSwordWithAfterimages(s, s.progress + s.rate * C.UPDATES_PER_FRAME * frac, origins[i].X, origins[i].Y)
    end
end

return Render
