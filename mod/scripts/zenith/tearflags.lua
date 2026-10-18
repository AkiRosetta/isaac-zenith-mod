-- 飞剑继承泪弹特效。
-- 每把剑出手时调用一次 GetTearHitParams，等于“替这把剑发射了一颗眼泪”：
-- 固定特效（如中毒、燃烧）和按幸运判定的概率特效都由游戏自己算好，结果存进这把剑；
-- 命中敌人时把对应的状态加到敌人身上。只支持下表中的特效，其余泪弹标记会被忽略。

local C = include("scripts.zenith.config")

local TearEffects = {}

local function has(flags, flag)
    local ok, result = pcall(function()
        return (flags & flag) == flag
    end)
    return ok and result
end

local SLOW_COLOR = Color(1, 1, 1, 1, 0.15, 0.15, 0.15)

-- { 泪弹标记名, 施加函数(敌人, 来源, 角色, 持续帧数) }
-- 原版状态函数直接可用；AddBaited / AddMagnetized / AddIce / AddBleeding / AddKnockback 需要 REPENTOGON，缺失时 pcall 会跳过
local EFFECTS = {
    { "TEAR_POISON", function(e, src, p, d) e:AddPoison(src, d, p.Damage) end },
    { "TEAR_BURN", function(e, src, p, d) e:AddBurn(src, d, p.Damage) end },
    { "TEAR_SLOW", function(e, src, _, d) e:AddSlowing(src, d, 0.5, SLOW_COLOR) end },
    { "TEAR_FREEZE", function(e, src, _, d) e:AddFreeze(src, d) end },
    { "TEAR_CHARM", function(e, src, _, d) e:AddCharmed(src, d) end },
    { "TEAR_CONFUSION", function(e, src, _, d) e:AddConfusion(src, d, false) end },
    { "TEAR_PERMANENT_CONFUSION", function(e, src, _, d) e:AddConfusion(src, d * 3, false) end },
    { "TEAR_FEAR", function(e, src, _, d) e:AddFear(src, d) end },
    { "TEAR_MIDAS", function(e, src, _, d) e:AddMidasFreeze(src, d) end },
    { "TEAR_SHRINK", function(e, src, _, d) e:AddShrink(src, d) end },
    { "TEAR_GODS_FLESH", function(e, src, _, d) e:AddShrink(src, d) end },
    { "TEAR_BAIT", function(e, src, _, d) e:AddBaited(src, d) end },
    { "TEAR_MAGNETIZE", function(e, src, _, d) e:AddMagnetized(src, d) end },
    { "TEAR_ICE", function(e, src, _, d) e:AddIce(src, d) end },
    { "TEAR_BACKSTAB", function(e, src, _, d) e:AddBleeding(src, d * 2) end },
    { "TEAR_PUNCH", function(e, src, p, d)
        local dir = e.Position - p.Position
        if dir:LengthSquared() > 0 then
            e:AddKnockback(src, dir:Resized(10), math.floor(d / 4), true)
        end
    end },
}

-- 取一颗“虚拟眼泪”的参数：泪弹标记、尺寸、伤害（泰拉等会让每颗眼泪伤害不同）
function TearEffects.Roll(player)
    local ok, params = pcall(player.GetTearHitParams, player, WeaponType.WEAPON_TEARS)
    if ok and params then
        return params.TearFlags, params.TearScale, params.TearDamage
    end
    return nil, 1, nil
end

function TearEffects.Has(flags, name)
    return flags ~= nil and TearFlags[name] ~= nil and has(flags, TearFlags[name])
end

-- 给一组泪弹标记加上 names 里的标记（按名字），返回新的标记；不认识的名字忽略
function TearEffects.AddFlags(flags, names)
    for _, name in ipairs(names or {}) do
        local flag = TearFlags[name]
        if flag ~= nil then
            if flags == nil then
                flags = flag
            else
                local ok, merged = pcall(function() return flags | flag end)
                if ok then
                    flags = merged
                end
            end
        end
    end
    return flags
end

-- 按幸运计算的触发概率，限制在 0～1。两种写法：
--   线性：base + perLuck × 幸运
--   倒数（以撒常见的“1/N 概率”）：1 / max(denomMin, denom + denomPerLuck × 幸运)
function TearEffects.LuckChance(spec, luck)
    local chance
    if spec.denom then
        chance = 1 / math.max(spec.denomMin or 1, spec.denom + (spec.denomPerLuck or 0) * luck)
    else
        chance = spec.base + (spec.perLuck or 0) * luck
    end
    return math.max(0, math.min(1, chance))
end

