local mod = RegisterMod("Zenith", 1)

local C = include("scripts.zenith.config")
local Sword = include("scripts.zenith.sword")
local Crosshair = include("scripts.zenith.crosshair")
local Render = include("scripts.zenith.render")
local DamageText = include("scripts.zenith.damagetext")
local TearEffects = include("scripts.zenith.tearflags")
local Weapons = include("scripts.zenith.weapons")
local Settings = include("scripts.zenith.settings")

-- 装了 REPENTOGON 时 content-repentogon/items.xml 生效，道具名是字符串表的键
local ZENITH = Isaac.GetItemIdByName(C.ITEM_NAME_KEY)
if ZENITH == -1 then
    ZENITH = Isaac.GetItemIdByName(C.ITEM_NAME)
end
local RENDERER = Isaac.GetEntityVariantByName(C.RENDERER_NAME)
local CROSSHAIR = Isaac.GetEntityVariantByName(C.CROSSHAIR_NAME)
local SWING_SOUND = Isaac.GetSoundIdByName(C.SWING_SOUND_NAME)
local HIT_SOUND = Isaac.GetSoundIdByName(C.HIT_SOUND_NAME)

-- 调试命令：zenith_debug（输出道具配置和道具栏内容，排查显示问题）
include("scripts.zenith.probe")(mod, function() return ZENITH end)

if ZENITH == -1 or RENDERER == -1 or CROSSHAIR == -1 or SWING_SOUND == -1 or HIT_SOUND == -1 then
    Isaac.DebugString("[Zenith] items.xml / entities2.xml / sounds.xml failed to load")
else
    Isaac.DebugString("[Zenith] loaded, item id = " .. ZENITH)
end
if not Render.HasTrail then
    Isaac.DebugString("[Zenith] REPENTOGON not found, trail strips disabled")
end

local function getState(player)
    local data = player:GetData()
    if not data.Zenith then
        data.Zenith = { active = false, swords = {}, particles = {}, cycle = 0, fireTimer = 0, renderFrame = 0 }
    end
    data.Zenith.particles = data.Zenith.particles or {} -- luamod 热重载前创建的旧状态
    return data.Zenith
end

local function ensureRenderer(player, state)
    local r = state.renderer
    if not (r and r:Exists()) then
        r = Isaac.Spawn(EntityType.ENTITY_EFFECT, RENDERER, 0, player.Position, Vector.Zero, player):ToEffect()
        state.renderer = r
    end
    r.Position = player.Position
    r.DepthOffset = 1000
end

-- 玩家设置（画面、声音、道具池）：读取存档，并在模组配置菜单（按 L）里注册“天顶剑”设置页
include("scripts.zenith.menu")(mod)

-- 游戏内自动测试：控制台命令 zenith_test，或由 tools/run_ingame_tests.ps1 自动启动
include("scripts.zenith.selftest")(mod, { item = ZENITH, crosshair = CROSSHAIR, renderer = RENDERER, getState = getState, swordConfig = Sword.Config })

-- 阶段 A：统一接管攻击方式。
-- 有 REPENTOGON 时用 SetCanShoot(false) 关闭所有原生攻击（眼泪、硫磺火、妈刀、史诗胎儿、骨棒等），
-- 这些道具的攻击方式被天顶剑覆盖，属性加成由游戏照常计算。每帧都确认一次，防止被其它逻辑改回。
-- 没有 REPENTOGON 时退回旧办法：让射击冷却始终不归零（只能屏蔽眼泪）。
local function takeOverShooting(player, data)
    if REPENTOGON and player.SetCanShoot then
        data.ZenithShootLock = true
        if player:CanShoot() then
            player:SetCanShoot(false)
        end
        return true
    end
    player.FireDelay = math.max(player.FireDelay, player.MaxFireDelay, 1)
    return false
end

-- 角色本身能否攻击（players.xml 的 canShoot，例如莉莉丝不能）；读不到时当作能
local function characterCanShoot(player)
    local ok, allowed = pcall(function() return player:GetEntityConfigPlayer():CanShoot() end)
    return not ok or allowed ~= false
end

-- 失去天顶剑时恢复射击。不用“接管前的状态”而是按角色和当前挑战的规定恢复：
-- 带着天顶剑退出再继续时，接管前的状态已经丢失，按规定恢复才不会把玩家永久锁住，也不会让莉莉丝变得能射击
local function releaseShooting(player, data)
    if not data.ZenithShootLock then
        return
    end
    data.ZenithShootLock = nil
    if REPENTOGON and player.SetCanShoot then
        local ok, allowed = pcall(function() return Game():GetChallengeParams():CanShoot() end)
        player:SetCanShoot((not ok or allowed) and characterCanShoot(player))
    end
end

-- 原版里角色暂时不能攻击的状态。天顶剑一直让游戏处于“禁止射击”，读不到游戏自己的判断，所以逐项检查：
-- 举着道具（拾取动画、鲍勃的烂头/蜡烛等投掷物）、巨型蘑菇变身、巨型激光发射中、摔角抓取/瞄准、传送等特殊动画。
-- 这些状态下暂停出剑、准星不响应按键；已经飞出的剑会把轨迹走完。
local function attackSuppressed(player)
    if player:IsHoldingItem() or not player:IsExtraAnimationFinished() then
        return true
    end
    if player:GetEffects():HasCollectibleEffect(CollectibleType.COLLECTIBLE_MEGA_MUSH) then
        return true
    end
    local ok, blast = pcall(function() return player:GetMegaBlastDuration() end)
    if ok and blast and blast > 0 then
        return true
    end
    local ok2, suplex = pcall(function() return player:GetSuplexState() end)
    if ok2 and suplex and suplex ~= 0 then
        return true
    end
    return false
