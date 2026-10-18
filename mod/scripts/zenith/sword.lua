-- 飞剑的生成、轨迹和命中判定。轨迹公式移植自泰拉原版天顶剑弹幕（AI 182, FinalFractal）。
-- 一把剑只是一张数据表，位置由“进度”直接算出，不依赖历史记录，所以拖尾和残影可以在任意进度上重算。

local C = include("scripts.zenith.config")
local Profiles = include("scripts.zenith.profiles")
local TearEffects = include("scripts.zenith.tearflags")
local Weapons = include("scripts.zenith.weapons")

local Sword = {}
-- 每个文件 include 到的配置表是各自独立的一份；游戏内测试要在运行时改飞剑用的数值（例如卢多维科转速）时改这一份
Sword.Config = C

local PI, TAU, HALF_PI = math.pi, math.pi * 2, math.pi / 2
local K = C.PX_TO_UNIT
local SCREEN_PER_UNIT = 0.65 -- 以撒 1 格 = 40 世界单位 = 26 像素
-- 贴图相关的长度（刀身、判定）：泰拉像素 → 贴图缩小一半 → 乘绘制倍率 → 换算成世界单位
Sword.VISUAL_PX_TO_UNIT = 0.5 * C.SWORD_SCALE / SCREEN_PER_UNIT
Sword.BLADE_HALF = C.BLADE_HALF_PX * Sword.VISUAL_PX_TO_UNIT

local function clamp01(x)
    if x < 0 then return 0 elseif x > 1 then return 1 end
    return x
end

-- 对应泰拉的 Utils.GetLerpValue(from, to, value, clamped: true)
local function lerpValue(from, to, value)
    return clamp01((value - from) / (to - from))
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

Sword.Clamp01 = clamp01
Sword.LerpValue = lerpValue

-- 返回世界坐标 x, y，剑的旋转（弧度，刀尖方向 = rot - π/2）和贴图朝向（1 / -1）
function Sword.Pose(s, progress, ox, oy)
    -- 卢多维科联动：围着原点（准星）转圈，刀尖朝外；刚出手时半径从 0 迅速张开
    if s.orbit then
        local angle = s.phase + s.spin * (progress / C.PATH_END) * TAU * C.LUDO_TURNS
        local r = (s.orbit == "player" and C.TINY_PLANET_RADIUS or C.LUDO_RADIUS) * lerpValue(0, 8, progress)
        return ox + math.cos(angle) * r, oy + math.sin(angle) * r, angle + HALF_PI, s.spin
    end
    local t2 = clamp01(progress / C.PATH_END)
    local dir = s.vx > 0 and 1 or -1
    local theta = PI + dir * t2 * TAU

    local a = s.vLen + lerpValue(0.5, 1, t2) * C.MAJOR_GROW_PX * K
    if a < C.MIN_MAJOR_PX * K then
        a = C.MIN_MAJOR_PX * K
    end
    local b = s.ai0 * K * lerp(2, 1, s.near)

    local sx, sy = math.cos(theta) * a, math.sin(theta) * b
    local cp, sp = s.cosPhi, s.sinPhi
    local fade = 1 - lerpValue(0, 0.5, t2)
    local x = ox + s.vx + sx * cp - sy * sp + fade * dir * -a * 0.1
    local y = oy + s.vy + sx * sp + sy * cp + fade * -s.ai0 * K * 0.3

    if s.ai0 < 0 then
        return x, y, PI + dir * t2 * -TAU + s.phi + HALF_PI, -dir
    end
    return x, y, theta + s.phi + HALF_PI, dir
end

local function isTarget(e)
    return e:IsVulnerableEnemy() and e:IsActiveEnemy(false) and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
end

local PROP_TYPES, GRID_TYPES = {}, {}
for _, t in ipairs(C.PROP_TYPES) do
    PROP_TYPES[t] = true
end
for _, t in ipairs(C.GRID_TYPES) do
    GRID_TYPES[t] = true
end