-- 复合骨折：在敌人身边朝随机方向碎出 1～3 块骨片（真实的眼泪实体，伤害 = 剑的单次伤害 × 0.5，不会再次碎裂）。
-- 骨片生成在敌人碰撞圈外（否则当帧就撞回同一个敌人消失）；生成期间在角色数据上做标记，
-- 让“删除跟班漏出的原生眼泪”的保险和测试计数能认出它们
function TearEffects.BoneShards(enemy, player, swordDamage, rng)
    local count = C.BONE_SHARDS_MIN + rng:RandomInt(C.BONE_SHARDS_MAX - C.BONE_SHARDS_MIN + 1)
    local data = player:GetData()
    data.ZenithSpawningOwn = true
    for _ = 1, count do
        local dir = Vector.FromAngle(rng:RandomFloat() * 360)
        pcall(function()
            local tear = Isaac.Spawn(EntityType.ENTITY_TEAR, TearVariant.BONE, 0, enemy.Position + dir * (enemy.Size + C.BONE_SHARD_SPAWN_GAP),
                dir * C.BONE_SHARD_SPEED, player):ToTear()
            tear.CollisionDamage = swordDamage * C.BONE_SHARD_DAMAGE
            tear:GetData().ZenithShard = true
        end)
    end
    data.ZenithSpawningOwn = nil
end


-- 命中特效替身：只保留 config.PROXY_FLAGS 里的标记（原版命中时才触发的效果），没有时返回 nil
function TearEffects.ProxyFlags(flags)
    if flags == nil then
        return nil
    end
    local out = nil
    for _, name in ipairs(C.PROXY_FLAGS) do
        local flag = TearFlags[name]
        if flag and has(flags, flag) then
            if out == nil then
                out = flag
            else
                local ok, merged = pcall(function() return out | flag end)
                if ok then
                    out = merged
                end
            end
        end
    end
    return out
end

-- 在敌人身上放一颗隐形的替身眼泪（只带命中特效标记、伤害 = 这一下剑的伤害），下一帧撞上敌人，由游戏按原版触发效果。
-- 生成期间在角色数据上做标记（同骨片），并打上 ZenithOwned，测试和“跟班漏出的原生攻击”检测不把它算进去
function TearEffects.SpawnProxy(enemy, player, flags, damage)
    local data = player:GetData()
    data.ZenithSpawningOwn = true
    local ok = pcall(function()
        local tear = Isaac.Spawn(EntityType.ENTITY_TEAR, 0, 0, enemy.Position, Vector.Zero, player):ToTear()
        tear.Parent = player
        tear.TearFlags = flags
        tear.CollisionDamage = damage
        tear.Visible = false
        tear:GetData().ZenithOwned = true
        tear:GetData().ZenithProxy = true
    end)
    data.ZenithSpawningOwn = nil
    return ok
end

-- 命中敌人时调用
function TearEffects.Apply(enemy, flags, player)
    if flags == nil then
        return
    end
    local src = EntityRef(player)
    for _, item in ipairs(EFFECTS) do
        local flag = TearFlags[item[1]]
        if flag and has(flags, flag) then
            pcall(item[2], enemy, src, player, C.STATUS_DURATION)
        end
    end
end

-- 吐根（爆炸泪弹）：每把剑只在第一次命中时炸一次。
-- 和原版吐根一样会炸伤自己（第 8 个参数 DamageSource = true）；伤害标记必须是 DAMAGE_EXPLOSION（函数默认值），
-- 纵火狂、主人帽等才会把它识别为爆炸伤害（回血或免疫）
function TearEffects.Explode(enemy, player, damageMult)
    pcall(function()
        Game():BombExplosionEffects(enemy.Position, player.Damage * C.EXPLOSION_DAMAGE_MULT * (damageMult or 1),
            TearFlags.TEAR_NORMAL, Color.Default, player, C.EXPLOSION_RADIUS_MULT, true, true, DamageFlag.DAMAGE_EXPLOSION)
    end)
end

-- 暴击率：基础 + 每点幸运加成，泪滴挂坠按“幸运类泪弹效果”额外加幸运（与原版规则一致）
function TearEffects.CritChance(player)
    local luck = player.Luck
    local charm = player:GetTrinketMultiplier(TrinketType.TRINKET_TEARDROP_CHARM)
    if charm > 0 then
        luck = luck + C.TEARDROP_CHARM_LUCK + C.TEARDROP_CHARM_LUCK_EXTRA * (charm - 1)
    end
    local chance = C.CRIT_CHANCE_BASE + C.CRIT_CHANCE_PER_LUCK * luck
    return math.max(0, math.min(1, chance))
end

return TearEffects