end

-- 被塞壬魅惑的跟班暂时归塞壬：不替角色出剑，也不拦它的原生攻击，按原版行为（用户决定）
local function charmed(familiar)
    -- IsCharmed 是 REPENTOGON 接口（实测魅惑结束时立即变回 false，而 FLAG_CHARM 会多留几帧）；没有时退回看魅惑标记
    local ok, result = pcall(function() return familiar:IsCharmed() end)
    if ok then
        return result
    end
    return familiar:HasEntityFlags(EntityFlag.FLAG_CHARM)
end

local function numSwordsPerShot(player)
    local ok, params = pcall(player.GetMultiShotParams, player, WeaponType.WEAPON_TEARS)
    if ok and params then
        return math.max(1, params:GetNumTears())
    end
    return 1
end

-- 每把剑出手时“替它发射一颗虚拟眼泪”：继承泪弹特效（概率特效每把剑独立判定）、
-- 按泪弹尺寸决定剑的大小（已包含伤害和泪弹变大道具的影响，再按 SIZE_RESPONSE 柔化），并记下当前暴击率
local function stackMult(player)
    return 1 + C.STACK_DAMAGE_BONUS * math.max(0, player:GetCollectibleNum(ZENITH) - 1)
end

-- 妈刀 / 英灵剑联动：这把剑换成哪种原版模型。英灵剑占 1/5（多个不叠加），妈刀每把占 1/5、最多占到剩下的部分；
-- 英灵剑出手时满血（红心 ≥ 有效心之容器，原版发射剑气的判定）则换成剑气
local function rollSpecial(player, rng)
    local spirit = player:HasCollectible(CollectibleType.COLLECTIBLE_SPIRIT_SWORD) and C.SPIRIT_SWORD_CHANCE or 0
    local knife = math.min(player:GetCollectibleNum(CollectibleType.COLLECTIBLE_MOMS_KNIFE) * C.KNIFE_CHANCE_PER_ITEM, 1 - spirit)
    local r = rng:RandomFloat()
    if r < knife then
        return "knife"
    elseif r < knife + spirit then
        return player:GetHearts() >= player:GetEffectiveMaxHearts() and "beam" or "spirit"
    end
    return nil
end

-- firstOfInterval：这把剑是不是本次射击间隔里的第 1 把（博士胎儿每个射击间隔只放一颗炸弹）
local function rollShot(player, rng, firstOfInterval)
    local flags, scale, tearDamage = TearEffects.Roll(player)
    local size = 1
    if C.SIZE_FOLLOW_TEARS then
        size = math.max(C.SIZE_MIN, math.min(C.SIZE_MAX, 1 + (scale - 1) * C.SIZE_RESPONSE))
    end
    return {
        flags = flags, size = size, critChance = TearEffects.CritChance(player), damageMult = stackMult(player),
        mulligan = player:HasCollectible(CollectibleType.COLLECTIBLE_MULLIGAN),
        guppy = player:HasPlayerForm(PlayerForm.PLAYERFORM_GUPPY),
        special = rollSpecial(player, rng),
        -- 卢多维科：飞剑围着准星转圈（用户选的方案 B）；小行星：飞剑围着角色转圈（同时拿时卢多维科优先）
        orbit = player:HasCollectible(CollectibleType.COLLECTIBLE_LUDOVICO_TECHNIQUE) and "crosshair"
            or player:HasCollectible(CollectibleType.COLLECTIBLE_TINY_PLANET) and "player" or nil,
        link = Weapons.Roll(player, firstOfInterval, rng),
        tearScale = scale,
        -- 泰拉：这颗“虚拟眼泪”的伤害相对角色伤害的浮动
        terraMult = (TearEffects.Has(flags, "TEAR_ROCK") and tearDamage and player.Damage > 0) and tearDamage / player.Damage or 1,
        wide = player:HasCollectible(CollectibleType.COLLECTIBLE_PUPULA_DUPLEX),
        proptosis = player:HasCollectible(CollectibleType.COLLECTIBLE_PROPTOSIS),
        -- 死亡之眼：出手时的连击层数（第一次命中时叠层、没打中任何敌人时清零，见 OnPlayerUpdate）
        deadEyeMult = player:HasCollectible(CollectibleType.COLLECTIBLE_DEAD_EYE)
            and 1 + C.DEAD_EYE_STEP * ((player:GetData().Zenith or {}).deadEye or 0) or 1,
    }
end