-- enemies：可锁定、会显示伤害数字的敌人；props：火堆、TNT 等只会被打坏的场景物件；
-- bombs：会被推动的炸弹（胎儿博士的炸弹和眼泪一样不受影响）；pickups：英灵剑能拾取 / 打开的掉落物
local COLLECTABLE = {
    [PickupVariant.PICKUP_HEART] = true, [PickupVariant.PICKUP_COIN] = true, [PickupVariant.PICKUP_KEY] = true,
    [PickupVariant.PICKUP_BOMB] = true, [PickupVariant.PICKUP_POOP] = true, [PickupVariant.PICKUP_GRAB_BAG] = true,
    [PickupVariant.PICKUP_PILL] = true, [PickupVariant.PICKUP_LIL_BATTERY] = true, [PickupVariant.PICKUP_TAROTCARD] = true,
    [PickupVariant.PICKUP_TRINKET] = true,
}
local CHESTS = {
    [PickupVariant.PICKUP_CHEST] = true, [PickupVariant.PICKUP_BOMBCHEST] = true, [PickupVariant.PICKUP_SPIKEDCHEST] = true,
    [PickupVariant.PICKUP_ETERNALCHEST] = true, [PickupVariant.PICKUP_MIMICCHEST] = true, [PickupVariant.PICKUP_OLDCHEST] = true,
    [PickupVariant.PICKUP_WOODENCHEST] = true, [PickupVariant.PICKUP_MEGACHEST] = true, [PickupVariant.PICKUP_HAUNTEDCHEST] = true,
    [PickupVariant.PICKUP_LOCKEDCHEST] = true, [PickupVariant.PICKUP_REDCHEST] = true, [PickupVariant.PICKUP_MOMSCHEST] = true,
}
Sword.CHESTS = CHESTS

