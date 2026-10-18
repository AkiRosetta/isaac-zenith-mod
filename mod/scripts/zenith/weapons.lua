-- 阶段 B：攻击类道具联动。攻击方式仍是飞剑，被覆盖的武器给飞剑追加原版特征：
--   硫磺火 / 阿撒泻勒：剑裹血光，命中时给敌人上原版硫磺标记，被标记的敌人受到这把剑的伤害提高；
--                     被标记的敌人被剑打死时把标记传染给周围敌人并造成一次伤害（照搬原版硫磺火击杀的传染）
--   科技：每把剑第一次命中敌人时，从角色（或跟班）的眼睛射一道细激光直接打向这个敌人
--   科技 2：准星显示时，从角色眼睛连一道持续的细激光到准星（Weapons.UpdateTech2）
--   科技 X：每把剑带着一个小激光环飞（Weapons.UpdateRing）
--   博士胎儿：每个射击间隔在剑飞到的准星处放一颗炸弹
--   史诗胎儿：按原版间隔在准星处落导弹（Weapons.UpdateEpicFetus）
-- 数值和原则见 config.lua。生成的激光、炸弹都标记 ZenithOwned，测试和“跟班漏出的原生攻击”检测不把它们算进去。

local C = include("scripts.zenith.config")
local TearEffects = include("scripts.zenith.tearflags")

local Weapons = {}

local TECH_LASER = 2

local function markOwned(e)
    if e then
        e:GetData().ZenithOwned = true
    end
    return e
end

-- 生成期间打上标记（main.lua OnMimicLeak 在激光出生回调里检查它）
local function spawning(player, fn)
    local data = player:GetData()
    data.ZenithSpawningOwn = true
    local ok, result = pcall(fn)
    data.ZenithSpawningOwn = nil
    if not ok then
        Isaac.DebugString("[Zenith] weapon synergy failed: " .. tostring(result))
        return nil
    end
    return result
end

-- 出剑时决定这把剑带哪些联动。firstOfInterval：这把剑是不是本次射击间隔里的第 1 把（博士胎儿只放一颗）。
-- 阿撒泻勒（含里阿撒泻勒）拿到硫磺火道具也仍是弱化版：原本的攻击方式被覆盖，不额外叠加（用户决定）
local function brimstoneKind(player)
    local t = player:GetPlayerType()
    if t == PlayerType.PLAYER_AZAZEL or t == PlayerType.PLAYER_AZAZEL_B then
        return "azazel"
    elseif player:HasCollectible(CollectibleType.COLLECTIBLE_BRIMSTONE) then
        return "full"
    end
    return nil
end

function Weapons.Roll(player, firstOfInterval, rng)
    local brimstone = brimstoneKind(player)
    local tech = player:HasCollectible(CollectibleType.COLLECTIBLE_TECHNOLOGY)
    local drFetus = firstOfInterval and player:HasCollectible(CollectibleType.COLLECTIBLE_DR_FETUS) or false
    local techX = player:HasCollectible(CollectibleType.COLLECTIBLE_TECH_X)
    -- 鬼椒 / 鸟眼椒：每把剑按原版概率在准星处生成火焰（两件都有时各自判定）
    local chance = TearEffects.LuckChance(C.PEPPER_CHANCE, player.Luck)
    local blueFlame = player:HasCollectible(CollectibleType.COLLECTIBLE_GHOST_PEPPER) and rng and rng:RandomFloat() < chance or false
    local redFlame = player:HasCollectible(CollectibleType.COLLECTIBLE_BIRDS_EYE) and rng and rng:RandomFloat() < chance or false
    if not (brimstone or tech or drFetus or techX or blueFlame or redFlame) then
        return nil
    end
    return { brimstone = brimstone, tech = tech, drFetus = drFetus, techX = techX, blueFlame = blueFlame, redFlame = redFlame }
end

-- 剑飞到准星处时要不要触发（博士胎儿、鬼椒、鸟眼椒）
function Weapons.HasApex(link)
    return link ~= nil and (link.drFetus or link.blueFlame or link.redFlame) or false
end

-- 血光颜色（拖尾、星闪、粒子），没有硫磺火联动时返回 nil
function Weapons.Color(link)
    local c = link and (link.brimstone == "full" and C.BRIMSTONE_COLOR or link.brimstone == "azazel" and C.AZAZEL_COLOR)
    if c then
        return { r = c[1] / 255, g = c[2] / 255, b = c[3] / 255 }
    end
    return nil
end

local function isMarked(e)
    return e:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED)
end

-- 命中前调用：被硫磺标记的敌人受到带硫磺火联动的剑的伤害倍率（没有联动或没被标记时为 1）
function Weapons.DamageMult(s, enemy)
    local b = s.link and s.link.brimstone
    if b and isMarked(enemy) then
        return b == "azazel" and C.AZAZEL_MARK_MULT or C.BRIMSTONE_MARK_MULT
    end
    return 1