-- 改变发射方向的道具（巫师帽、洛基之角、妈妈的眼、眼疮）：额外的剑飞向的落点。aim = 角色原点 → 准星
local function extraTargets(player, rng, origin, aim)
    local out = {}
    local luck = player.Luck
    local function chance(spec)
        return rng:RandomFloat() < math.max(0, math.min(1, spec.base + spec.perLuck * luck))
    end
    if player:HasCollectible(CollectibleType.COLLECTIBLE_THE_WIZ) then
        out[#out + 1] = { origin + aim:Rotated(C.WIZ_ANGLE), 0 }
        out[#out + 1] = { origin + aim:Rotated(-C.WIZ_ANGLE), 0 }
    end
    if player:HasCollectible(CollectibleType.COLLECTIBLE_LOKIS_HORNS) and chance(C.LOKI) then
        for _ = 1, C.LOKI.swords do
            out[#out + 1] = { origin + aim, 2 } -- 准星附近的随机位置（第 3 种出剑方式的随机偏移）
        end
    end
    if player:HasCollectible(CollectibleType.COLLECTIBLE_MOMS_EYE) and chance(C.MOMS_EYE) then
        out[#out + 1] = { origin - aim, 0 }
    end
    if player:HasCollectible(CollectibleType.COLLECTIBLE_EYE_SORE) and rng:RandomFloat() < C.EYE_SORE.chance then
        local r, n = rng:RandomFloat(), 1
        local acc = 0
        for i, w in ipairs(C.EYE_SORE.weights) do
            acc = acc + w
            if r < acc then
                n = i
                break
            end
        end
        for _ = 1, n do
            out[#out + 1] = { origin + aim:Rotated(rng:RandomFloat() * 360), 0 }
        end
    end
    return out
end

local function shoot(player, state, enemies)
    local rng = player:GetCollectibleRNG(ZENITH)
    local origin = player.Position + C.ORIGIN_OFFSET
    local index = state.cycle % 3
    local firstOfInterval = state.cycle % C.FIRE_RATE_MULT == 0
    state.cycle = state.cycle + 1

    local before = #state.swords
    -- 原版不能自己攻击的角色（莉莉丝）本人不出剑，只由模仿型跟班出剑
    if not C.NO_OWN_SWORDS[player:GetPlayerType()] then
        state.swords[#state.swords + 1] = Sword.Create(origin, state.pos, index, enemies, rng, rollShot(player, rng, firstOfInterval))
        -- 多发道具（20/20、内眼等）额外的剑都按“锁敌 + 随机偏移”处理
        local count = numSwordsPerShot(player)
        -- 巫师帽：游戏把它算成“每次 2 颗”（多发），飞剑版本改成 1 把主剑 + 左右两把斜向的剑（extraTargets），所以扣掉它加的那 1 把
        if player:HasCollectible(CollectibleType.COLLECTIBLE_THE_WIZ) then
            count = math.max(1, count - 1)
        end
        -- 铅笔：每第 15 次出剑改为一次扔出 13 把剑（原版每第 15 颗眼泪变成 13 颗的齐射，实测）
        if player:HasCollectible(CollectibleType.COLLECTIBLE_LEAD_PENCIL) then
            state.pencil = (state.pencil or 0) + 1
            if state.pencil >= C.PENCIL_PERIOD then
                state.pencil = 0
                count = math.max(count, C.PENCIL_BURST)
            end
        end
        for _ = 2, count do
            state.swords[#state.swords + 1] = Sword.Create(origin, state.pos, 2, enemies, rng, rollShot(player, rng, false))
        end
        -- 巫师帽、洛基之角、妈妈的眼、眼疮：额外的剑
        local aim = state.pos - origin
        if aim:LengthSquared() < 1 then
            aim = Vector(C.REACH_MIN, 0)
        end
        for _, t in ipairs(extraTargets(player, rng, origin, aim)) do
            state.swords[#state.swords + 1] = Sword.Create(origin, t[1], t[2], enemies, rng, rollShot(player, rng, false))
        end
    end

    -- 阶段 C / D：模仿型跟班（Incubus、扭曲双子、吉罗、血块）同时从自己的位置出剑，伤害和特效按原版
    local lilith = player:GetPlayerType() == PlayerType.PLAYER_LILITH or player:GetPlayerType() == PlayerType.PLAYER_LILITH_B
    local bffs = player:HasCollectible(CollectibleType.COLLECTIBLE_BFFS) and C.FAMILIAR_BFFS_MULT or 1
    for variant, rule in pairs(C.FAMILIAR_SWORDS) do
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, variant)) do
            local fam = e:ToFamiliar()
            -- 血块等按子类型区分倍率和特效
            local r = rule.subtypes and fam and rule.subtypes[fam.SubType] or rule
            if fam and r.mult and fam.Player and GetPtrHash(fam.Player) == GetPtrHash(player) and not charmed(fam) then
                local famOrigin = fam.Position + C.ORIGIN_OFFSET
                for k = 1, numSwordsPerShot(player) do
                    local shot = rollShot(player, rng, k == 1 and firstOfInterval)
                    local famMult = (lilith and r.lilithMult or r.mult) * bffs
                    shot.anchor = fam
                    shot.size = shot.size * C.FAMILIAR_SWORD_SIZE
                    shot.damageMult = shot.damageMult * famMult
                    shot.knifeMult, shot.linkMult = famMult, famMult -- 妈刀 / 英灵剑和联动效果也按跟班倍率
                    shot.flags = TearEffects.AddFlags(shot.flags, r.flags)
                    if r.chance and rng:RandomFloat() < TearEffects.LuckChance(r.chance, player.Luck) then
                        shot.flags = TearEffects.AddFlags(shot.flags, { r.chance.flag })
                    end
                    state.swords[#state.swords + 1] = Sword.Create(famOrigin, state.pos, k == 1 and index or 2, enemies, rng, shot)
                end
            end
        end
    end

    if SWING_SOUND ~= -1 and #state.swords > before then
        local pitch = 1 + (rng:RandomFloat() * 2 - 1) * C.SWING_SOUND_PITCH_RANDOM
        SFXManager():Play(SWING_SOUND, Settings.Get("swingVolume") / 100, 0, false, pitch)
    end
end

-- 击中敌人：泰拉受击音效（限频）+ 伤害数字
local lastHitSoundFrame = -100
local function onHit(rng)
    return function(enemy, damage, crit)
        local frame = Game():GetFrameCount()
        -- rewind（发光沙漏等）会把游戏帧数倒回去，计时要跟着重置，否则间隔判断一直不成立、音效全部被跳过
        if frame < lastHitSoundFrame then
            lastHitSoundFrame = -100
        end
        if HIT_SOUND ~= -1 and frame - lastHitSoundFrame >= C.HIT_SOUND_INTERVAL then
            lastHitSoundFrame = frame
            SFXManager():Play(HIT_SOUND, Settings.Get("hitVolume") / 100, 0, false, 0.95 + rng:RandomFloat() * 0.1)
        end
        DamageText.Add(enemy, damage, crit, rng)
    end
end

-- 攻击方式被天顶剑完全覆盖的道具：拿着天顶剑时屏蔽（BlockCollectible，游戏当作没有这件道具，效果和属性都不生效），
-- 失去天顶剑时解除（用户定的统一规则）。屏蔽状态变化后重新计算属性
local FULL_OVERRIDE = {}
for _, name in ipairs(C.FULL_OVERRIDE) do
    local id = CollectibleType["COLLECTIBLE_" .. name]
    if id then
        FULL_OVERRIDE[#FULL_OVERRIDE + 1] = id
    end
end
local FULL_OVERRIDE_TRINKETS = {}
for _, name in ipairs(C.FULL_OVERRIDE_TRINKETS) do
    local id = TrinketType["TRINKET_" .. name]
    if id then
        FULL_OVERRIDE_TRINKETS[#FULL_OVERRIDE_TRINKETS + 1] = id
    end
end
local function setOverrideBlocks(player, data, block)
    -- 保险：没拿天顶剑、本次游戏还没检查过时，把仍被屏蔽的道具解除（屏蔽状态如果随存档保存，继续游戏时不会卡住）
    if not block and not data.ZenithBlockChecked then
        data.ZenithBlockChecked = true
        data.ZenithBlocked = true
    end
    if not player.BlockCollectible or (data.ZenithBlocked or false) == block then
        return
    end
    data.ZenithBlocked = block or nil
    for _, id in ipairs(FULL_OVERRIDE) do
        pcall(function()
            if block then
                player:BlockCollectible(id)
            else
                player:UnblockCollectible(id)
            end
        end)
    end
    for _, id in ipairs(FULL_OVERRIDE_TRINKETS) do
        pcall(function()
            if block then
                player:BlockTrinket(id)
            else
                player:UnblockTrinket(id)
            end
        end)
    end
    player:AddCacheFlags(CacheFlag.CACHE_ALL)
    player:EvaluateItems()
end

function mod:OnPlayerUpdate(player)
    local data = player:GetData()
    if not player:HasCollectible(ZENITH) then
        if data.Zenith then
            Crosshair.Remove(data.Zenith)
        end
        data.Zenith = nil
        releaseShooting(player, data)
        setOverrideBlocks(player, data, false)
        return
    end
    setOverrideBlocks(player, data, true)

    local state = getState(player)
    ensureRenderer(player, state)

    state.shootingLocked = takeOverShooting(player, data)
    state.suppressed = attackSuppressed(player)

    Crosshair.Update(player, state, CROSSHAIR)
    Crosshair.HideVanilla(player)

    local enemies, props, bombs, pickups = Sword.GetTargets()
    if state.active and state.pos and not state.suppressed then
        state.fireTimer = state.fireTimer - 1
        local interval = (player.MaxFireDelay + 1) / C.FIRE_RATE_MULT / (C.CHARACTER_FIRE_RATE_MULT[player:GetPlayerType()] or 1)
        local shots = 0
        while state.fireTimer <= 0 and shots < 6 do
            shoot(player, state, enemies)
            state.fireTimer = state.fireTimer + interval
            shots = shots + 1
        end
    else
        state.fireTimer = math.max(state.fireTimer - 1, 0)
    end

    -- 史诗胎儿：准星显示且能攻击时按原版间隔在准星处落导弹；科技 2：维持连到准星的激光
    Weapons.UpdateEpicFetus(player, state, state.active and not state.suppressed)
    Weapons.UpdateTech2(player, state, state.active and not state.suppressed)

    local origin = player.Position + C.ORIGIN_OFFSET
    local rng = player:GetCollectibleRNG(ZENITH)
    Sword.UpdateParticles(state.particles)
    local hitHandler = onHit(rng)
    for i = #state.swords, 1, -1 do
        local s = state.swords[i]
        local alive = Sword.Update(player, s, Sword.Origin(s, origin, nil, state.pos), enemies, props, bombs, state.particles, rng, hitHandler, pickups)
        -- 死亡之眼：每把剑第一次命中敌人时叠一层（最多 4 层），一把剑飞完都没打中敌人就清零
        if s.deadEyeMult ~= 1 or player:HasCollectible(CollectibleType.COLLECTIBLE_DEAD_EYE) then
            if s.firstHitDone and not s.deadEyeCounted then
                s.deadEyeCounted = true
                state.deadEye = math.min(C.DEAD_EYE_MAX, (state.deadEye or 0) + 1)
            elseif not alive and not s.firstHitDone and not s.anchor then
                state.deadEye = 0
            end
        end
        if not alive then
            table.remove(state.swords, i)
        end
    end
    state.renderFrame = Isaac.GetFrameCount()
end
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, mod.OnPlayerUpdate)

function mod:OnRendererRender(effect)
    local player = effect.SpawnerEntity and effect.SpawnerEntity:ToPlayer()
    if not player then
        effect:Remove()
        return
    end
    local state = player:GetData().Zenith
    if not state then
        effect:Remove()
        return
    end
    Render.Draw(effect, state, player)
end
mod:AddCallback(ModCallbacks.MC_POST_EFFECT_RENDER, mod.OnRendererRender, RENDERER)

function mod:OnCrosshairUpdate(effect)
    Crosshair.OnEffectUpdate(effect)
end
mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, mod.OnCrosshairUpdate, CROSSHAIR)

-- 原版准星（标记 30 / 玄秘魔眼 153）刚生成时也立即隐藏，避免闪现一帧
function mod:OnVanillaTargetUpdate(effect)
    local player = effect.SpawnerEntity and effect.SpawnerEntity:ToPlayer()
    if player and player:HasCollectible(ZENITH) then
        local target = player:GetMarkedTarget()
        if target and GetPtrHash(target) == GetPtrHash(effect) then
            effect.Visible = false
        end
    end
end
mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, mod.OnVanillaTargetUpdate, EffectVariant.TARGET)
mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, mod.OnVanillaTargetUpdate, EffectVariant.OCCULT_TARGET)

-- 保险：持有天顶剑时如果仍有眼泪被发射（某些道具会绕过射击冷却），直接移除眼泪和发射音效
local reportedTear = false
function mod:OnFireTear(tear)
    local player = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
    if player and player:HasCollectible(ZENITH) then
        tear:Remove()
        SFXManager():Stop(SoundEffect.SOUND_TEARS_FIRE)
        if not reportedTear then
            reportedTear = true
            Isaac.DebugString("[Zenith] blocked a tear fired by the player")
        end
    end
end
mod:AddCallback(ModCallbacks.MC_POST_FIRE_TEAR, mod.OnFireTear)

-- 模仿型跟班（Incubus、扭曲双子）用自己的武器照搬角色的攻击，按射击键就开火，不受 SetCanShoot 影响
-- （原版莉莉丝不能射击却能靠 Incubus 攻击，就是这个原理）。角色拿着天顶剑时它们改为扔飞剑，
-- 所以在它们更新前把武器的射击冷却顶住、蓄力清零，原生攻击就不会触发（游戏内测试实测）
local MIMIC_FIRE_DELAY_HOLD = 10
function mod:OnMimicFamiliarUpdate(familiar)
    local player = familiar.Player
    if not (player and player:HasCollectible(ZENITH)) or charmed(familiar) then
        return
    end
    local ok, weapon = pcall(familiar.GetWeapon, familiar)
    if ok and weapon then
        weapon:SetFireDelay(math.max(weapon:GetFireDelay(), MIMIC_FIRE_DELAY_HOLD))
        weapon:SetCharge(0)
    end
end
if ModCallbacks.MC_PRE_FAMILIAR_UPDATE then
    for variant in pairs(C.FAMILIAR_SWORDS) do
        mod:AddCallback(ModCallbacks.MC_PRE_FAMILIAR_UPDATE, mod.OnMimicFamiliarUpdate, variant)
    end
end

-- 保险：冷却顶住后仍漏出来的原生攻击（例如吉罗被弹出的那一下）直接删除
function mod:OnMimicFamiliarFire(shot)
    local spawner = shot.SpawnerEntity
    local fam = spawner and spawner:ToFamiliar()
    if fam and charmed(fam) then
        return
    end
    local player = spawner and (spawner:ToPlayer() or (fam and fam.Player))
    if player and player:HasCollectible(ZENITH) then
        shot:Remove()
        SFXManager():Stop(SoundEffect.SOUND_TEARS_FIRE)
    end
end
for _, callback in ipairs({ "MC_POST_FAMILIAR_FIRE_PROJECTILE", "MC_POST_FAMILIAR_FIRE_BRIMSTONE", "MC_POST_FAMILIAR_FIRE_TECH_LASER" }) do
    if ModCallbacks[callback] then
        for variant in pairs(C.FAMILIAR_SWORDS) do
            mod:AddCallback(ModCallbacks[callback], mod.OnMimicFamiliarFire, variant)
        end
    end
end

-- 保险 2：血块等跟班的眼泪生成者记为角色本人，也不经过上面的“跟班发射”回调（游戏内实测）。
-- 角色拿着天顶剑时，出生位置紧挨着该角色的模仿型跟班、且离跟班不比离角色本人远的眼泪 / 激光视为跟班的原生攻击，删除。
-- 出生回调里来源可能还没设好，所以第一帧更新时再查一次（实测漏网的眼泪离跟班和角色都是 20）。
-- 天顶剑自己生成的骨片、联动激光和炸弹（weapons.lua）生成期间角色数据上带 ZenithSpawningOwn 标记，不受影响
function mod:OnMimicLeak(shot)
    local player = shot.SpawnerEntity and shot.SpawnerEntity:ToPlayer()
    if not (player and player:HasCollectible(ZENITH)) or player:GetData().ZenithSpawningOwn then
        return
    end
    local selfDist = shot.Position:Distance(player.Position)
    for variant in pairs(C.FAMILIAR_SWORDS) do
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, variant)) do
            local fam = e:ToFamiliar()
            if fam and fam.Player and GetPtrHash(fam.Player) == GetPtrHash(player) and not charmed(fam) then
                local dist = shot.Position:Distance(fam.Position)
                if dist <= selfDist and dist <= C.MIMIC_LEAK_RADIUS then
                    shot:Remove()
                    SFXManager():Stop(SoundEffect.SOUND_TEARS_FIRE)
                    return
                end
            end
        end
    end
end
mod:AddCallback(ModCallbacks.MC_POST_TEAR_INIT, mod.OnMimicLeak)
mod:AddCallback(ModCallbacks.MC_POST_LASER_INIT, mod.OnMimicLeak)
local function onFirstUpdate(_, shot)
    local data = shot:GetData()
    if shot.FrameCount <= 1 and not data.ZenithShard and not data.ZenithOwned then
        mod:OnMimicLeak(shot)
    end
end
mod:AddCallback(ModCallbacks.MC_POST_TEAR_UPDATE, onFirstUpdate)
mod:AddCallback(ModCallbacks.MC_POST_LASER_UPDATE, onFirstUpdate)

-- 妈刀 / 英灵剑联动：拿着天顶剑时原版妈刀、英灵剑实体仍会停在角色身边（射击被关闭，不会挥动），隐藏它们并去掉碰撞，
-- 改由飞剑按概率换成刀 / 剑模型扔出（sword.lua）。跟班（Incubus 等）的同样处理
local HIDDEN_KNIVES = { [0] = true, [10] = true } -- 0 = 妈刀，10 = 英灵剑（实测 8.10）
local function knifeOwner(knife)
    local owner = knife.SpawnerEntity or knife.Parent
    return owner and (owner:ToPlayer() or (owner:ToFamiliar() and owner:ToFamiliar().Player))
end
mod:AddCallback(ModCallbacks.MC_POST_KNIFE_UPDATE, function(_, knife)
    local player = knifeOwner(knife)
    if HIDDEN_KNIVES[knife.Variant] and player and player:HasCollectible(ZENITH) then
        knife.Visible = false
        knife.EntityCollisionClass = EntityCollisionClass.ENTCOLL_NONE
    end
end)
mod:AddCallback(ModCallbacks.MC_PRE_KNIFE_COLLISION, function(_, knife)
    local player = knifeOwner(knife)
    if HIDDEN_KNIVES[knife.Variant] and player and player:HasCollectible(ZENITH) then
        return true
    end
end)

-- 牵引光束：拿着天顶剑时眼泪被覆盖，原版的引导光束（激光变体 7，不造成伤害）没有用处，隐藏它（道具扫描发现）
local TRACTOR_BEAM_LASER = 7
mod:AddCallback(ModCallbacks.MC_POST_LASER_UPDATE, function(_, laser)
    if laser.Variant ~= TRACTOR_BEAM_LASER then
        return
    end
    local player = laser.SpawnerEntity and laser.SpawnerEntity:ToPlayer()
    if player and player:HasCollectible(ZENITH) then
        laser.Visible = false
    end
end)

-- 道具池（用户设置，默认天使房、恶魔房、宝箱房、商店）：itempools.xml 把天顶剑放进了所有可选的池，
-- 从没开启的池抽到天顶剑时换成这个池里的另一个道具
local POOL_SETTING = {}
for _, entry in ipairs(Settings.POOLS) do
    for _, name in ipairs(entry.pools) do
        if ItemPoolType[name] then
            POOL_SETTING[ItemPoolType[name]] = entry.key
        end
    end
end
local rerolling = false
mod:AddCallback(ModCallbacks.MC_POST_GET_COLLECTIBLE, function(_, selected, poolType, decrease, seed)
    if selected ~= ZENITH or rerolling then
        return nil
    end
    local key = POOL_SETTING[poolType]
    if key == nil or Settings.PoolEnabled(key) then
        return nil
    end
    rerolling = true
    local pool, next = Game():GetItemPool(), seed
    local pick = selected
    for _ = 1, 10 do
        next = math.max(1, (next * 1103515245 + 12345) % 2147483648)
        pick = pool:GetCollectible(poolType, decrease, next)
        if pick ~= ZENITH then
            break
        end
    end
    rerolling = false
    if pick == ZENITH then
        return CollectibleType.COLLECTIBLE_BREAKFAST -- 极端情况下（池里只剩天顶剑）给原版的保底道具早餐
    end
    return pick
end)

-- 伤害数字：所有角色共用一份，逻辑帧更新、渲染帧绘制（暂停时不画）
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, DamageText.Update)

-- 推炸弹：在炸弹自己更新之后结算（和原版眼泪撞炸弹的时机一致）
mod:AddCallback(ModCallbacks.MC_POST_BOMB_UPDATE, function(_, bomb)
    Sword.ApplyBombPush(bomb)
end)
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    Sword.PruneBombPushes(false)
end)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
    if Game():IsPaused() then
        return
    end
    DamageText.Render()
    -- 每个渲染帧检查丢弃键，避免逻辑帧漏检（见 Crosshair.PollDrop）
    for i = 0, Game():GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        local state = player:GetData().Zenith
        if state then
            Crosshair.PollDrop(player, state)
        end
    end
end)