function Sword.GetTargets()
    local enemies, props, bombs, pickups = {}, {}, {}, {}
    for _, e in ipairs(Isaac.GetRoomEntities()) do
        if isTarget(e) then
            enemies[#enemies + 1] = e
        elseif PROP_TYPES[e.Type] then
            props[#props + 1] = e
        elseif e.Type == C.BOMB_TYPE then
            local bomb = e:ToBomb()
            if bomb and not bomb.IsFetus then
                bombs[#bombs + 1] = e
            end
        elseif e.Type == EntityType.ENTITY_PICKUP and (COLLECTABLE[e.Variant] or CHESTS[e.Variant]) then
            local pickup = e:ToPickup()
            if pickup and pickup.Price == 0 and not pickup:IsShopItem() then
                pickups[#pickups + 1] = pickup
            end
        end
    end
    return enemies, props, bombs, pickups
end

-- 对应 Player.GetZenithTarget：离准星最近、且在半径内的敌人
local function findTarget(enemies, pos, radius)
    local best, bestDist = nil, radius
    for _, e in ipairs(enemies) do
        local d = e.Position:Distance(pos)
        if d < bestDist then
            best, bestDist = e, d
        end
    end
    return best
end

local function randomInCircle(rng, radius)
    local angle = rng:RandomFloat() * TAU
    local r = math.sqrt(rng:RandomFloat()) * radius
    return Vector(math.cos(angle) * r, math.sin(angle) * r)
end

-- index：0 = 天顶剑本体（直飞准星，不追踪）；1 = 锁定准星附近的敌人；2 = 锁定敌人并随机偏移
-- shot：出手时确定的参数
--   size       剑的大小倍率（贴图、判定、拖尾宽度一起缩放）
--   flags      这把剑继承的泪弹标记（GetTearHitParams 的结果）
--   critChance 这把剑每次命中的暴击率（随幸运变化）
function Sword.Create(origin, crosshair, index, enemies, rng, shot)
    shot = shot or {}
    local aim = crosshair - origin
    local profileId = Profiles.ZENITH
    -- 追踪泪弹：天顶剑本体也锁定准星附近的敌人（不加随机偏移）
    if index == 0 and TearEffects.Has(shot.flags, "TEAR_HOMING") then
        local enemy = findTarget(enemies, crosshair, C.HOMING_RADIUS_PX * K)
        if enemy then
            aim = enemy.Position - origin
        end
    end
    if index > 0 then
        profileId = Profiles.RandomId(rng)
        local enemy = findTarget(enemies, crosshair, C.HOMING_RADIUS_PX * K)
        if enemy then
            aim = enemy.Position - origin
        end
        if index == 2 or not enemy then
            aim = aim + randomInCircle(rng, C.RANDOM_OFFSET_PX * K)
        end
    end

    -- 妈刀 / 英灵剑联动：这把剑换成原版模型
    local special = shot.special or (shot.knife and "knife") or nil
    if special == "knife" then
        profileId = Profiles.KNIFE
    elseif special == "spirit" then
        profileId = Profiles.SPIRIT_SWORD
    elseif special == "beam" then
        profileId = Profiles.SWORD_BEAM
    end

    local v = aim * 0.5
    local s = {
        profile = Profiles.Get(profileId),
        vx = v.X,
        vy = v.Y,
        vLen = v:Length(),
        ai0 = rng:RandomInt(C.ELLIPSE_WIDTH_PX * 2 + 1) - C.ELLIPSE_WIDTH_PX,
        progress = 0,
        updates = 0,
        hits = {},
        gridHits = {},
        pushed = {},
        size = shot.size or 1,
        damageMult = shot.damageMult or 1,
        anchor = shot.anchor, -- 发出者是跟班时记下它，轨迹跟着跟班走
        flags = shot.flags,
        critChance = shot.critChance or 0,
        explosive = TearEffects.Has(shot.flags, "TEAR_EXPLOSIVE"),
        bone = TearEffects.Has(shot.flags, "TEAR_BONE"),         -- 复合骨折：第一次命中敌人时碎骨
        backstab = TearEffects.Has(shot.flags, "TEAR_BACKSTAB"), -- 背刺：每次命中都算背刺（伤害 ×2，流血另由 TearEffects 施加）
        acid = TearEffects.Has(shot.flags, "TEAR_ACID"),         -- 硫酸：打碎石头、打开隐藏房的墙
        rockBreak = TearEffects.Has(shot.flags, "TEAR_ACID") or TearEffects.Has(shot.flags, "TEAR_ROCK"), -- 硫酸、泰拉：打碎石头
        proxyFlags = TearEffects.ProxyFlags(shot.flags),         -- 命中特效替身（小魔角、圣光等，第一次命中时放替身眼泪）
        wide = shot.wide,                                        -- 双瞳：判定变宽
        proptosis = shot.proptosis,                              -- 眼球突出：伤害随敌人离角色的距离衰减
        belial = TearEffects.Has(shot.flags, "TEAR_BELIAL"),     -- 贝利尔之眼：命中第二个及之后的敌人 ×2
        attractor = TearEffects.Has(shot.flags, "TEAR_ATTRACTOR"), -- 奇异吸引子：命中时把周围敌人拉过来
        glow = TearEffects.Has(shot.flags, "TEAR_GLOW"),         -- 神性：剑带光环
        auraHits = {},
        enemyCount = 0,
        terraMult = shot.terraMult or 1,                         -- 泰拉：每把剑伤害随机浮动（取游戏给这颗“虚拟眼泪”的伤害）
        deadEyeMult = shot.deadEyeMult or 1,                     -- 死亡之眼：出手时的连击层数加成
        tearScale = shot.tearScale,                              -- 鬼椒 / 鸟眼椒火焰的大小
        mulligan = shot.mulligan,                                -- 穆里根：第一次命中敌人时概率生成蓝苍蝇
        guppy = shot.guppy,                                      -- 猫套：第一次命中敌人时概率在角色身边生成蓝苍蝇
        special = special,                                       -- 妈刀 / 英灵剑 / 剑气：单独计算伤害，只有本体判定，每个敌人只打一次
        knife = special == "knife",
        collects = special == "spirit" or special == "beam",     -- 英灵剑和剑气能拾取掉落物、打开箱子
        collected = {},
        knifeMult = shot.knifeMult or 1,
        link = shot.link,                                        -- 攻击类道具联动（weapons.lua）
        linkMult = shot.linkMult or 1,
        color = Weapons.Color(shot.link),                        -- 硫磺火血光：拖尾、星闪、粒子换成血红色（nil = 用剑本身的颜色）
    }
    -- 卢多维科联动：围着准星转圈（随机起始角度、随机转向），转动速度固定
    if shot.orbit then
        s.orbit = shot.orbit -- "crosshair" = 卢多维科（绕准星），"player" = 小行星（绕角色）
        s.phase = rng:RandomFloat() * TAU
        s.spin = rng:RandomInt(2) == 0 and 1 or -1
    end
    -- 剑沿椭圆的转向（屏幕坐标 y 向下）：决定拖尾亮边在条带的哪一侧
    s.tipRight = (s.vx > 0 and 1 or -1) * (s.ai0 >= 0 and 1 or -1) > 0
    if s.orbit then
        s.tipRight = s.spin > 0
    end
    s.phi = math.atan(s.vy, s.vx)
    s.cosPhi, s.sinPhi = math.cos(s.phi), math.sin(s.phi)
    -- 距离越远飞得越慢
    s.near = lerpValue(C.RATE_DISTANCE_PX, 0, s.vLen * 2 / K)
    s.rate = s.orbit and C.LUDO_RATE or lerp(C.RATE_FAR, C.RATE_NEAR, s.near)
    return s
end

-- 点到线段的距离
local function segmentDistance(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = clamp01(((px - ax) * dx + (py - ay) * dy) / len2)
    end
    local cx, cy = ax + dx * t - px, ay + dy * t - py
    return math.sqrt(cx * cx + cy * cy)
end

local function bladeHits(s, progress, ox, oy, e)
    local x, y, rot = Sword.Pose(s, progress, ox, oy)
    local half = Sword.BLADE_HALF * s.size
    local dx, dy = math.cos(rot - HALF_PI) * half, math.sin(rot - HALF_PI) * half
    local p = e.Position
    return segmentDistance(p.X, p.Y, x - dx, y - dy, x + dx, y + dy) <= e.Size + C.BLADE_THICKNESS * 0.5 * s.size * (s.wide and C.PUPULA_WIDTH or 1)
end

-- 当前位置 + 4 个残影位置都参与判定（与原版一致）。剑消失后不再造成伤害。
local function collides(s, ox, oy, e)
    if s.progress <= C.PATH_END + 8 and bladeHits(s, s.progress, ox, oy, e) then
        return true
    end
    -- 妈刀、英灵剑、剑气的残影不造成伤害
    if s.special then
        return false
    end
    for i = C.AFTERIMAGE_STEP - 1, C.TRAIL_CACHE - 1, C.AFTERIMAGE_STEP do
        local t = s.progress - i
        if t >= 0 and t <= C.PATH_END then
            local past = s.progress - i * s.rate
            if past >= 0 and bladeHits(s, past, ox, oy, e) then
                return true
            end
        end
    end
    return false
end

-- 这把剑单次命中的基础伤害（妈刀 / 英灵剑 / 剑气不吃天顶剑倍率，只乘跟班倍率）：
--   妈刀 = 角色伤害 × 6；英灵剑 = 3.5 + 角色伤害 × 3；剑气 = 5.5 + 角色伤害 × 4；普通剑 = 角色伤害 × 0.35 × 剑的倍率
local function baseDamage(player, s)
    if s.special == "knife" then
        return player.Damage * C.KNIFE_DAMAGE_MULT * s.knifeMult
    elseif s.special == "spirit" then
        return (C.SPIRIT_SWORD_DAMAGE_ADD + player.Damage * C.SPIRIT_SWORD_DAMAGE_MULT) * s.knifeMult
    elseif s.special == "beam" then
        return (C.SWORD_BEAM_DAMAGE_ADD + player.Damage * C.SWORD_BEAM_DAMAGE_MULT) * s.knifeMult
    end
    return player.Damage * C.DAMAGE_MULT * s.damageMult
end

-- 眼球突出：按命中时敌人离角色的距离，在实测曲线上插值出伤害倍率
local function proptosisMult(dist)
    local curve = C.PROPTOSIS_CURVE
    for i = 2, #curve do
        if dist <= curve[i][1] then
            local a, b = curve[i - 1], curve[i]
            return a[2] + (b[2] - a[2]) * clamp01((dist - a[1]) / (b[1] - a[1]))
        end
    end
    return curve[#curve][2]
end

-- 返回实际伤害和是否暴击（妈刀、英灵剑、剑气没有天顶剑的暴击）。mult：额外倍率（硫磺标记、贝利尔之眼）。
-- proxy 为 true 时这一下的伤害交给替身眼泪（命中特效替身），剑本身不再造成伤害
local function hit(player, s, e, ox, oy, rng, mult, proxy)
    local damage = baseDamage(player, s) * (mult or 1) * (s.backstab and C.BACKSTAB_MULT or 1) * s.terraMult * s.deadEyeMult
    if s.proptosis then
        damage = damage * proptosisMult(e.Position:Distance(player.Position))
    end
    local crit = not s.special and rng:RandomFloat() < s.critChance
    if crit then
        damage = damage * C.CRIT_MULT
    end
    if not (proxy and TearEffects.SpawnProxy(e, player, s.proxyFlags, damage)) then
        e:TakeDamage(damage, 0, EntityRef(player), 0)
    end
    if not e:IsBoss() then
        local push = e.Position - Vector(ox, oy)
        if push:LengthSquared() > 0 then
            e:AddVelocity(push:Resized(C.KNOCKBACK))
        end
    end
    return damage, crit
end

-- 和眼泪一样打坏地形里的大便、TNT：沿刀身取 5 个点检查所在格子
-- 硫酸：能打碎的石头类地形（普通 / 有色 / 炸弹石 / 罐子类 / 超级隐藏房标记石 / 尖刺石 / 骷髅 / 金矿石；金属块不行）
local ACID_ROCKS = { [2] = true, [4] = true, [5] = true, [6] = true, [22] = true, [25] = true, [26] = true, [27] = true }
local SECRET_ROOMS = { [RoomType.ROOM_SECRET] = true, [RoomType.ROOM_SUPERSECRET] = true }

local function hitGrids(player, s, ox, oy, damage)
    if s.progress > C.PATH_END + 8 then
        return
    end
    local room = Game():GetRoom()
    local x, y, rot = Sword.Pose(s, s.progress, ox, oy)
    local half = Sword.BLADE_HALF * s.size
    local bx, by = math.cos(rot - HALF_PI) * half, math.sin(rot - HALF_PI) * half
    for k = -2, 2 do
        local point = Vector(x + bx * k * 0.5, y + by * k * 0.5)
        local index = room:GetGridIndex(point)
        if index >= 0 and (s.gridHits[index] or 0) <= s.updates then
            local grid = room:GetGridEntity(index)
            local t = grid and grid:GetType()
            if t and GRID_TYPES[t] then
                s.gridHits[index] = s.updates + C.HIT_COOLDOWN_UPDATES
                room:DamageGrid(index, damage)
            elseif t and s.rockBreak and ACID_ROCKS[t] and grid.CollisionClass ~= GridCollisionClass.COLLISION_NONE then
                -- 硫酸、泰拉：和原版眼泪一样直接打碎石头
                s.gridHits[index] = s.updates + C.HIT_COOLDOWN_UPDATES
                room:DestroyGrid(index, true)
            end
        end
        -- 硫酸：刀身碰到隐藏房 / 超级隐藏房的墙时打开（准星限制在房间内，所以按离门 40 以内算碰到）
        if s.acid then
            for slot = 0, DoorSlot.NUM_DOOR_SLOTS - 1 do
                local door = room:GetDoor(slot)
                if door and SECRET_ROOMS[door.TargetRoomType] and not door:IsOpen() and door.Position:Distance(point) < 40 then
                    door:TryBlowOpen(true, player)
                end
            end
        end
    end
end

-- 原版 StripDust：在刀身外半段随机位置生成粒子，沿剑的运动方向飞出
local function spawnDust(s, ox, oy, particles, rng)
    if rng:RandomInt(C.DUST_CHANCE) ~= 0 then
        return
    end
    local x, y, rot, dir = Sword.Pose(s, s.progress, ox, oy)
    local p = s.color or s.profile
    local bladeHalf = s.profile.blade * 0.5 * Sword.VISUAL_PX_TO_UNIT * s.size
    local bx, by = math.cos(rot - HALF_PI), math.sin(rot - HALF_PI)
    local angle = rot - HALF_PI + HALF_PI * dir
    for _ = 1, rng:RandomInt(3) + 1 do
        local along = bladeHalf * lerp(0.5, 1, rng:RandomFloat())
        local speed = lerp(C.DUST_SPEED_PX[1], C.DUST_SPEED_PX[2], rng:RandomFloat()) * 2 * K
        local life = rng:RandomInt(C.DUST_LIFE[2] - C.DUST_LIFE[1] + 1) + C.DUST_LIFE[1]
        local white = rng:RandomFloat() * 0.3
        particles[#particles + 1] = {
            x = x + bx * along,
            y = y + by * along,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            life = life,
            maxLife = life,
            r = lerp(p.r, 1, white),
            g = lerp(p.g, 1, white),
            b = lerp(p.b, 1, white),
        }
    end
end

function Sword.UpdateParticles(particles)
    for i = #particles, 1, -1 do
        local d = particles[i]
        d.life = d.life - 1
        if d.life <= 0 then
            table.remove(particles, i)
        else
            d.x, d.y = d.x + d.vx, d.y + d.vy
            d.vx, d.vy = d.vx * C.DUST_DRAG, d.vy * C.DUST_DRAG
        end
    end
end

local function hitEntities(player, s, ox, oy, list, rng, onHit)
    for _, e in ipairs(list) do
        if e:Exists() and not e:IsDead() then
            local key = GetPtrHash(e)
            if (s.hits[key] or 0) <= s.updates and collides(s, ox, oy, e) then
                local firstOnThis = s.hits[key] == nil
                -- 妈刀、英灵剑、剑气每个敌人只打一次
                s.hits[key] = s.special and math.huge or (s.updates + C.HIT_COOLDOWN_UPDATES)
                -- 硫磺火联动：命中前已被硫磺标记的敌人受到更高伤害（只对敌人）；贝利尔之眼：第二个及之后的敌人 ×2
                local wasMarked = onHit and Weapons.IsMarked(e)
                local mult = onHit and Weapons.DamageMult(s, e) or 1
                if onHit and firstOnThis then
                    if s.belial and s.enemyCount >= 1 then
                        mult = mult * C.BELIAL_MULT
                    end
                    s.enemyCount = s.enemyCount + 1
                end
                -- 命中特效替身：这把剑第一次命中敌人时，伤害交给替身眼泪，由游戏触发原版效果
                local proxy = onHit and s.proxyFlags ~= nil and not s.proxyDone
                if proxy then
                    s.proxyDone = true
                end
                local damage, crit = hit(player, s, e, ox, oy, rng, mult, proxy)
                if onHit then
                    -- 奇异吸引子：把周围的其他敌人往这个敌人拉
                    if s.attractor then
                        for _, other in ipairs(list) do
                            local d = e.Position - other.Position
                            if GetPtrHash(other) ~= key and other:Exists() and d:Length() <= C.ATTRACTOR_RADIUS and d:LengthSquared() > 1 then
                                other:AddVelocity(d:Resized(C.ATTRACTOR_PULL))
                            end
                        end
                    end
                    Weapons.AfterHit(player, s, e, wasMarked, list)
                    -- 科技：每把剑第一次命中敌人时从角色身上射激光打它
                    if not s.firstHitDone then
                        s.firstHitDone = true
                        Weapons.OnFirstHit(player, s, e)
                    end
                    -- 只有敌人才带 onHit：上状态、吐根爆炸、音效和伤害数字
                    TearEffects.Apply(e, s.flags, player)
                    if s.explosive then
                        s.explosive = false
                        TearEffects.Explode(e, player, s.damageMult)
                    end
                    -- 碎骨按“一把剑相当于一颗眼泪”：剑会多次穿过敌人，只在第一次命中时碎一次
                    if s.bone then
                        s.bone = false
                        TearEffects.BoneShards(e, player, baseDamage(player, s), rng)
                    end
                    -- 穆里根同样只在第一次命中时判定一次
                    if s.mulligan then
                        s.mulligan = false
                        if rng:RandomFloat() < C.MULLIGAN_CHANCE then
                            player:AddBlueFlies(1, e.Position, nil)
                        end
                    end
                    -- 猫套：同样只判定一次，苍蝇和原版一样生成在角色身边
                    if s.guppy then
                        s.guppy = false
                        if rng:RandomFloat() < C.GUPPY_CHANCE then
                            player:AddBlueFlies(1, player.Position, nil)
                        end
                    end
                    onHit(e, damage, crit)
                end
            end
        end
    end
end

-- 英灵剑 / 剑气：像原版挥剑一样，碰到掉落物就拾取（挪到角色身上，由角色自己捡起），碰到箱子就打开
local function collectPickups(player, s, ox, oy, pickups)
    for _, pickup in ipairs(pickups) do
        local key = GetPtrHash(pickup)
        if not s.collected[key] and pickup:Exists() and collides(s, ox, oy, pickup) then
            s.collected[key] = true
            if CHESTS[pickup.Variant] then
                pcall(function() pickup:TryOpenChest(player) end)
            else
                pickup.Position = player.Position
                pickup.Velocity = Vector.Zero
            end
        end
    end
end

-- 普通眼泪（变体 0）的质量：取自游戏的实体配置，只读一次
local tearMass
function Sword.TearMass()
    if not tearMass then
        local ok, mass = pcall(function() return EntityConfig.GetEntity(2, 0):GetMass() end)
        tearMass = (ok and type(mass) == "number" and mass > 0) and mass or C.TEAR_MASS_FALLBACK
    end
    return tearMass
end

-- 和眼泪一样推动炸弹：每把剑对同一颗炸弹只推一次（相当于这把剑的虚拟眼泪撞上炸弹），方向是出手时的瞄准方向。
-- 实测原版：眼泪撞炸弹后，炸弹沿碰撞方向获得 (眼泪速度 - 炸弹迎面速度) × 眼泪质量 / (眼泪质量 + 炸弹质量)，
-- 且发生在炸弹自己更新之后。所以这里先记下，等 MC_POST_BOMB_UPDATE 时再按炸弹当时的速度结算（Sword.ApplyBombPush）
local pendingPushes = {}
local function pushBombs(player, s, ox, oy, bombs)
    for _, e in ipairs(bombs) do
        local key = GetPtrHash(e)
        if not s.pushed[key] and e:Exists() and collides(s, ox, oy, e) then
            s.pushed[key] = true
            local dir = Vector(s.vx, s.vy)
            if dir:LengthSquared() > 0 then
                pendingPushes[#pendingPushes + 1] = {
                    key = key, entity = e, dir = dir:Normalized(), speed = player.ShotSpeed * C.TEAR_BASE_SPEED,
                }
            end
        end
    end
end

-- 炸弹更新之后调用：结算这颗炸弹待处理的推力
function Sword.ApplyBombPush(bomb)
    local key = GetPtrHash(bomb)
    for i = #pendingPushes, 1, -1 do
        local push = pendingPushes[i]
        if push.key == key then
            table.remove(pendingPushes, i)
            local closing = push.speed - (bomb.Velocity.X * push.dir.X + bomb.Velocity.Y * push.dir.Y)
            if closing > 0 then
                local m = Sword.TearMass()
                -- 直接改速度：AddVelocity 会再除以实体的 Friction（超级即爆炸弹为 0.8，实测推力会多 25%）
                bomb.Velocity = bomb.Velocity + push.dir * (closing * m / (m + math.max(bomb.Mass, 0)) * C.BOMB_PUSH_MULT)
            end
        end
    end
end

-- 丢掉已经不存在的炸弹的推力（每帧调用）；clearAll 为 true 时全部清空（换房间）
function Sword.PruneBombPushes(clearAll)
    for i = #pendingPushes, 1, -1 do
        if clearAll or not pendingPushes[i].entity:Exists() then
            table.remove(pendingPushes, i)
        end
    end
end

-- 剑的轨迹原点：发出者是跟班时用跟班的位置（frac 为渲染插值比例），
-- 跟班消失后停在最后记下的位置把轨迹走完；否则用角色原点 fallback
-- center：卢多维科联动绕圈的剑以准星为原点（准星没了就停在最后记下的位置）
function Sword.Origin(s, fallback, frac, center)
    if s.orbit == "crosshair" then
        if center then
            if not frac then
                s.lastOrigin = center
            end
            return center
        end
        return s.lastOrigin or fallback
    end
    local a = s.anchor
    if a and a:Exists() then
        local pos = a.Position + a.Velocity * (frac or 0) + C.ORIGIN_OFFSET
        if not frac then
            s.lastOrigin = pos
        end
        return pos
    end
    if a then
        return s.lastOrigin or fallback
    end
    return fallback
end

-- 推进一帧（= 泰拉的 UPDATES_PER_FRAME 次更新）。返回 false 表示这把剑已结束。
-- onHit(敌人, 伤害, 是否暴击)：只对敌人调用，用于音效和伤害数字
function Sword.Update(player, s, origin, enemies, props, bombs, particles, rng, onHit, pickups)
    local ox, oy = origin.X, origin.Y
    for _ = 1, C.UPDATES_PER_FRAME do
        s.progress = s.progress + s.rate
        s.updates = s.updates + 1
        if s.progress >= C.LIFE_END then
            Weapons.UpdateRing(player, s, nil, false)
            return false
        end
        -- 飞到准星处（轨迹中点）：博士胎儿放炸弹，鬼椒 / 鸟眼椒放火焰
        if s.link and Weapons.HasApex(s.link) and not s.apexDone and s.progress >= C.PATH_END / 2 then
            s.apexDone = true
            local x, y = Sword.Pose(s, C.PATH_END / 2, ox, oy)
            Weapons.OnApex(player, s, Vector(x, y))
        end
        if s.progress < C.PATH_END then
            spawnDust(s, ox, oy, particles, rng)
        end
        hitEntities(player, s, ox, oy, enemies, rng, onHit)
        -- 神性：剑带光环，半径内的敌人每隔一段时间受固定伤害（原版光环 2 点）
        if s.glow and s.progress <= C.PATH_END + 8 then
            local x, y = Sword.Pose(s, s.progress, ox, oy)
            local center = Vector(x, y)
            for _, e in ipairs(enemies) do
                local key = GetPtrHash(e)
                if e:Exists() and not e:IsDead() and (s.auraHits[key] or 0) <= s.updates
                    and e.Position:Distance(center) <= C.GODHEAD_RADIUS * s.size + e.Size then
                    s.auraHits[key] = s.updates + C.GODHEAD_INTERVAL
                    e:TakeDamage(C.GODHEAD_DAMAGE, 0, EntityRef(player), 0)
                end
            end
        end
        hitEntities(player, s, ox, oy, props, rng, nil)
        pushBombs(player, s, ox, oy, bombs)
        if s.collects and pickups then
            collectPickups(player, s, ox, oy, pickups)
        end
        hitGrids(player, s, ox, oy, math.max(1, math.floor(player.Damage * C.DAMAGE_MULT + 0.5)))
    end
    -- 科技 X：激光环跟着剑走，剑回到角色身边（不再造成伤害）时消失
    if s.link and s.link.techX then
        local x, y = Sword.Pose(s, s.progress, ox, oy)
        Weapons.UpdateRing(player, s, Vector(x, y), s.progress <= C.PATH_END + 8)
    end
    return true
end

return Sword