end

local function addMark(player, e)
    pcall(function() e:AddBrimstoneMark(EntityRef(player), C.BRIMSTONE_MARK_DURATION) end)
end

-- 被标记的敌人被剑打死：把标记传染给周围敌人，并各造成一次 角色伤害 × 2 + 3（原版数值）；被传染打死的敌人继续传染
-- （原版只有被硫磺火打死才传染，这里对应为被剑打死，用户决定）
local function spread(player, origin, enemies)
    local queue, done, n = { origin }, { [GetPtrHash(origin)] = true }, 0
    local damage = player.Damage * C.BRIMSTONE_SPREAD_DAMAGE_MULT + C.BRIMSTONE_SPREAD_DAMAGE_ADD
    while #queue > 0 and n < 30 do
        local dead = table.remove(queue, 1)
        n = n + 1
        for _, e in ipairs(enemies) do
            local key = GetPtrHash(e)
            if not done[key] and e:Exists() and not e:IsDead() and e.Position:Distance(dead.Position) <= C.BRIMSTONE_SPREAD_RADIUS then
                addMark(player, e)
                e:TakeDamage(damage, 0, EntityRef(player), 0)
                if e:HasMortalDamage() then
                    done[key] = true
                    queue[#queue + 1] = e
                end
            end
        end
    end
end

-- 命中后调用：上（刷新）硫磺标记；命中前已被标记、这一下致死时触发传染
function Weapons.AfterHit(player, s, enemy, wasMarked, enemies)
    if not (s.link and s.link.brimstone) then
        return
    end
    if wasMarked and enemy:HasMortalDamage() then
        spread(player, enemy, enemies)
    end
    addMark(player, enemy)
end

Weapons.IsMarked = isMarked

-- 激光从眼睛射出：原版科技激光的高度偏移（GetLaserOffset），读不到时用固定值
local function eyeOffset(player, dir)
    local ok, offset = pcall(function() return player:GetLaserOffset(LaserOffset.LASER_TECH1_OFFSET, dir) end)
    return ok and offset or Vector(0, -20)
end

local function shootLaser(player, variant, pos, dir, timeout, damage, offset)
    local laser = EntityLaser.ShootAngle(variant, pos, dir:GetAngleDegrees(), timeout, offset or Vector.Zero, player)
    if laser then
        laser.DisableFollowParent = true
        laser.CollisionDamage = damage
    end
    return markOwned(laser)
end

-- 科技：这把剑第一次命中敌人时，从角色（跟班的剑从跟班）的眼睛射一道细激光打向它
function Weapons.OnFirstHit(player, s, enemy)
    if not (s.link and s.link.tech) then
        return
    end
    local from = (s.anchor and s.anchor:Exists()) and s.anchor.Position or player.Position
    local dir = enemy.Position - from
    if dir:LengthSquared() == 0 then
        return
    end
    spawning(player, function()
        dir = dir:Normalized()
        shootLaser(player, TECH_LASER, from, dir, C.TECH_TIMEOUT, player.Damage * C.TECH_DAMAGE * (s.linkMult or 1), eyeOffset(player, dir))
    end)
end

-- 科技 2：准星显示且能攻击时，维持一道从角色眼睛连到准星的持续细激光（跟着角色移动、每帧对准准星）；否则移除
function Weapons.UpdateTech2(player, state, canAttack)
    local laser = state.tech2Laser
    local want = canAttack and state.pos and player:HasCollectible(CollectibleType.COLLECTIBLE_TECHNOLOGY_2)
    if not want then
        if laser and laser:Exists() then
            laser:Remove()
        end
        state.tech2Laser = nil
        return
    end
    local delta = state.pos - player.Position
    if delta:LengthSquared() < 1 then
        delta = Vector(1, 0)
    end
    local dir = delta:Normalized()
    if not (laser and laser:Exists()) then
        laser = spawning(player, function()
            local l = EntityLaser.ShootAngle(TECH_LASER, player.Position, dir:GetAngleDegrees(), 3, eyeOffset(player, dir), player)
            return markOwned(l)
        end)
        state.tech2Laser = laser
        if not laser then
            return
        end
    end
    laser.Timeout = 3
    laser.AngleDegrees = dir:GetAngleDegrees()
    laser:SetMaxDistance(delta:Length())
    laser.CollisionDamage = player.Damage * C.TECH2_DAMAGE
end

-- 科技 X：剑在飞时带着一个小激光环（剑回到角色身边、或剑结束时移除）。同时存在的环有上限，避免卡顿
local rings = {}
local function liveRings()
    local n = 0
    for i = #rings, 1, -1 do
        if rings[i]:Exists() then
            n = n + 1
        else
            table.remove(rings, i)
        end
    end
    return n
end
-- pos：剑当前的位置；active：剑还在“能造成伤害”的阶段
function Weapons.UpdateRing(player, s, pos, active)
    if not (s.link and s.link.techX) then
        return
    end
    local ring = s.ring
    if not active then
        if ring and ring:Exists() then
            ring:Remove()
        end
        s.ring = nil
        return
    end
    if not (ring and ring:Exists()) then
        if s.ringDone or liveRings() >= C.TECHX_MAX_RINGS then
            return
        end
        s.ringDone = true
        ring = spawning(player, function()
            -- 环的伤害只认生成时的倍率（实测之后改 CollisionDamage 无效）
            return markOwned(player:FireTechXLaser(pos, Vector.Zero, C.TECHX_RADIUS, player, C.TECHX_DAMAGE * (s.linkMult or 1)))
        end)
        if not ring then
            return
        end
        ring.DisableFollowParent = true
        rings[#rings + 1] = ring
        s.ring = ring
    end
    ring.Position, ring.Velocity = pos, Vector.Zero
    ring.Timeout = 3
end

-- 剑飞到准星处时调用一次：博士胎儿放炸弹（跟班的剑乘跟班倍率）；鬼椒 / 鸟眼椒在这里生成蓝火 / 红火，
-- 大小 = 这把剑出手时的泪弹尺寸（原版火焰大小随角色伤害变化，实测与泪弹尺寸一致：伤害 3.5 → 1.02，13.5 → 1.53）
local BLUE_FLAME, RED_FLAME = 10, 52
function Weapons.OnApex(player, s, pos)
    local link = s.link
    if not Weapons.HasApex(link) then
        return
    end
    local mult = s.linkMult or 1
    spawning(player, function()
        if link.drFetus then
            local bomb = markOwned(player:FireBomb(pos, Vector.Zero, player))
            if bomb and mult ~= 1 then
                bomb.ExplosionDamage = bomb.ExplosionDamage * mult
            end
        end
        for _, kind in ipairs({ { link.blueFlame, BLUE_FLAME }, { link.redFlame, RED_FLAME } }) do
            if kind[1] then
                local flame = markOwned(Isaac.Spawn(EntityType.ENTITY_EFFECT, kind[2], 0, pos, Vector.Zero, player))
                if flame then
                    local scale = s.tearScale or 1
                    flame.SpriteScale = Vector(scale, scale)
                end
            end
        end
    end)
end

-- 史诗胎儿：准星显示时按原版间隔在准星处召唤导弹，流程照搬原版（游戏内逐帧实测）：
--   瞄准标记计时 50（自己会播放闪烁动画），计时剩 9 时导弹从 1000 高处出现、每帧落 100，
--   落地时导弹自己爆炸、按原版造成伤害（实测 角色伤害 × 20）和音效，所以这里只负责生成，不另外造成伤害；
--   标记计时剩 21 时播放“滴滴”提示音（自己生成的标记不会自动播放）
function Weapons.UpdateEpicFetus(player, state, canAttack)
    state.strikes = state.strikes or {}
    for i = #state.strikes, 1, -1 do
        local strike = state.strikes[i]
        strike.timer = strike.timer - 1
        -- “滴滴”提示音：原版在标记计时剩 21 时开始播放（实测 SOUND_DRSREMOTE_WARNING）
        if not strike.beeped and strike.timer + C.EPIC_FETUS_FALL_FRAMES <= C.EPIC_FETUS_BEEP_AT then
            strike.beeped = true
            SFXManager():Play(SoundEffect.SOUND_DRSREMOTE_WARNING)
        end
        if strike.timer <= 0 then
            spawning(player, function()
                local rocket = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.ROCKET, 0, strike.pos, Vector.Zero, player):ToEffect()
                rocket.PositionOffset = Vector(0, -C.EPIC_FETUS_FALL_HEIGHT)
                rocket.Timeout = C.EPIC_FETUS_FALL_FRAMES
                markOwned(rocket)
            end)
            table.remove(state.strikes, i)
        end
    end

    if not player:HasCollectible(CollectibleType.COLLECTIBLE_EPIC_FETUS) then
        state.epicTimer = nil
        return
    end
    local interval = C.EPIC_FETUS_BASE_INTERVAL + player.MaxFireDelay + 1
    state.epicTimer = math.min(state.epicTimer or interval, interval)
    if canAttack and state.pos then
        state.epicTimer = state.epicTimer - 1
        if state.epicTimer <= 0 then
            state.epicTimer = interval
            local marker = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.TARGET, 0, state.pos, Vector.Zero, player):ToEffect()
            marker.Timeout = C.EPIC_FETUS_TARGET_TIMEOUT
            markOwned(marker)
            state.strikes[#state.strikes + 1] = { timer = C.EPIC_FETUS_TARGET_TIMEOUT - C.EPIC_FETUS_FALL_FRAMES, pos = state.pos }
        end
    end
end

return Weapons