-- 清空场上的飞剑和准星（换房间、里拉撒路翻转时）
local function resetState(state)
    state.active = false
    state.swords = {}
    state.particles = {}
    state.strikes = {}
    state.tech2Laser = nil
    state.crosshair = nil
    state.dropPressed = false
    state.waitRelease = false
    state.renderer = nil
end

-- 和标记一样：换房间后准星隐藏，飞剑清空
function mod:OnNewRoom()
    DamageText.Clear()
    Sword.PruneBombPushes(true)
    for i = 0, Game():GetNumPlayers() - 1 do
        local state = Isaac.GetPlayer(i):GetData().Zenith
        if state then
            resetState(state)
        end
    end
end
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, mod.OnNewRoom)

-- 里拉撒路翻转后，不活动的形态不再更新，它没飞完的剑会冻结，翻转回来时接着飞（游戏内测试实测），所以翻转后清空。
-- 两个形态的道具各自独立（原版），另一形态没拿天顶剑时没有状态，不受影响
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    for i = 0, Game():GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(i)
        local t = player:GetPlayerType()
        if t == PlayerType.PLAYER_LAZARUS_B or t == PlayerType.PLAYER_LAZARUS2_B then
            local ok, other = pcall(player.GetFlippedForm, player)
            local state = ok and other and other:GetData().Zenith
            if state and (#state.swords > 0 or state.crosshair) then
                Crosshair.Remove(state)
                resetState(state)
            end
        end
    end
end)

if EID then
    EID:addCollectible(ZENITH,
        "Replaces tears with flying Terraria swords"
            .. "#Fire keys move a crosshair, swords auto-fire toward it; Drop key hides it"
            .. "#Crosshair distance sets the attack range, capped by {{Range}} Range; crosshair speed grows with {{Shotspeed}} Shot speed"
            .. "#Swords pierce enemies and walls, and break fires, poop and TNT"
            .. "#Swords inherit tear effects (poison, burn, slow, charm, homing, etc.)"
            .. "#15% crit chance (x2 damage), +5% per {{Luck}} Luck (100% at 17 Luck), counts as a luck-based tear effect"
            .. "#{{Collectible394}} Marked, {{Collectible572}} Eye of the Occult, charged attacks, splitting tears and some tear-path items are fully overridden: their effects and stats do not apply (marked in their descriptions)",
        "Zenith", "en_us")
    EID:addCollectible(ZENITH,
        "攻击方式变为发射泰拉瑞亚飞剑"
            .. "#射击键移动准星，飞剑自动连续飞向准星；按丢弃键收起准星"
            .. "#准星距离决定攻击距离，上限由{{Range}}射程决定；准星移动速度随{{Shotspeed}}弹速提升"
            .. "#飞剑可穿透敌人和障碍物，能打坏火堆、大便和TNT"
            .. "#飞剑继承泪弹特效（中毒、燃烧、减速、魅惑、追踪等）"
            .. "#暴击率15%（伤害x2），每点{{Luck}}幸运+5%，17幸运时为100%；属于幸运类泪弹效果"
            .. "#{{Collectible394}}标记、{{Collectible572}}玄秘魔眼、蓄力类、分裂泪弹类和部分改变泪弹轨迹的道具被完全覆盖，效果和属性均不生效（这些道具的说明里会标出）",
        "天顶剑", "zh_cn")

    -- 联动道具的说明里追加天顶剑联动效果（仅当有角色持有天顶剑时，用户选的方案 B）。
    -- 妈刀、英灵剑只写效果，不写概率和叠加规则（用户要求）
    local I = CollectibleType
    local SYNERGY = {
        [I.COLLECTIBLE_BRIMSTONE] = { "飞剑带血光，命中时给敌人上硫磺标记，被标记的敌人受到飞剑伤害x5；被标记的敌人被飞剑击杀时把标记传染给周围敌人",
            "Swords glow red and apply the Brimstone mark; marked enemies take x5 sword damage and spread the mark when killed by a sword" },
        [I.COLLECTIBLE_TECHNOLOGY] = { "每把飞剑第一次命中敌人时，从眼睛射出一道激光打向它",
            "Each sword's first hit fires a laser from Isaac's eyes at that enemy" },
        [I.COLLECTIBLE_TECHNOLOGY_2] = { "从眼睛连一道持续的激光到准星", "A continuous laser runs from Isaac's eyes to the crosshair" },
        [I.COLLECTIBLE_TECH_X] = { "每把飞剑带着一个激光环", "Each sword carries a small laser ring" },
        [I.COLLECTIBLE_DR_FETUS] = { "每次射击在准星处放下一颗炸弹", "Each shot drops a bomb at the crosshair" },
        [I.COLLECTIBLE_EPIC_FETUS] = { "按原版间隔在准星处召唤导弹", "Missiles strike the crosshair at the usual interval" },
        [I.COLLECTIBLE_LUDOVICO_TECHNIQUE] = { "飞剑改为围着准星转圈", "Swords orbit around the crosshair instead" },
        [I.COLLECTIBLE_MOMS_KNIFE] = { "部分飞剑变成妈刀，单次造成高伤害", "Some swords become Mom's Knife, dealing one heavy hit" },
        [I.COLLECTIBLE_SPIRIT_SWORD] = { "部分飞剑变成英灵剑（满血时为剑气），单次造成高伤害，并能拾取掉落物、打开箱子",
            "Some swords become the Spirit Sword (a sword beam at full health), dealing one heavy hit and collecting pickups / opening chests" },
        [I.COLLECTIBLE_MULLIGAN] = { "每把飞剑第一次命中敌人时有概率生成蓝苍蝇", "Each sword's first hit may spawn a blue fly" },
        [I.COLLECTIBLE_IPECAC] = { "每把飞剑第一次命中敌人时爆炸", "Each sword explodes on its first hit" },
        [I.COLLECTIBLE_COMPOUND_FRACTURE] = { "每把飞剑第一次命中敌人时碎出骨片", "Each sword shatters into bone shards on its first hit" },
        [I.COLLECTIBLE_THE_WIZ] = { "每次出剑额外两把剑，飞向准星左右两侧", "Each attack throws two extra swords to the sides of the crosshair" },
        [I.COLLECTIBLE_LOKIS_HORNS] = { "概率额外扔出 3 把剑飞向准星附近", "Chance to throw 3 extra swords around the crosshair" },
        [I.COLLECTIBLE_MOMS_EYE] = { "概率额外一把剑飞向身后", "Chance to throw an extra sword behind Isaac" },
        [I.COLLECTIBLE_EYE_SORE] = { "概率额外扔出 1～3 把剑飞向随机方向", "Chance to throw 1-3 extra swords in random directions" },
        [I.COLLECTIBLE_TINY_PLANET] = { "飞剑改为围着角色转圈", "Swords orbit around Isaac instead" },
        [I.COLLECTIBLE_PUPULA_DUPLEX] = { "飞剑的判定变宽", "Swords hit a wider area" },
        [I.COLLECTIBLE_PROPTOSIS] = { "敌人离角色越近，飞剑伤害越高（远处很低）", "Swords deal more damage to close enemies and little to far ones" },
        [I.COLLECTIBLE_STRANGE_ATTRACTOR] = { "飞剑命中时把周围敌人往被命中的敌人拉", "Sword hits pull nearby enemies toward the target" },
        [I.COLLECTIBLE_EYE_OF_BELIAL] = { "每把飞剑命中第二个及之后的敌人时伤害x2", "Each sword deals x2 damage to the second and later enemies it hits" },
        [I.COLLECTIBLE_DEAD_EYE] = { "飞剑连续命中叠加伤害，一把剑没打中敌人时清零", "Consecutive sword hits stack damage; a sword that misses resets it" },
        [I.COLLECTIBLE_GHOST_PEPPER] = { "飞剑有概率在准星处留下蓝色火焰", "Swords may leave a blue flame at the crosshair" },
        [I.COLLECTIBLE_BIRDS_EYE] = { "飞剑有概率在准星处留下红色火焰", "Swords may leave a red flame at the crosshair" },
        [I.COLLECTIBLE_GODHEAD] = { "每把飞剑带一个伤害光环", "Each sword carries a damaging aura" },
    }
    -- 命中特效靠“替身眼泪”触发原版效果的道具：统一提示
    for _, name in ipairs({ "LITTLE_HORN", "EUTHANASIA", "HOLY_LIGHT", "JACOBS_LADDER", "SINUS_INFECTION", "EXPLOSIVO",
        "MYSTERIOUS_LIQUID", "PARASITOID", "E_COLI", "TERRA", "HEAD_OF_THE_KEEPER" }) do
        local id = CollectibleType["COLLECTIBLE_" .. name]
        if id and not SYNERGY[id] then
            SYNERGY[id] = { "每把飞剑第一次命中敌人时触发原版效果", "Each sword triggers the original effect on its first hit" }
        end
    end
    SYNERGY[I.COLLECTIBLE_TERRA] = { "每把飞剑第一次命中敌人时触发原版效果，并能打碎石头", "Each sword triggers the original effect on its first hit and breaks rocks" }
    EID:addDescriptionModifier("Zenith Synergies", function(descObj)
        return descObj.ObjType == EntityType.ENTITY_PICKUP and descObj.ObjVariant == PickupVariant.PICKUP_COLLECTIBLE
            and SYNERGY[descObj.ObjSubType] and EID:PlayersHaveCollectible(ZENITH)
    end, function(descObj)
        local text = SYNERGY[descObj.ObjSubType]
        local zh = EID:getLanguage() == "zh_cn"
        EID:appendToDescription(descObj, "#{{Collectible" .. ZENITH .. "}} " .. (zh and ("天顶剑：" .. text[1]) or ("Zenith: " .. text[2])))
        return descObj
    end)

    -- 被天顶剑完全覆盖的道具（config.lua FULL_OVERRIDE：准星类、蓄力类、分裂泪弹类）说明里追加提示（仅当有角色持有天顶剑时）
    local OVERRIDDEN, OVERRIDDEN_TRINKETS = {}, {}
    for _, id in ipairs(FULL_OVERRIDE) do
        OVERRIDDEN[id] = true
    end
    for _, id in ipairs(FULL_OVERRIDE_TRINKETS) do
        OVERRIDDEN_TRINKETS[id] = true
    end
    EID:addDescriptionModifier("Zenith Overrides Crosshair Items", function(descObj)
        if descObj.ObjType ~= EntityType.ENTITY_PICKUP or not EID:PlayersHaveCollectible(ZENITH) then
            return false
        end
        if descObj.ObjVariant == PickupVariant.PICKUP_TRINKET then
            return OVERRIDDEN_TRINKETS[descObj.ObjSubType % 32768] -- 金饰品的子类型带 32768 标记
        end
        return descObj.ObjVariant == PickupVariant.PICKUP_COLLECTIBLE and OVERRIDDEN[descObj.ObjSubType]
    end, function(descObj)
        local text = EID:getLanguage() == "zh_cn"
            and "#{{Collectible" .. ZENITH .. "}} 攻击方式被天顶剑覆盖，效果和属性均不生效"
            or "#{{Collectible" .. ZENITH .. "}} Overridden by Zenith: its effects and stats do not apply"
        EID:appendToDescription(descObj, text)
        return descObj
    end)
end
