-- 游戏内自动测试：只测数值类行为（伤害、射击接管、推炸弹、跟班、状态恢复等），画面表现仍需人工检查。
-- 用法：
--   1. 在一局游戏里打开控制台输入 zenith_test（常规测试）或 zenith_test characters（角色扫描）；都会用控制台命令重开游戏，当前这局会丢失
--   2. 运行 tools/run_ingame_tests.ps1：脚本创建 autotest_flag.lua（含存档位，默认 2）并通过 REPENTOGON 启动器启动游戏。
--      本模块跳过标题画面、在选存档界面把光标固定到指定存档，脚本按确认键；选中的存档正确时
--      开一局“自定义种子”游戏（不解锁成就）并运行全部测试，选错存档则不开局
-- 结果以 “[ZenithTest]” 开头写进 log.txt，最后一行为 “[ZenithTest] DONE”。

local C = include("scripts.zenith.config")
local Crosshair = include("scripts.zenith.crosshair")
local Sword = include("scripts.zenith.sword")
local TearEffects = include("scripts.zenith.tearflags")

local ENTITY_GAPER, ENTITY_BOMB, ENTITY_FIREPLACE = 10, 4, 33
local BOMB_NORMAL, BOMB_TROLL, BOMB_SUPERTROLL = 0, 3, 4
local BOMB_NAMES = { [BOMB_NORMAL] = "普通炸弹", [BOMB_TROLL] = "即爆炸弹", [BOMB_SUPERTROLL] = "超级即爆炸弹" }
local INCUBUS, TWISTED_BABY = 80, 235
local ITEM = {
    SCORPIO = 305, INCUBUS = 360, BFFS = 247, TWISTED_PAIR = 698,
    IPECAC = 149, PYROMANIAC = 223, MEGA_MUSH = 625,
}
local TEARDROP_CHARM = 139
local AUTO_START_SEED = 20261018

local function log(s)
    Isaac.DebugString("[ZenithTest] " .. s)
    print("[ZenithTest] " .. s)
end

-- 只有测试脚本创建了 autotest_flag.lua 时才自动运行，返回其中的设置（存档位等）；
-- 文件里带过期时间，脚本异常退出没删掉时也不会一直触发
local function autoRequested()
    local ok, flag = pcall(include, "scripts.zenith.autotest_flag")
    if not ok or type(flag) ~= "table" then
        return nil
    end
    local okTime, now = pcall(function() return os.time() end)
    if okTime and flag.expires and now > flag.expires then
        return nil
    end
    return flag
end

return function(mod, api)
    local co, sleep = nil, 0
    local passed, failed = 0, 0
    local damageLog, tearsFired = nil, 0
    -- 原生攻击统计（MC_INPUT_ACTION 模拟按住射击键 simNative 时，角色 / 跟班自己发出的眼泪和激光）
    local nativeAttacks, familiarShots = 0, 0
    local electricArcs = 0 -- 雅各的梯子的电弧（不算原生攻击）
    local needleBursts = 0 -- 命中效果产生的眼泪（安乐死的针等，不算原生攻击）
    local boneShards = 0    -- 天顶剑碎出的骨片（TearEffects.BoneShards 生成，带 ZenithShard 标记，不算原生攻击）
    local shardDamages = {} -- 骨片的伤害（第 2 帧读取，此时 CollisionDamage 已设置）
    -- 测试用的临时幸运加成（MC_EVALUATE_CACHE），用完要设回 0 并重新计算
    -- 蓝苍蝇生成数（贴着敌人生成的当帧就可能撞死，只能在初始化时数）
    local blueFlies = 0
    mod:AddCallback(ModCallbacks.MC_FAMILIAR_INIT, function()
        blueFlies = blueFlies + 1
    end, FamiliarVariant.BLUE_FLY)
    local probeLuck, probeDamage = 0, 0
    mod:AddCallback(ModCallbacks.MC_EVALUATE_CACHE, function(_, p, flag)
        if probeLuck ~= 0 and flag == CacheFlag.CACHE_LUCK then
            p.Luck = p.Luck + probeLuck
        end
        if probeDamage ~= 0 and flag == CacheFlag.CACHE_DAMAGE then
            p.Damage = p.Damage + probeDamage
        end
    end)
    local function setProbeLuck(p, luck)
        probeLuck = luck
        p:AddCacheFlags(CacheFlag.CACHE_LUCK)
        p:EvaluateItems()
    end
    local simNative = nil
    local watched = nil   -- 只统计这个角色（和它的跟班）发出的攻击，例如雅各拿剑时不算以扫
    local shotLog = 0     -- 大于 0 时逐发记录来源（诊断用），每记录一发减 1
    local gameStarted = false

    local function check(name, ok, detail)
        if ok then
            passed = passed + 1
            log("PASS " .. name .. (detail and ("  (" .. detail .. ")") or ""))
        else
            failed = failed + 1
            log("FAIL " .. name .. (detail and ("  (" .. detail .. ")") or ""))
        end
    end
    local function near(a, b, eps)
        return math.abs(a - b) <= (eps or 1e-4)
    end
    local function wait(frames)
        coroutine.yield(frames or 1)
    end
    local function waitUntil(cond, maxFrames)
        for _ = 1, maxFrames do
            if cond() then
                return true
            end
            wait(1)
        end
        return cond()
    end

    -- 模拟按住射击键 frames 帧后松手，再等 after 帧（松手才发射的蓄力攻击也能数到），期间固定角色位置
    local function pressFire(p, home, frames, after)
        simNative = Vector(1, 0)
        for _ = 1, frames do
            p.Position, p.Velocity = home, Vector.Zero
            wait(1)
        end
        simNative = nil
        for _ = 1, after do
            p.Position, p.Velocity = home, Vector.Zero
            wait(1)
        end
    end

    local function player()
        return Isaac.GetPlayer(0)
    end
    local function center()
        return Game():GetRoom():GetCenterPos()
    end
    local function state()
        return player():GetData().Zenith
    end

    -- 清掉测试生成的东西（敌人、炸弹、火堆、眼泪、掉落物）和场上的飞剑，把角色放回房间中央
    local function clearRoom()
        for _, e in ipairs(Isaac.GetRoomEntities()) do
            local t = e.Type
            if e:IsEnemy() or t == ENTITY_BOMB or t == ENTITY_FIREPLACE or t == EntityType.ENTITY_TEAR
                or t == EntityType.ENTITY_PICKUP then
                e:Remove()
            end
        end
        local p = player()
        p.Position = center()
        p.Velocity = Vector.Zero
        local st = state()
        if st then
            st.swords = {}
        end
    end

    local function spawnDummy(pos)
        local e = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil):ToNPC()
        e.MaxHitPoints = 100000
        e.HitPoints = 100000
        return e
    end

    -- 把准星固定在 pos（没有时直接生成），固定 pinned 里的实体，持续 frames 帧；返回这段时间出现过的所有飞剑
    local function hold(frames, pos, pinned, onFrame)
        local seen, list = {}, {}
        for _ = 1, frames do
            local p = player()
            local st = api.getState(p)
            local target = st.crosshair
            if not (target and target:Exists()) then
                target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                st.crosshair = target
            end
            target.Position = pos
            target.Velocity = Vector.Zero
            p.Velocity = Vector.Zero
            for _, e in ipairs(pinned or {}) do
                if e.entity:Exists() then
                    e.entity.Position = e.pos
                    e.entity.Velocity = Vector.Zero
                end
            end
            for _, s in ipairs(st.swords) do
                if not seen[s] then
                    seen[s] = true
                    list[#list + 1] = s
                end
            end
            if onFrame then
                onFrame()
            end
            wait(1)
        end
        return list
    end

    local function damageTo(entity)
        local hash, out = GetPtrHash(entity), {}
        for _, d in ipairs(damageLog) do
            if d.hash == hash then
                out[#out + 1] = d
            end
        end
        return out
    end

    local function familiarsOf(variant)
        local out = {}
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, variant)) do
            out[#out + 1] = e
        end
        return out
    end

    -- 统计飞剑：发出者是角色（没有 anchor）的数量、跟班的剑的伤害倍率是否全部等于 mult、出剑的跟班个数
    local function swordStats(list, mult)
        local own, fam, multOk, anchors, nAnchors = 0, 0, true, {}, 0
        for _, s in ipairs(list) do
            if s.anchor then
                fam = fam + 1
                multOk = multOk and near(s.damageMult, mult)
                local h = GetPtrHash(s.anchor)
                if not anchors[h] then
                    anchors[h] = true
                    nAnchors = nAnchors + 1
                end
            else
                own = own + 1
            end
        end
        return own, fam, multOk, nAnchors
    end

    local tests = {}
    local function test(name, fn)
        tests[#tests + 1] = { name = name, fn = fn }
    end

    test("道具配置", function()
        check("道具已加载", api.item ~= -1, "id=" .. api.item)
        local cfg = Isaac.GetItemConfig():GetCollectible(api.item)
        check("品质为 4", cfg and cfg.Quality == 4)
        local gfx = cfg and cfg.GfxFileName or ""
        check("贴图路径正确", gfx:find("collectible_zenith.png", 1, true) ~= nil and not gfx:find("collectibles/collectibles", 1, true), gfx)
        check("准星、渲染器实体已注册", api.crosshair ~= -1 and api.renderer ~= -1)
    end)

    test("接管射击", function()
        local p = player()
        p:AddCollectible(api.item)
        wait(3)
        check("拿到后 CanShoot = false", p:CanShoot() == false)
        check("创建了天顶剑状态", state() ~= nil)
    end)

    test("射击键推动准星、不发射眼泪", function()
        clearRoom()
        tearsFired = 0
        local st = state()
        if st.crosshair and st.crosshair:Exists() then
            st.crosshair:Remove()
            st.crosshair = nil
        end
        local cycle0 = st.cycle
        local p = player()
        st.testInput = Vector(1, 0)
        wait(20)
        st.testInput = nil
        local target = st.crosshair
        check("按住右射击键后准星出现在角色右侧", target ~= nil and target:Exists() and target.Position.X > p.Position.X + 20,
            target and string.format("准星 x-角色 x = %.1f", target.Position.X - p.Position.X) or "没有准星")
        check("出剑次数 > 0", st.cycle > cycle0, "出剑 " .. (st.cycle - cycle0) .. " 次")
        check("没有发射眼泪", tearsFired == 0, "眼泪 " .. tearsFired)
        wait(15)
    end)

    test("准星加速度", function()
        local p = player()
        local mult = math.max(C.CROSSHAIR_SPEED_MULT_MIN, math.min(C.CROSSHAIR_SPEED_MULT_MAX, 1 + (p.ShotSpeed - 1) * C.CROSSHAIR_SHOTSPEED_SCALING))
        check("准星加速度符合弹速公式", near(Crosshair.Accel(p), C.CROSSHAIR_ACCEL * mult),
            string.format("弹速 %.2f，加速度 %.2f", p.ShotSpeed, Crosshair.Accel(p)))
    end)

    test("伤害与暴击", function()
        clearRoom()
        local p = player()
        local pos = center() + Vector(120, 0)
        local dummy = spawnDummy(pos)
        damageLog = {}
        hold(150, pos, { { entity = dummy, pos = pos } })
        local hits = damageTo(dummy)
        local base = p.Damage * C.DAMAGE_MULT
        local ok, crits = #hits > 0, 0
        for _, d in ipairs(hits) do
            if near(d.amount, base * C.CRIT_MULT, 1e-3) then
                crits = crits + 1
            elseif not near(d.amount, base, 1e-3) then
                ok = false
            end
            ok = ok and d.srcType == EntityType.ENTITY_PLAYER
        end
        check("每次命中 = 伤害 × " .. C.DAMAGE_MULT .. "（暴击 ×" .. C.CRIT_MULT .. "）", ok,
            string.format("%d 次命中，伤害 %.2f，首次 %.3f", #hits, p.Damage, hits[1] and hits[1].amount or 0))
        local expected = TearEffects.CritChance(p)
        local rate = #hits > 0 and crits / #hits or 0
        check("暴击率大致符合", #hits >= 20 and math.abs(rate - expected) < 0.2,
            string.format("实际 %.0f%%，理论 %.0f%%，样本 %d", rate * 100, expected * 100, #hits))
        damageLog = nil
        dummy:Remove()
    end)

    test("多个天顶剑叠加伤害", function()
        local p = player()
        for _, n in ipairs({ 2, 3 }) do
            clearRoom()
            while p:GetCollectibleNum(api.item) < n do
                p:AddCollectible(api.item)
            end
            wait(3)
            local pos = center() + Vector(120, 0)
            local dummy = spawnDummy(pos)
            damageLog = {}
            hold(90, pos, { { entity = dummy, pos = pos } })
            local hits = damageTo(dummy)
            local mult = 1 + C.STACK_DAMAGE_BONUS * (n - 1)
            local base = p.Damage * C.DAMAGE_MULT * mult
            local ok = #hits > 0
            for _, d in ipairs(hits) do
                ok = ok and (near(d.amount, base, 1e-3) or near(d.amount, base * C.CRIT_MULT, 1e-3))
            end
            check(string.format("%d 个天顶剑：每次命中 = 伤害 × %.2f × %.1f", n, C.DAMAGE_MULT, mult), ok,
                string.format("%d 次命中，首次 %.3f，预期 %.3f", #hits, hits[1] and hits[1].amount or 0, base))
            damageLog = nil
            dummy:Remove()
        end
        while p:GetCollectibleNum(api.item) > 1 do
            p:RemoveCollectible(api.item)
        end
        wait(3)
        check("移除多余的天顶剑后仍持有 1 个", p:GetCollectibleNum(api.item) == 1 and state() ~= nil)
    end)

    test("幸运与泪滴挂坠", function()
        local p = player()
        local luck = p.Luck
        check("暴击率 = 15% + 5% × 幸运", near(TearEffects.CritChance(p), math.max(0, math.min(1, 0.15 + 0.05 * luck))),
            string.format("幸运 %.1f，暴击率 %.2f", luck, TearEffects.CritChance(p)))
        p:AddTrinket(TEARDROP_CHARM)
        wait(2)
        check("泪滴挂坠 +4 幸运", near(TearEffects.CritChance(p), math.max(0, math.min(1, 0.15 + 0.05 * (p.Luck + 4)))),
            string.format("暴击率 %.2f", TearEffects.CritChance(p)))
        p:TryRemoveTrinket(TEARDROP_CHARM)
        wait(2)
    end)

    test("穆里根：每把剑第一次命中时 1/6 生成蓝苍蝇", function()
        clearRoom()
        local p = player()
        local pos = center() + Vector(120, 0)
        local function run(frames)
            local dummy = spawnDummy(pos)
            blueFlies = 0
            local swords = hold(frames, pos, { { entity = dummy, pos = pos } })
            local hitSwords = 0
            for _, s in ipairs(swords) do
                if next(s.hits) ~= nil then
                    hitSwords = hitSwords + 1
                end
            end
            dummy:Remove()
            for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
                f:Remove()
            end
            return blueFlies, hitSwords
        end
        local controlFlies = run(90)
        check("没有穆里根时不生成蓝苍蝇", controlFlies == 0, "蓝苍蝇 " .. controlFlies)
        p:AddCollectible(CollectibleType.COLLECTIBLE_MULLIGAN)
        wait(3)
        local flies, hitSwords = run(300)
        local expected = hitSwords * C.MULLIGAN_CHANCE
        check("蓝苍蝇数量约为命中的剑 × 1/6", hitSwords >= 30 and flies >= expected * 0.4 and flies <= expected * 2,
            string.format("命中的剑 %d，蓝苍蝇 %d，预期约 %.1f", hitSwords, flies, expected))
        p:RemoveCollectible(CollectibleType.COLLECTIBLE_MULLIGAN)
        wait(3)
    end)

    test("继承泪弹特效（天蝎座：中毒）", function()
        clearRoom()
        local p = player()
        p:AddCollectible(ITEM.SCORPIO)
        wait(3)
        local pos = center() + Vector(120, 0)
        local dummy = spawnDummy(pos)
        local poisoned = false
        hold(90, pos, { { entity = dummy, pos = pos } }, function()
            poisoned = poisoned or dummy:HasEntityFlags(EntityFlag.FLAG_POISON)
        end)
        check("敌人中毒", poisoned)
        p:RemoveCollectible(ITEM.SCORPIO)
        dummy:Remove()
        wait(3)
    end)

    test("场景互动", function()
        clearRoom()
        local pos = center() + Vector(120, 0)
        local fire = Isaac.Spawn(ENTITY_FIREPLACE, 0, 0, pos, Vector.Zero, nil)
        local hp0 = fire.HitPoints
        hold(90, pos)
        check("火堆被打", not fire:Exists() or fire.HitPoints < hp0, string.format("血量 %.1f → %.1f", hp0, fire:Exists() and fire.HitPoints or 0))
        fire:Remove()

        clearRoom()
        local room = Game():GetRoom()
        local poopPos = room:GetGridPosition(room:GetGridIndex(center() + Vector(120, -80)))
        Isaac.GridSpawn(GridEntityType.GRID_POOP, 0, poopPos, true)
        local grid = room:GetGridEntityFromPos(poopPos)
        local state0 = grid and grid.State or -1
        hold(90, poopPos)
        grid = room:GetGridEntityFromPos(poopPos)
        check("地形里的大便被打", grid ~= nil and grid.State ~= state0, string.format("状态 %d → %d", state0, grid and grid.State or -1))
        room:RemoveGridEntity(room:GetGridIndex(poopPos), 0, false)
    end)

    -- 推炸弹的效果看“单帧速度变化最大的一次”（即被撞的那一下），不看总位移：超级即爆炸弹会自己滚向角色
    local function newKickTracker(bomb)
        local last, kick = Vector.Zero, Vector.Zero
        return function()
            if bomb:Exists() then
                local dv = bomb.Velocity - last
                if dv:Length() > kick:Length() then
                    kick = dv
                end
                last = bomb.Velocity
            end
            return kick
        end
    end

    test("推炸弹", function()
        for _, variant in ipairs({ BOMB_NORMAL, BOMB_TROLL, BOMB_SUPERTROLL }) do
            clearRoom()
            local p = player()
            local pos = center() + Vector(120, 40)
            local bomb = Isaac.Spawn(ENTITY_BOMB, variant, 0, pos, Vector.Zero, nil)
            local track = newKickTracker(bomb)
            hold(15, pos, { { entity = p, pos = center() } }, track)
            local kick = track()
            local aim = (pos - (center() + C.ORIGIN_OFFSET)):Normalized()
            local dot = kick:Length() > 0 and (kick.X * aim.X + kick.Y * aim.Y) / kick:Length() or 0
            check(BOMB_NAMES[variant] .. "沿瞄准方向被推动", kick:Length() > 1 and dot > 0.8,
                string.format("单帧速度变化 %.2f，方向一致度 %.2f", kick:Length(), dot))
            bomb:Remove()
        end
    end)

    -- 同一种炸弹分别被一颗普通眼泪、一把飞剑撞一次，比较被撞那一下的速度变化
    test("推炸弹力度：与普通眼泪对比", function()
        local p = player()
        local variants = { BOMB_NORMAL, BOMB_TROLL, BOMB_SUPERTROLL }
        local function measure(variant, push)
            clearRoom()
            local pos = center() + Vector(120, 40)
            local bomb = Isaac.Spawn(ENTITY_BOMB, variant, 0, pos, Vector.Zero, nil)
            wait(2)
            local mass = bomb.Mass
            local track = newKickTracker(bomb)
            track()
            push(pos)
            for _ = 1, 20 do
                p.Position = center()
                p.Velocity = Vector.Zero
                wait(1)
                track()
            end
            bomb:Remove()
            return track():Length(), mass
        end

        -- 1. 不拿天顶剑，朝炸弹发射一颗普通眼泪（速度 = 弹速 × 10）
        p:RemoveCollectible(api.item)
        wait(3)
        local tear, masses = {}, {}
        for _, v in ipairs(variants) do
            tear[v], masses[v] = measure(v, function(pos)
                p:FireTear(p.Position, (pos - p.Position):Resized(p.ShotSpeed * C.TEAR_BASE_SPEED), false, true, false)
            end)
        end

        -- 2. 拿天顶剑，只放出一把瞄准炸弹的飞剑（删掉准星，不再自动出剑）
        p:AddCollectible(api.item)
        wait(3)
        local sword = {}
        for _, v in ipairs(variants) do
            sword[v] = measure(v, function(pos)
                local st = state()
                if st.crosshair and st.crosshair:Exists() then
                    st.crosshair:Remove()
                end
                st.crosshair = nil
                st.swords[#st.swords + 1] = Sword.Create(p.Position + C.ORIGIN_OFFSET, pos, 0, {},
                    p:GetCollectibleRNG(api.item), { critChance = 0 })
            end)
        end

        local okCfg, cfgMass = pcall(function() return EntityConfig.GetEntity(EntityType.ENTITY_TEAR, 0):GetMass() end)
        log(string.format("眼泪质量：游戏配置 %s，推力计算使用 %s", okCfg and tostring(cfgMass) or "读取失败", tostring(Sword.TearMass())))
        for _, v in ipairs(variants) do
            local ratio = tear[v] > 0 and sword[v] / tear[v] or 0
            check(BOMB_NAMES[v] .. "：飞剑推力与普通眼泪一致（±10%）", tear[v] > 0 and ratio > 0.9 and ratio < 1.1,
                string.format("炸弹质量 %.2f，被撞速度变化：眼泪 %.2f，飞剑 %.2f，飞剑/眼泪 = %.2f", masses[v], tear[v], sword[v], ratio))
        end
    end)

    test("模仿型跟班", function()
        local p = player()
        local pos = center() + Vector(120, 0)
        -- 出剑的同时模拟按住射击键：模仿型跟班照搬角色的武器、看射击键开火，拿着天顶剑时不应再发射自己的眼泪
        local native = 0
        local function run(frames)
            clearRoom()
            local dummy = spawnDummy(pos)
            watched, nativeAttacks, simNative = p, 0, Vector(1, 0)
            local list = hold(frames, pos, { { entity = dummy, pos = pos } })
            simNative, watched = nil, nil
            native = nativeAttacks
            dummy:Remove()
            return list
        end

        p:AddCollectible(ITEM.INCUBUS)
        wait(5)
        local own, fam, multOk = swordStats(run(40), C.FAMILIAR_SWORDS[INCUBUS].mult)
        check("Incubus 出剑，倍率 75%", #familiarsOf(INCUBUS) > 0 and fam > 0 and multOk, string.format("角色 %d 把，Incubus %d 把", own, fam))
        check("角色本人照常出剑", own > 0)
        check("Incubus 不再发射自己的眼泪", native == 0, "原生攻击 " .. native .. " 次")

        p:AddCollectible(ITEM.BFFS)
        wait(5)
        own, fam, multOk = swordStats(run(40), C.FAMILIAR_SWORDS[INCUBUS].mult * C.FAMILIAR_BFFS_MULT)
        check("BFFS! 时 Incubus 倍率 ×2", fam > 0 and multOk)
        p:RemoveCollectible(ITEM.BFFS)
        p:RemoveCollectible(ITEM.INCUBUS)
        wait(5)

        p:AddCollectible(ITEM.TWISTED_PAIR)
        wait(5)
        local nAnchors
        own, fam, multOk, nAnchors = swordStats(run(40), C.FAMILIAR_SWORDS[TWISTED_BABY].mult)
        check("扭曲双子两只都出剑，倍率 37.5%", fam > 0 and multOk and nAnchors == 2, string.format("出剑的跟班 %d 只", nAnchors))
        check("扭曲双子不再发射自己的眼泪", native == 0, "原生攻击 " .. native .. " 次")
        p:RemoveCollectible(ITEM.TWISTED_PAIR)
        wait(5)
        check("移除道具后模仿型跟班消失", #familiarsOf(INCUBUS) == 0 and #familiarsOf(TWISTED_BABY) == 0)
    end)

    test("吐根爆炸伤到自己、纵火狂回血", function()
        clearRoom()
        local p = player()
        p:AddCollectible(ITEM.IPECAC)
        p:AddSoulHearts(8)
        wait(3)
        local pos = center() + Vector(30, 0)
        local dummy = spawnDummy(pos)
        damageLog = {}
        hold(60, pos, { { entity = dummy, pos = pos }, { entity = p, pos = center() } })
        local selfHit = false
        for _, d in ipairs(damageTo(p)) do
            selfHit = selfHit or (d.flags & DamageFlag.DAMAGE_EXPLOSION) ~= 0
        end
        check("爆炸伤到角色（爆炸伤害标记）", selfHit)

        -- 纵火狂：拿着它时角色被炸不会触发受伤回调，所以先扣掉一颗红心，看爆炸能不能把血补回来；
        -- 爆炸确实发生过，用敌人受到的爆炸伤害来证明
        p:AddCollectible(ITEM.PYROMANIAC)
        wait(60) -- 等受伤无敌时间结束
        p:AddHearts(-2)
        wait(2)
        local red0 = p:GetHearts()
        damageLog = {}
        hold(60, pos, { { entity = dummy, pos = pos }, { entity = p, pos = center() } })
        local red1 = p:GetHearts()
        local blasts = 0
        for _, d in ipairs(damageTo(dummy)) do
            if (d.flags & DamageFlag.DAMAGE_EXPLOSION) ~= 0 then
                blasts = blasts + 1
            end
        end
        check("纵火狂：被自己的爆炸炸到会回血", blasts > 0 and red1 > red0,
            string.format("爆炸 %d 次，红心 %d → %d（半心为单位）", blasts, red0, red1))
        damageLog = nil
        dummy:Remove()
        p:RemoveCollectible(ITEM.PYROMANIAC)
        p:RemoveCollectible(ITEM.IPECAC)
        wait(3)
    end)

    test("失去天顶剑", function()
        clearRoom()
        local p = player()
        hold(5, center() + Vector(100, 0))
        p:RemoveCollectible(api.item)
        wait(3)
        check("CanShoot 恢复为 true", p:CanShoot() == true)
        check("准星被删除", #Isaac.FindByType(EntityType.ENTITY_EFFECT, api.crosshair) == 0)
        check("天顶剑状态被清除", p:GetData().Zenith == nil)
    end)

    test("巨型蘑菇期间暂停", function()
        clearRoom()
        local p = player()
        p:AddCollectible(api.item)
        wait(3)
        hold(5, center() + Vector(100, 0))
        p:UseActiveItem(ITEM.MEGA_MUSH, UseFlag.USE_NOANIM)
        wait(10)
        local st = state()
        local cycle0 = st.cycle
        hold(30, center() + Vector(100, 0))
        check("变身期间不出剑", st.cycle == cycle0, "出剑 " .. (st.cycle - cycle0) .. " 次")
        check("变身期间准星隐藏", st.crosshair ~= nil and st.crosshair.Visible == false)
        p:GetEffects():RemoveCollectibleEffect(ITEM.MEGA_MUSH, -1)
        wait(10)
    end)

    test("莉莉丝", function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_LILITH)
        check("重开为莉莉丝", waitUntil(function() return gameStarted end, 300))
        wait(30)
        clearRoom()
        local p = player()
        check("当前角色是莉莉丝", p:GetPlayerType() == PlayerType.PLAYER_LILITH)
        p:AddCollectible(api.item)
        wait(5)
        local pos = center() + Vector(120, 0)
        local dummy = spawnDummy(pos)
        local own, fam, multOk = swordStats(hold(40, pos, { { entity = dummy, pos = pos } }), C.FAMILIAR_SWORDS[INCUBUS].lilithMult)
        check("莉莉丝本人不出剑", own == 0, own .. " 把")
        check("Incubus 出剑，倍率 100%", fam > 0 and multOk, fam .. " 把")
        dummy:Remove()
        p:RemoveCollectible(api.item)
        wait(3)
        check("失去天顶剑后莉莉丝仍不能射击", p:CanShoot() == false)
        watched, nativeAttacks = p, 0
        pressFire(p, p.Position, 40, 15)
        watched = nil
        check("失去天顶剑后 Incubus 恢复发射眼泪", nativeAttacks > 0, "原生攻击 " .. nativeAttacks .. " 次")
    end)

    -- 里夏娃的血块：8 种颜色逐个放出来，检查飞剑倍率、固定特效、原生眼泪关闭、骨血块碎骨
    test("里夏娃血块", function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_EVE_B)
        check("重开为里夏娃", waitUntil(function() return gameStarted end, 300))
        wait(30)
        clearRoom()
        local p = player()
        local home = p.Position
        -- 对照：没拿天顶剑时血块确实会开火，后面“不再发射原生眼泪”才有意义
        local probe = Isaac.Spawn(EntityType.ENTITY_FAMILIAR, 238, 0, home + Vector(0, 40), Vector.Zero, p)
        wait(3)
        watched, nativeAttacks = p, 0
        pressFire(p, home, 45, 15)
        watched = nil
        check("对照：没拿天顶剑时血块会发射眼泪", nativeAttacks > 0, "原生攻击 " .. nativeAttacks .. " 次")
        probe:Remove()
        p:AddCollectible(api.item)
        wait(5)
        local rules = C.FAMILIAR_SWORDS[238].subtypes
        for subtype = 0, 7 do
            for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, 238)) do
                e:Remove()
            end
            clearRoom()
            -- 金血块：幸运加到 40，点金概率 1/max(1, 10 - 0.25 × 幸运) = 100%，用来验证概率特效的出剑接线
            if subtype == 4 then
                setProbeLuck(p, 40)
            end
            local clot = Isaac.Spawn(EntityType.ENTITY_FAMILIAR, 238, subtype, home + Vector(0, 40), Vector.Zero, p):ToFamiliar()
            wait(3)
            local pos = home + Vector(120, 0)
            local dummy = spawnDummy(pos)
            shardDamages = {}
            watched, nativeAttacks, boneShards, simNative = p, 0, 0, Vector(1, 0)
            local list = hold(60, pos, { { entity = dummy, pos = pos }, { entity = p, pos = home } })
            simNative, watched = nil, nil
            if subtype == 4 then
                setProbeLuck(p, 0)
            end
            local clotSwords, multOk, flagsOk, chanceOk, burst = 0, true, true, true, 0
            local rule = rules[subtype]
            for _, s in ipairs(list) do
                if s.anchor and GetPtrHash(s.anchor) == GetPtrHash(clot) then
                    clotSwords = clotSwords + 1
                    multOk = multOk and near(s.damageMult, rule.mult)
                    for _, name in ipairs(rule.flags or {}) do
                        flagsOk = flagsOk and TearEffects.Has(s.flags, name)
                    end
                    if rule.chance then
                        chanceOk = chanceOk and TearEffects.Has(s.flags, rule.chance.flag)
                    end
                    if s.bone == false then
                        burst = burst + 1 -- 骨头剑第一次命中后 s.bone 置为 false
                    end
                end
            end
            local tag = "血块 " .. subtype
            check(tag .. "：扔飞剑，倍率 " .. rule.mult, clotSwords > 0 and multOk, string.format("飞剑 %d 把", clotSwords))
            if rule.flags then
                check(tag .. "：飞剑带 " .. table.concat(rule.flags, ","), flagsOk)
            end
            check(tag .. "：不再发射原生眼泪", nativeAttacks == 0, "原生攻击 " .. nativeAttacks .. " 次")
            if subtype == 4 then
                check(tag .. "：幸运 40 时每把剑都带点金", clotSwords > 0 and chanceOk)
            end
            if subtype == 5 then
                check(tag .. "：每把剑只在第一次命中时碎 1～3 块骨片", burst > 0 and boneShards >= burst and boneShards <= 3 * burst,
                    string.format("碎过的剑 %d 把，骨片 %d 块", burst, boneShards))
                local expected = p.Damage * C.DAMAGE_MULT * rule.mult * C.BONE_SHARD_DAMAGE
                local dmgOk = #shardDamages > 0
                for _, d in ipairs(shardDamages) do
                    dmgOk = dmgOk and near(d, expected, 1e-3)
                end
                check(tag .. "：骨片伤害 = 剑单次伤害 × 0.5", dmgOk,
                    string.format("预期 %.3f，实际 %s", expected, shardDamages[1] and string.format("%.3f", shardDamages[1]) or "无"))
            end
            dummy:Remove()
            clot:Remove()
        end
        p:RemoveCollectible(api.item)
        wait(3)
    end)

    -- 放在最后：移除道具后猫套变身不会消失，之后的伤害统计会混进蓝苍蝇的伤害
    test("猫套：每把剑第一次命中时 2/3 在角色身边生成蓝苍蝇", function()
        clearRoom()
        local p = player()
        if not p:HasCollectible(api.item) then
            p:AddCollectible(api.item)
        end
        local guppyItems = { CollectibleType.COLLECTIBLE_GUPPYS_TAIL, CollectibleType.COLLECTIBLE_GUPPYS_COLLAR, CollectibleType.COLLECTIBLE_GUPPYS_PAW }
        for _, item in ipairs(guppyItems) do
            p:AddCollectible(item)
        end
        wait(5)
        check("猫套变身已激活", p:HasPlayerForm(PlayerForm.PLAYERFORM_GUPPY))
        local pos = center() + Vector(120, 0)
        local dummy = spawnDummy(pos)
        blueFlies = 0
        local seenFly, nearPlayer, nearEnemy = {}, 0, 0
        for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
            seenFly[GetPtrHash(f)] = true
        end
        local swords = hold(360, pos, { { entity = dummy, pos = pos } }, function()
            for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
                local key = GetPtrHash(f)
                if not seenFly[key] then
                    seenFly[key] = true
                    if f.Position:Distance(p.Position) < f.Position:Distance(pos) then
                        nearPlayer = nearPlayer + 1
                    else
                        nearEnemy = nearEnemy + 1
                    end
                end
            end
        end)
        local hitSwords = 0
        for _, s in ipairs(swords) do
            if next(s.hits) ~= nil then
                hitSwords = hitSwords + 1
            end
        end
        local expected = hitSwords * C.GUPPY_CHANCE
        check("蓝苍蝇数量约为命中的剑 × 2/3", hitSwords >= 15 and blueFlies >= expected * 0.6 and blueFlies <= expected * 1.4,
            string.format("命中的剑 %d，蓝苍蝇 %d，预期约 %.1f", hitSwords, blueFlies, expected))
        check("蓝苍蝇生成在角色身边", nearPlayer > 0 and nearEnemy == 0, string.format("靠近角色 %d，靠近敌人 %d", nearPlayer, nearEnemy))
        dummy:Remove()
        for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
            f:Remove()
        end
        for _, item in ipairs(guppyItems) do
            p:RemoveCollectible(item)
        end
        wait(5)
    end)

    -- 角色扫描（zenith_test characters / run_ingame_tests.ps1 -Suite characters）：
    -- 每个可选角色重开一局，检查拿到天顶剑后能否出剑、原生攻击是否关闭、跟班是否还在自己射击、失去后能否恢复。
    -- “原生攻击”用 MC_INPUT_ACTION 模拟按住射击键来触发；先在拿剑前做一次对照，对照为 0 说明该角色检测不到，不据此判失败。
    local CHARACTERS = {
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 15, 16, 18, 19,                     -- 普通角色
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37,          -- 里角色
    }
    local charTests = {}

    local function characterCanShoot(p)
        local ok, allowed = pcall(function() return p:GetEntityConfigPlayer():CanShoot() end)
        return not ok or allowed ~= false
    end

    local function findPlayerOfType(id)
        for i = 0, Game():GetNumPlayers() - 1 do
            local p = Isaac.GetPlayer(i)
            if p:GetPlayerType() == id then
                return p
            end
        end
        return nil
    end

    for _, id in ipairs(CHARACTERS) do
        charTests[#charTests + 1] = { id = id, name = "角色 " .. id, fn = function()
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. id)
            if not waitUntil(function() return gameStarted end, 300) then
                check("角色 " .. id .. "：重开", false, "超时")
                return
            end
            wait(30)
            clearRoom()
            local p = findPlayerOfType(id)
            if not p then
                local types = {}
                for i = 0, Game():GetNumPlayers() - 1 do
                    types[#types + 1] = tostring(Isaac.GetPlayer(i):GetPlayerType())
                end
                log(string.format("SKIP 角色 %d：没有找到该角色，当前角色 %s", id, table.concat(types, ",")))
                return
            end
            local tag = string.format("角色 %d %s", id, p:GetName())
            local home = p.Position
            watched = p

            -- 1. 对照：不拿天顶剑，按住射击键 45 帧再松手（硫磺火等蓄力攻击松手才发射）
            nativeAttacks, familiarShots = 0, 0
            pressFire(p, home, 45, 20)
            local control, controlFam = nativeAttacks, familiarShots

            -- 2. 拿到天顶剑：模拟按住射击键的同时让飞剑攻击固定在准星处的敌人
            p:AddCollectible(api.item)
            wait(5)
            local pos = home + Vector(120, 0)
            local dummy = spawnDummy(pos)
            damageLog, nativeAttacks, familiarShots = {}, 0, 0
            shotLog = 8
            simNative = Vector(1, 0)
            local swords = {}
            local st = api.getState(p)
            local gelloFar = 0 -- 吉罗离角色最远的距离（看它是否照常弹出）
            -- 开始时就在场、归属本人的模仿型跟班：它们必须出剑（中途才生成的，比如里夏娃按住射击键造出的血块，不要求）
            local presentMimics = {}
            for variant in pairs(C.FAMILIAR_SWORDS) do
                for _, e in ipairs(familiarsOf(variant)) do
                    local fam = e:ToFamiliar()
                    if fam.Player and GetPtrHash(fam.Player) == GetPtrHash(p) then
                        presentMimics[#presentMimics + 1] = fam
                    end
                end
            end
            for _ = 1, 60 do
                local target = st.crosshair
                if not (target and target:Exists()) then
                    target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                    st.crosshair = target
                end
                target.Position, target.Velocity = pos, Vector.Zero
                p.Position, p.Velocity = home, Vector.Zero
                if dummy:Exists() then
                    dummy.Position, dummy.Velocity = pos, Vector.Zero
                end
                for _, s in ipairs(st.swords) do
                    swords[s] = true
                end
                for _, g in ipairs(familiarsOf(240)) do
                    gelloFar = math.max(gelloFar, g.Position:Distance(p.Position))
                end
                wait(1)
            end
            simNative, shotLog = nil, 0
            for _ = 1, 20 do -- 松手后蓄力攻击才发射，也要算进来
                p.Position, p.Velocity = home, Vector.Zero
                wait(1)
            end
            for variant in pairs(C.FAMILIAR_SWORDS) do
                for _, e in ipairs(familiarsOf(variant)) do
                    local fam = e:ToFamiliar()
                    log(string.format("FAM 角色 %d：跟班 %d.%d，归属该角色 %s", id, e.Variant, e.SubType,
                        tostring(fam.Player ~= nil and GetPtrHash(fam.Player) == GetPtrHash(p))))
                end
            end
            local list = {}
            for s in pairs(swords) do
                list[#list + 1] = s
            end
            local own, fam = swordStats(list, 0)
            local hits = #damageTo(dummy)
            local shootDuring = p:CanShoot()
            log(string.format("CHAR %d %s | 对照：原生攻击 %d，跟班射击 %d | 拿剑后：原生攻击 %d，跟班射击 %d，自己的剑 %d，跟班的剑 %d，命中 %d，CanShoot=%s",
                id, p:GetName(), control, controlFam, nativeAttacks, familiarShots, own, fam, hits, tostring(shootDuring)))
            check(tag .. "：拿剑后关闭原生射击", shootDuring == false)
            if control > 0 then
                check(tag .. "：原生攻击不再触发", nativeAttacks == 0, "拿剑后 " .. nativeAttacks .. " 次")
            end
            check(tag .. "：飞剑能命中敌人", hits > 0, string.format("自己的剑 %d，跟班的剑 %d，命中 %d", own, fam, hits))
            if C.NO_OWN_SWORDS[id] then
                check(tag .. "：本人不出剑，由跟班出剑", own == 0 and fam > 0, string.format("自己的剑 %d，跟班的剑 %d", own, fam))
            end
            local lilithChar = id == PlayerType.PLAYER_LILITH or id == PlayerType.PLAYER_LILITH_B
            for _, fam in ipairs(presentMimics) do
                local rule = C.FAMILIAR_SWORDS[fam.Variant]
                local r = rule.subtypes and rule.subtypes[fam.SubType] or rule
                local expected = lilithChar and r.lilithMult or r.mult
                local n, ok = 0, true
                for _, sword in ipairs(list) do
                    if sword.anchor and GetPtrHash(sword.anchor) == GetPtrHash(fam) then
                        n = n + 1
                        ok = ok and near(sword.damageMult, expected)
                    end
                end
                check(string.format("%s：跟班 %d.%d 出剑，倍率 %.3f", tag, fam.Variant, fam.SubType, expected or -1), n > 0 and ok, n .. " 把")
            end
            if id == PlayerType.PLAYER_LILITH_B then
                check(tag .. "：按住射击键时吉罗照常弹出", gelloFar > 60, string.format("吉罗离角色最远 %.0f", gelloFar))
            end
            damageLog = nil
            dummy:Remove()

            -- 3. 失去天顶剑：射击权限回到角色本来的设定，准星删除
            p:RemoveCollectible(api.item)
            wait(5)
            local expected = characterCanShoot(p)
            check(tag .. "：失去天顶剑后射击权限恢复", p:CanShoot() == expected,
                string.format("CanShoot=%s，角色设定=%s", tostring(p:CanShoot()), tostring(expected)))
            check(tag .. "：失去天顶剑后准星删除", #Isaac.FindByType(EntityType.ENTITY_EFFECT, api.crosshair) == 0)
            if control > 0 then
                nativeAttacks = 0
                pressFire(p, home, 45, 20)
                check(tag .. "：失去天顶剑后原生攻击恢复", nativeAttacks > 0, "原生攻击 " .. nativeAttacks .. " 次")
            end
            if id == 19 then
                local esau = findPlayerOfType(20)
                check(tag .. "：以扫不受影响", esau ~= nil and esau:CanShoot() == true and esau:GetData().Zenith == nil)
            end
        end }
    end

    -- 实测（zenith_test probe_clots / -Suite probe_clots）：里夏娃 8 种血块各自眼泪的伤害倍率、泪弹标记、血量，
    -- 以及复合骨折的碎骨。只用来取得原版数值（结果以 PROBE 开头写进日志），不判定通过与否
    local function tearFlagNames(flags)
        local names = {}
        for name, flag in pairs(TearFlags) do
            if name ~= "TEAR_NORMAL" then
                local ok, hit = pcall(function() return (flags & flag) == flag end)
                if ok and hit then
                    names[#names + 1] = name
                end
            end
        end
        table.sort(names)
        return table.concat(names, ",")
    end

    local probeTests = {}
    probeTests[1] = { name = "血块与碎骨实测", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_EVE_B)
        if not waitUntil(function() return gameStarted end, 300) then
            log("PROBE 重开里夏娃失败")
            return
        end
        wait(30)
        clearRoom()
        local p = player()
        local home = p.Position
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, 238)) do
            e:Remove() -- 开局自带的血块
        end
        wait(2)

        -- 1. 8 种血块：放在角色下方，模拟按住射击键，记录离血块比离角色近的新眼泪（血块的眼泪生成者也是角色）
        for subtype = 0, 7 do
            local clot = Isaac.Spawn(EntityType.ENTITY_FAMILIAR, 238, subtype, home + Vector(0, 40), Vector.Zero, p):ToFamiliar()
            wait(3)
            local owned = clot.Player ~= nil and GetPtrHash(clot.Player) == GetPtrHash(p)
            local seen, logged = {}, 0
            simNative = Vector(1, 0)
            for _ = 1, 45 do
                p.Position, p.Velocity = home, Vector.Zero
                for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                    local tear = t:ToTear()
                    local key = GetPtrHash(t)
                    if tear and not seen[key] then
                        seen[key] = true
                        if clot:Exists() and logged < 4 and tear.Position:Distance(clot.Position) < tear.Position:Distance(p.Position) then
                            logged = logged + 1
                            log(string.format("PROBE 血块 %d：伤害倍率 %.3f（眼泪 %.2f / 角色 %.2f），变体 %d，大小 %.2f，标记 [%s]，血块血量 %.1f，归属角色 %s",
                                subtype, tear.CollisionDamage / p.Damage, tear.CollisionDamage, p.Damage, tear.Variant, tear.Scale,
                                tearFlagNames(tear.TearFlags), clot.MaxHitPoints, tostring(owned)))
                        end
                    end
                end
                wait(1)
            end
            simNative = nil
            if logged == 0 then
                log(string.format("PROBE 血块 %d：45 帧内没有发射眼泪（血块血量 %.1f，归属角色 %s）", subtype, clot.MaxHitPoints, tostring(owned)))
            end
            clot:Remove()
            for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                t:Remove()
            end
            wait(15)
        end

        -- 2. 复合骨折：角色自己的骨头眼泪打中敌人后碎成的骨片（第一次出现在敌人附近的眼泪就是骨片）
        p:AddCollectible(CollectibleType.COLLECTIBLE_COMPOUND_FRACTURE)
        wait(3)
        local pos = home + Vector(120, 0)
        local dummy = spawnDummy(pos)
        local seen, logged, mainLogged = {}, 0, false
        simNative = Vector(1, 0)
        for _ = 1, 60 do
            p.Position, p.Velocity = home, Vector.Zero
            dummy.Position, dummy.Velocity = pos, Vector.Zero
            for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                local tear = t:ToTear()
                local key = GetPtrHash(t)
                if tear and not seen[key] then
                    seen[key] = true
                    if tear.Position:Distance(pos) < 60 then
                        if logged < 12 then
                            logged = logged + 1
                            log(string.format("PROBE 碎骨 f%d：伤害倍率 %.3f，速度 %.2f，方向 %.0f°，变体 %d，大小 %.2f，标记 [%s]",
                                Game():GetFrameCount(), tear.CollisionDamage / p.Damage, tear.Velocity:Length(), tear.Velocity:GetAngleDegrees(),
                                tear.Variant, tear.Scale, tearFlagNames(tear.TearFlags)))
                        end
                    elseif not mainLogged then
                        mainLogged = true
                        log(string.format("PROBE 骨头眼泪本体：伤害倍率 %.3f，速度 %.2f，变体 %d，标记 [%s]",
                            tear.CollisionDamage / p.Damage, tear.Velocity:Length(), tear.Variant, tearFlagNames(tear.TearFlags)))
                    end
                end
            end
            wait(1)
        end
        simNative = nil
        dummy:Remove()
        log("PROBE 结束")
    end }

    -- 实测（-Suite probe_rates）：黑血块的恐惧、金血块的点金在幸运 0 / 10 / 20 时的触发比例，
    -- 腐血块和“穆里根”道具命中后生成蓝苍蝇的比例。为了样本够大：给里夏娃豆奶（射速 ×5.5），同色血块一次放 4 个。
    -- 幸运通过 MC_EVALUATE_CACHE 临时加上（probeLuck，定义在文件开头）

    -- 蓝苍蝇生成计数：贴着敌人生成的苍蝇当帧就会撞上去死掉，按帧扫描看不到，所以在初始化回调里数
    local flyInits = 0
    local famInits = {} -- 测试期间初始化的所有跟班变体（看命中时到底生成了什么）
    mod:AddCallback(ModCallbacks.MC_FAMILIAR_INIT, function(_, fam)
        if fam.Variant == FamiliarVariant.BLUE_FLY then
            flyInits = flyInits + 1
        end
        famInits[fam.Variant] = (famInits[fam.Variant] or 0) + 1
    end)

    -- part："chances" 只测恐惧/点金概率（-Only 1），"flies" 只测蓝苍蝇（-Only 2）
    local function rateProbe(part)
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_EVE_B)
        if not waitUntil(function() return gameStarted end, 300) then
            log("PROBE 重开里夏娃失败")
            return
        end
        wait(30)
        clearRoom()
        local p = player()
        local home = p.Position
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, 238)) do
            e:Remove()
        end
        if part == "chances" then
            p:AddCollectible(CollectibleType.COLLECTIBLE_SOY_MILK) -- 射速 ×5.5，加大样本
        end
        wait(3)

        local function setLuck(luck)
            probeLuck = luck
            p:AddCacheFlags(CacheFlag.CACHE_LUCK)
            p:EvaluateItems()
        end

        -- subtype 为 nil 时统计角色自己的眼泪（穆里根对照）；否则只统计血块的眼泪，角色自己的眼泪直接删掉
        -- normalEnemy 为 true 时用默认血量的普通敌人（死了就补一个），对照“超高血量假人”是否影响命中特效
        local function sample(label, subtype, count, frames, normalEnemy)
            local clots = {}
            for i = 1, count do
                clots[i] = Isaac.Spawn(EntityType.ENTITY_FAMILIAR, 238, subtype or 0, home + Vector(-30 + 20 * i, 40), Vector.Zero, p):ToFamiliar()
            end
            if not subtype then
                for _, c in ipairs(clots) do
                    c:Remove()
                end
                clots = {}
            end
            local pos = home + Vector(110, 30)
            local dummy = normalEnemy and Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil) or spawnDummy(pos)
            local killed = 0
            wait(3)
            local function nearestClot(position)
                local best = math.huge
                for _, c in ipairs(clots) do
                    if c:Exists() then
                        best = math.min(best, c.Position:Distance(position))
                    end
                end
                return best
            end
            local seen, seenFlies = {}, {}
            for _, fly in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
                seenFlies[GetPtrHash(fly)] = true
            end
            local tears, fear, midas, newFlies = 0, 0, 0, 0
            flyInits, famInits = 0, {}
            damageLog = {}
            simNative = Vector(1, 0)
            for _ = 1, frames do
                p.Position, p.Velocity = home, Vector.Zero
                if normalEnemy then
                    p:SetMinDamageCooldown(60)
                    if not dummy:Exists() or dummy:IsDead() then
                        killed = killed + 1
                        dummy = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil)
                    end
                end
                if dummy:Exists() then
                    dummy.Position, dummy.Velocity = pos, Vector.Zero
                end
                for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                    local tear = t:ToTear()
                    local key = GetPtrHash(t)
                    if tear and not seen[key] then
                        seen[key] = true
                        local fromClot = subtype and nearestClot(tear.Position) < tear.Position:Distance(p.Position)
                        if fromClot or not subtype then
                            tears = tears + 1
                            local flags = tear.TearFlags
                            if (flags & TearFlags.TEAR_FEAR) == TearFlags.TEAR_FEAR then
                                fear = fear + 1
                            end
                            if (flags & TearFlags.TEAR_MIDAS) == TearFlags.TEAR_MIDAS then
                                midas = midas + 1
                            end
                        else
                            t:Remove()
                        end
                    end
                end
                for _, fly in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
                    local key = GetPtrHash(fly)
                    if not seenFlies[key] then
                        seenFlies[key] = true
                        newFlies = newFlies + 1
                    end
                end
                wait(1)
            end
            simNative = nil
            newFlies = math.max(newFlies, flyInits)
            local hits = 0 -- 敌人（包括补上来的普通敌人）受到的所有伤害次数
            for _, d in ipairs(damageLog) do
                if d.hash ~= GetPtrHash(p) then
                    hits = hits + 1
                end
            end
            damageLog = nil
            if normalEnemy then
                log("PROBE   普通敌人被打死 " .. killed .. " 只")
            end
            log(string.format("PROBE %s（幸运 %.1f）：眼泪 %d，恐惧 %d（%.1f%%），点金 %d（%.1f%%），命中 %d，新蓝苍蝇 %d（每次命中 %.1f%%）",
                label, p.Luck, tears, fear, tears > 0 and fear * 100 / tears or 0, midas, tears > 0 and midas * 100 / tears or 0,
                hits, newFlies, hits > 0 and newFlies * 100 / hits or 0))
            local inits = {}
            for variant, n in pairs(famInits) do
                inits[#inits + 1] = variant .. "×" .. n
            end
            log("PROBE   期间初始化的跟班变体：" .. (#inits > 0 and table.concat(inits, "，") or "无"))
            for _, c in ipairs(clots) do
                c:Remove()
            end
            dummy:Remove()
            for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
                f:Remove()
            end
            for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                t:Remove()
            end
            wait(10)
        end

        if part == "chances" then
            for _, luck in ipairs({ 0, 10, 20 }) do
                setLuck(luck)
                sample("黑血块", 2, 4, 450)
                sample("金血块", 4, 4, 450)
            end
            setLuck(0)
        else
            sample("腐血块（普通敌人）", 6, 4, 600, true)
            p:AddCollectible(CollectibleType.COLLECTIBLE_MULLIGAN)
            wait(3)
            sample("角色自己的眼泪 + 穆里根（普通敌人）", nil, 0, 600, true)
        end
        log("PROBE 结束")
    end
    local rateTests = {
        { id = 1, name = "血块恐惧/点金概率实测", fn = function() rateProbe("chances") end },
        { id = 2, name = "蓝苍蝇实测", fn = function() rateProbe("flies") end },
    }

    -- 压力测试（-Suite stress）：复现闪退用。里夏娃 + 天顶剑 + BFFS! + 复合骨折 + 多只血块，
    -- 持续生成敌人并出剑，每隔一段时间做一次完整垃圾回收并换房间。能跑完说明没有崩溃
    local stressTests = {}
    stressTests[1] = { name = "闪退复现压力测试", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_EVE_B)
        if not waitUntil(function() return gameStarted end, 300) then
            check("重开里夏娃", false, "超时")
            return
        end
        wait(30)
        local p = player()
        p:AddCollectible(api.item)
        p:AddCollectible(CollectibleType.COLLECTIBLE_BFFS)
        p:AddCollectible(CollectibleType.COLLECTIBLE_COMPOUND_FRACTURE)
        wait(5)
        local level = Game():GetLevel()
        local rooms = {}
        for i = 0, level:GetRooms().Size - 1 do
            local desc = level:GetRooms():Get(i)
            if desc and desc.Data and desc.Data.Type == RoomType.ROOM_DEFAULT then
                rooms[#rooms + 1] = desc.SafeGridIndex
            end
        end
        log("STRESS 可用房间 " .. #rooms .. " 个")
        local transitions = 0
        for cycle = 1, 40 do
            local room = Game():GetRoom()
            local c = room:GetCenterPos()
            for subtype = 0, 7 do
                Isaac.Spawn(EntityType.ENTITY_FAMILIAR, 238, subtype, p.Position + Vector(-40 + 10 * subtype, 30), Vector.Zero, p)
            end
            for k = 1, 4 do
                local e = Isaac.Spawn(226, 0, 0, c + Vector(-150 + 100 * k, -80), Vector.Zero, nil):ToNPC()
                e.MaxHitPoints, e.HitPoints = 500, 500
            end
            local st = api.getState(p)
            for f = 1, 240 do
                p:SetMinDamageCooldown(30)
                local target = st.crosshair
                if not (target and target:Exists()) then
                    target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, c, Vector.Zero, p):ToEffect()
                    st.crosshair = target
                end
                target.Position = c + Vector(math.cos(f * 0.05) * 120, math.sin(f * 0.07) * 60)
                target.Velocity = Vector.Zero
                wait(1)
            end
            log(string.format("STRESS 第 %d 轮：飞剑 %d，Lua 内存 %.0f KB", cycle, #st.swords, collectgarbage("count")))
            collectgarbage("collect")
            if #rooms > 0 then
                Game():ChangeRoom(rooms[(cycle % #rooms) + 1])
                transitions = transitions + 1
                wait(40)
            end
        end
        check("压力测试跑完没有崩溃", true, "换房间 " .. transitions .. " 次")
    end }

    -- 闪退复现（-Suite repro）：用户两次闪退都在种子 ASFL T04R、里夏娃、进入 1.822 号房间后不久。
    -- 按当时的路线走：拿天顶剑 + BFFS!，进 1.822 用剑打怪，去 1.927 再回来，重复几次
    local reproTests = {}
    reproTests[1] = { name = "闪退现场复现", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_EVE_B)
        waitUntil(function() return gameStarted end, 300)
        wait(20)
        gameStarted = false
        Isaac.ExecuteCommand("seed ASFL T04R")
        check("用种子 ASFL T04R 开局", waitUntil(function() return gameStarted end, 300))
        wait(30)
        local p = player()
        log(string.format("REPRO 角色 %d，种子 %s", p:GetPlayerType(), Game():GetSeeds():GetStartSeedString()))
        p:AddCollectible(api.item)
        p:AddCollectible(CollectibleType.COLLECTIBLE_BFFS)
        wait(5)
        local level = Game():GetLevel()
        local function findRoom(variant)
            for i = 0, level:GetRooms().Size - 1 do
                local desc = level:GetRooms():Get(i)
                if desc and desc.Data and desc.Data.Variant == variant then
                    return desc.SafeGridIndex
                end
            end
        end
        local list = {}
        for i = 0, level:GetRooms().Size - 1 do
            local desc = level:GetRooms():Get(i)
            if desc and desc.Data then
                list[#list + 1] = desc.Data.Type .. "." .. desc.Data.Variant .. "@" .. desc.SafeGridIndex
            end
        end
        log("REPRO 本层房间：" .. table.concat(list, " ") .. "；楼层 " .. level:GetStage() .. "." .. level:GetStageType())
        local r822, r927 = findRoom(822), findRoom(927)
        log(string.format("REPRO 1.822 在格子 %s，1.927 在格子 %s", tostring(r822), tostring(r927)))
        if not r822 then
            check("找到 1.822 号房间", false)
            return
        end
        for round = 1, 4 do
            Game():ChangeRoom(r822)
            wait(30)
            local st = api.getState(p)
            for f = 1, 450 do
                p:SetMinDamageCooldown(30)
                local target = st.crosshair
                if not (target and target:Exists()) then
                    target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, p.Position, Vector.Zero, p):ToEffect()
                    st.crosshair = target
                end
                -- 准星追着最近的敌人
                local best, bestDist = nil, math.huge
                for _, e in ipairs(Isaac.GetRoomEntities()) do
                    if e:IsVulnerableEnemy() and e:IsActiveEnemy(false) then
                        local d = e.Position:Distance(p.Position)
                        if d < bestDist then
                            best, bestDist = e, d
                        end
                    end
                end
                target.Position = best and best.Position or (p.Position + Vector(math.cos(f * 0.05) * 100, math.sin(f * 0.05) * 60))
                target.Velocity = Vector.Zero
                wait(1)
            end
            log(string.format("REPRO 第 %d 轮在 1.822 打完：飞剑 %d，Lua 内存 %.0f KB", round, #st.swords, collectgarbage("count")))
            if r927 then
                Game():ChangeRoom(r927)
                wait(120)
            end
        end
        check("复现路线走完没有崩溃", true)
    end }

    -- 阶段 B 实测（-Suite probe_b，只记录数值，不判定）：1 遗骸射速，2 穆里根，3 塞壬魅惑跟班
    local probeB = {}
    local function maxDelay(p)
        p:AddCacheFlags(CacheFlag.CACHE_FIREDELAY)
        p:EvaluateItems()
        return p.MaxFireDelay
    end
    probeB[1] = { id = 1, name = "遗骸射速实测", fn = function()
        local configs = {
            { "无道具", {} },
            { "2 个悲伤洋葱", { CollectibleType.COLLECTIBLE_SAD_ONION, CollectibleType.COLLECTIBLE_SAD_ONION } },
            { "硫磺火", { CollectibleType.COLLECTIBLE_BRIMSTONE } },
            { "吐根", { CollectibleType.COLLECTIBLE_IPECAC } },
        }
        for _, id in ipairs({ PlayerType.PLAYER_ISAAC, PlayerType.PLAYER_THEFORGOTTEN, PlayerType.PLAYER_THEFORGOTTEN_B }) do
            for _, cfg in ipairs(configs) do
                gameStarted = false
                Isaac.ExecuteCommand("restart " .. id)
                waitUntil(function() return gameStarted end, 300)
                wait(20)
                local p = player()
                for _, item in ipairs(cfg[2]) do
                    p:AddCollectible(item)
                end
                wait(5)
                local line = string.format("PROBE 射速 角色 %d %s：MaxFireDelay %.3f", id, cfg[1], maxDelay(p))
                if id == PlayerType.PLAYER_THEFORGOTTEN then
                    pcall(function() p:SwapForgottenForm(true, true) end)
                    wait(15)
                    p = player()
                    line = line .. string.format("；切到灵魂（%d）后 %.3f", p:GetPlayerType(), maxDelay(p))
                elseif id == PlayerType.PLAYER_THEFORGOTTEN_B then
                    local soul = findPlayerOfType(PlayerType.PLAYER_THESOUL_B)
                    line = line .. string.format("；灵魂 %.3f", soul and maxDelay(soul) or -1)
                end
                log(line)
            end
        end
    end }
    probeB[2] = { id = 2, name = "穆里根实测", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(CollectibleType.COLLECTIBLE_MULLIGAN)
        wait(5)
        local home = p.Position
        for _, pinned in ipairs({ true, false }) do
            local pos = home + Vector(110, 0)
            local enemy = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil)
            local seen, tears, flagged, flaggedGone, killed = {}, 0, 0, 0, 0
            local flagTears = {}
            flyInits, famInits = 0, {}
            damageLog = {}
            simNative = Vector(1, 0)
            for _ = 1, 900 do
                p.Position, p.Velocity = home, Vector.Zero
                p:SetMinDamageCooldown(60)
                if not enemy:Exists() or enemy:IsDead() then
                    killed = killed + 1
                    enemy = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil)
                end
                if pinned then
                    enemy.Position, enemy.Velocity = pos, Vector.Zero
                end
                for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                    local tear = t:ToTear()
                    local key = GetPtrHash(t)
                    if tear and not seen[key] then
                        seen[key] = true
                        tears = tears + 1
                        if (tear.TearFlags & TearFlags.TEAR_MULLIGAN) == TearFlags.TEAR_MULLIGAN then
                            flagged = flagged + 1
                            flagTears[#flagTears + 1] = t
                        end
                    end
                end
                for i = #flagTears, 1, -1 do
                    local t = flagTears[i]
                    if not t:Exists() then
                        flaggedGone = flaggedGone + 1
                        table.remove(flagTears, i)
                    end
                end
                wait(1)
            end
            simNative = nil
            local hits = 0
            for _, d in ipairs(damageLog) do
                if d.hash ~= GetPtrHash(p) then
                    hits = hits + 1
                end
            end
            damageLog = nil
            local inits = {}
            for variant, n in pairs(famInits) do
                inits[#inits + 1] = variant .. "×" .. n
            end
            log(string.format("PROBE 穆里根（敌人%s）：眼泪 %d，带穆里根标记 %d（%.1f%%），带标记的消失 %d，命中 %d，打死 %d，蓝苍蝇 %d；初始化的跟班 %s",
                pinned and "固定" or "自由移动", tears, flagged, tears > 0 and flagged * 100 / tears or 0, flaggedGone, hits, killed,
                flyInits, #inits > 0 and table.concat(inits, "，") or "无"))
            enemy:Remove()
            clearRoom()
            wait(10)
        end
    end }
    -- 对照：穆里根是否对 Incubus 的眼泪生效、里夏娃拿穆里根、腐血块。只统计跟班的眼泪（离角色比离跟班近的眼泪直接删掉）
    local guppyOnly = false -- probe 6 复用下面的统计：只测猫套对 Incubus 眼泪是否生效
    probeB[4] = { id = 4, name = "穆里根对照实测", fn = function()
        local function sampleFlies(label, character, setup)
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. character)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, 238)) do
                e:Remove()
            end
            local home = p.Position
            local onlyFamiliars, enemyOffset = setup(p, home)
            wait(10)
            local pos = home + (enemyOffset or Vector(110, 0))
            local enemy = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil)
            local seen, tears = {}, 0
            flyInits, famInits = 0, {}
            damageLog = {}
            simNative = Vector(1, 0)
            for _ = 1, 900 do
                p.Position, p.Velocity = home, Vector.Zero
                p:SetMinDamageCooldown(60)
                if not enemy:Exists() or enemy:IsDead() then
                    enemy = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil)
                end
                enemy.Position, enemy.Velocity = pos, Vector.Zero
                for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                    local key = GetPtrHash(t)
                    if not seen[key] then
                        seen[key] = true
                        local famDist = math.huge
                        for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR)) do
                            if f.Variant ~= FamiliarVariant.BLUE_FLY then
                                famDist = math.min(famDist, f.Position:Distance(t.Position))
                            end
                        end
                        if onlyFamiliars and t.Position:Distance(p.Position) < famDist then
                            t:Remove()
                        else
                            tears = tears + 1
                        end
                    end
                end
                wait(1)
            end
            simNative = nil
            local hits = 0
            for _, d in ipairs(damageLog) do
                if d.hash ~= GetPtrHash(p) then
                    hits = hits + 1
                end
            end
            damageLog = nil
            log(string.format("PROBE 穆里根对照 %s：统计的眼泪 %d，命中 %d，蓝苍蝇 %d（每次命中 %.1f%%）", label, tears, hits, flyInits,
                hits > 0 and flyInits * 100 / hits or 0))
            enemy:Remove()
            clearRoom()
            wait(10)
        end
        if guppyOnly then
            sampleFlies("以撒 + Incubus + 猫套（只统计 Incubus）", PlayerType.PLAYER_ISAAC, function(p)
                p:AddCollectible(CollectibleType.COLLECTIBLE_INCUBUS)
                for _, item in ipairs({ CollectibleType.COLLECTIBLE_GUPPYS_TAIL, CollectibleType.COLLECTIBLE_GUPPYS_COLLAR, CollectibleType.COLLECTIBLE_GUPPYS_PAW }) do
                    p:AddCollectible(item)
                end
                return true
            end)
            return
        end
        sampleFlies("以撒 + 穆里根（角色自己的眼泪）", PlayerType.PLAYER_ISAAC, function(p)
            p:AddCollectible(CollectibleType.COLLECTIBLE_MULLIGAN)
            return false
        end)
        sampleFlies("以撒 + Incubus + 穆里根（只统计 Incubus）", PlayerType.PLAYER_ISAAC, function(p)
            p:AddCollectible(CollectibleType.COLLECTIBLE_INCUBUS)
            p:AddCollectible(CollectibleType.COLLECTIBLE_MULLIGAN)
            return true
        end)
        sampleFlies("里夏娃 + 穆里根（角色自己的眼泪）", PlayerType.PLAYER_EVE_B, function(p)
            p:AddCollectible(CollectibleType.COLLECTIBLE_MULLIGAN)
            return false
        end)
        sampleFlies("以撒 + 4 个腐血块（只统计血块）", PlayerType.PLAYER_ISAAC, function(p, home)
            for i = 1, 4 do
                Isaac.Spawn(EntityType.ENTITY_FAMILIAR, 238, 6, home + Vector(-30 + 20 * i, 40), Vector.Zero, p)
            end
            return true, Vector(110, 40) -- 血块在角色下方，敌人放在它们的弹道上
        end)
    end }
    -- 猫套（嗝屁猫套装）：原版眼泪命中时生成蓝苍蝇的比例和位置，对比拿天顶剑时
    probeB[5] = { id = 5, name = "猫套实测", fn = function()
        for _, withZenith in ipairs({ false, true }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            for _, item in ipairs({ CollectibleType.COLLECTIBLE_GUPPYS_TAIL, CollectibleType.COLLECTIBLE_GUPPYS_COLLAR, CollectibleType.COLLECTIBLE_GUPPYS_PAW }) do
                p:AddCollectible(item)
            end
            if withZenith then
                p:AddCollectible(api.item)
            end
            wait(10)
            local home = p.Position
            local pos = home + Vector(110, 0)
            local enemy = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil)
            local st = withZenith and api.getState(p) or nil
            local seenFly, nearPlayer, nearEnemy, killed, seenTear, tears = {}, 0, 0, 0, {}, 0
            for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
                seenFly[GetPtrHash(f)] = true
            end
            flyInits = 0
            damageLog = {}
            simNative = Vector(1, 0)
            for _ = 1, withZenith and 450 or 1800 do
                p.Position, p.Velocity = home, Vector.Zero
                p:SetMinDamageCooldown(60)
                if not enemy:Exists() or enemy:IsDead() then
                    killed = killed + 1
                    enemy = Isaac.Spawn(ENTITY_GAPER, 0, 0, pos, Vector.Zero, nil)
                end
                enemy.Position, enemy.Velocity = pos, Vector.Zero
                if st then
                    local target = st.crosshair
                    if not (target and target:Exists()) then
                        target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                        st.crosshair = target
                    end
                    target.Position, target.Velocity = pos, Vector.Zero
                end
                for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                    if not seenTear[GetPtrHash(t)] then
                        seenTear[GetPtrHash(t)] = true
                        tears = tears + 1
                    end
                end
                for _, f in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, FamiliarVariant.BLUE_FLY)) do
                    local key = GetPtrHash(f)
                    if not seenFly[key] then
                        seenFly[key] = true
                        if f.Position:Distance(home) < f.Position:Distance(pos) then
                            nearPlayer = nearPlayer + 1
                        else
                            nearEnemy = nearEnemy + 1
                        end
                    end
                end
                wait(1)
            end
            simNative = nil
            local hits = 0
            for _, d in ipairs(damageLog) do
                if d.hash ~= GetPtrHash(p) then
                    hits = hits + 1
                end
            end
            damageLog = nil
            log(string.format("PROBE 猫套（%s）：猫套变身=%s，眼泪 %d，命中 %d（含蓝苍蝇的伤害），打死 %d，蓝苍蝇 %d（每颗眼泪 %.1f%%），首次看到时靠近角色 %d、靠近敌人 %d",
                withZenith and "拿天顶剑" or "原版眼泪", tostring(p:HasPlayerForm(PlayerForm.PLAYERFORM_GUPPY)), tears, hits, killed, flyInits,
                tears > 0 and flyInits * 100 / tears or 0, nearPlayer, nearEnemy))
            enemy:Remove()
        end
    end }
    probeB[6] = { id = 6, name = "猫套对 Incubus 实测", fn = function()
        guppyOnly = true
        probeB[4].fn()
        guppyOnly = false
    end }
    -- 攻击类道具原版数值（联动用）：对固定假人的每次伤害、射击间隔、期间生成的激光 / 炸弹 / 特效。
    -- pattern：{ 按住帧数, 松开帧数 } 依次执行（蓄力类松手才发射）
    local function sampleWeapon(label, character, items, pattern, extra, follow)
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. character)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        for _, item in ipairs(items) do
            p:AddCollectible(item)
        end
        wait(10)
        local home = p.Position
        local pos = home + Vector(100, 0)
        local dummy = spawnDummy(pos)
        local seen, spawned = {}, {}
        local function scan()
            for _, e in ipairs(Isaac.GetRoomEntities()) do
                local key = GetPtrHash(e)
                if not seen[key] and (e.Type == EntityType.ENTITY_LASER or e.Type == EntityType.ENTITY_BOMB
                    or e.Type == EntityType.ENTITY_KNIFE or e.Type == EntityType.ENTITY_TEAR
                    or (e.Type == EntityType.ENTITY_EFFECT and e.Variant ~= api.renderer and e.Variant ~= api.crosshair)) then
                    seen[key] = true
                    local desc = e.Type .. "." .. e.Variant
                    local laser = e:ToLaser()
                    if laser then
                        desc = desc .. string.format("(timeout %d,maxdist %.0f,dmg %.2f)", laser.Timeout, laser.MaxDistance, laser.CollisionDamage)
                    end
                    spawned[desc] = (spawned[desc] or 0) + 1
                end
            end
        end
        if extra then
            extra(p, pos)
        end
        damageLog = {}
        local frames = 0
        for _, step in ipairs(pattern) do
            for phase = 1, 2 do
                simNative = phase == 1 and Vector(1, 0) or nil
                for _ = 1, step[phase] do
                    p.Position, p.Velocity = home, Vector.Zero
                    p:SetMinDamageCooldown(60)
                    if follow then
                        pos = follow(p) or pos
                    end
                    dummy.Position, dummy.Velocity = pos, Vector.Zero
                    scan()
                    frames = frames + 1
                    wait(1)
                end
            end
        end
        simNative = nil
        local hist, total, n, hitFrames = {}, 0, 0, {}
        for _, d in ipairs(damageLog) do
            if d.hash == GetPtrHash(dummy) then
                n = n + 1
                hitFrames[#hitFrames + 1] = tostring(d.frame)
                total = total + d.amount
                local k = string.format("%.2f", d.amount)
                hist[k] = (hist[k] or 0) + 1
            end
        end
        damageLog = nil
        local parts = {}
        for k, v in pairs(hist) do
            parts[#parts + 1] = k .. "×" .. v
        end
        table.sort(parts)
        local sp = {}
        for k, v in pairs(spawned) do
            sp[#sp + 1] = k .. "×" .. v
        end
        log(string.format("PROBE 武器 %s：伤害 %.2f，MaxFireDelay %.2f，%d 帧内命中 %d 次，总伤害 %.1f（= 角色伤害 × %.2f）；每次伤害 %s；生成 %s；命中帧 %s",
            label, p.Damage, p.MaxFireDelay, frames, n, total, total / p.Damage, table.concat(parts, " "), table.concat(sp, " "),
            #hitFrames <= 12 and table.concat(hitFrames, ",") or (#hitFrames .. " 个")))
        dummy:Remove()
    end
    probeB[7] = { id = 7, name = "攻击类道具原版数值", fn = function()
        local I = CollectibleType
        sampleWeapon("普通眼泪", PlayerType.PLAYER_ISAAC, {}, { { 90, 30 } })
        sampleWeapon("硫磺火（蓄满一发）", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_BRIMSTONE }, { { 75, 75 } })
        sampleWeapon("阿撒泻勒（蓄满一发）", PlayerType.PLAYER_AZAZEL, {}, { { 75, 75 } })
        sampleWeapon("科技", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_TECHNOLOGY }, { { 90, 30 } })
        sampleWeapon("博士胎儿", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_DR_FETUS }, { { 150, 90 } })
        sampleWeapon("史诗胎儿（按住）", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_EPIC_FETUS }, { { 150, 90 } })
        sampleWeapon("直接生成导弹特效", PlayerType.PLAYER_ISAAC, {}, { { 0, 90 } }, function(p, pos)
            local rocket = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.ROCKET, 0, pos, Vector.Zero, p)
            log("PROBE   导弹特效生成：" .. tostring(rocket and rocket:Exists()))
        end)
        sampleWeapon("妈刀（蓄满一发）", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_MOMS_KNIFE }, { { 90, 60 } })
        sampleWeapon("妈刀（轻点一发）", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_MOMS_KNIFE }, { { 3, 60 } })
    end }
    -- 史诗胎儿：在假人处生成原版瞄准特效（1000.30），看会不会落导弹、伤害多少；分别测不拿 / 拿着天顶剑（射击权限被关闭）
    probeB[8] = { id = 8, name = "史诗胎儿导弹实测", fn = function()
        local I = CollectibleType
        for _, cfg in ipairs({
            { "史诗胎儿 + 瞄准特效", { I.COLLECTIBLE_EPIC_FETUS } },
            { "史诗胎儿 + 天顶剑 + 瞄准特效", { I.COLLECTIBLE_EPIC_FETUS, api.item } },
            { "无史诗胎儿 + 瞄准特效", {} },
        }) do
            sampleWeapon(cfg[1], PlayerType.PLAYER_ISAAC, cfg[2], { { 0, 150 } }, function(p, pos)
                local t = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.TARGET, 0, pos, Vector.Zero, p)
                log("PROBE   瞄准特效生成：" .. tostring(t and t:Exists()))
            end)
        end
        -- 原版按住射击键：假人每帧放到原版准星上，测导弹伤害和落下间隔
        local function onTarget()
            local t = Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.TARGET)[1]
            return t and t.Position
        end
        sampleWeapon("史诗胎儿（按住，假人跟着准星）", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_EPIC_FETUS }, { { 360, 60 } }, nil, onTarget)
        sampleWeapon("史诗胎儿 + 2 个悲伤洋葱（按住，假人跟着准星）", PlayerType.PLAYER_ISAAC,
            { I.COLLECTIBLE_EPIC_FETUS, I.COLLECTIBLE_SAD_ONION, I.COLLECTIBLE_SAD_ONION }, { { 360, 60 } }, nil, onTarget)
    end }
    -- 妈刀贴图：从真实的妈刀实体读出精灵文件、动画、帧尺寸，以及朝右扔出时的旋转（决定我们画刀时的角度偏移）
    probeB[9] = { id = 9, name = "妈刀贴图实测", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(CollectibleType.COLLECTIBLE_MOMS_KNIFE)
        wait(10)
        local function describe(tag)
            for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_KNIFE)) do
                local s = e:GetSprite()
                local info = {}
                local function try(name, fn)
                    local ok, v = pcall(fn)
                    info[#info + 1] = name .. "=" .. (ok and tostring(v) or "×")
                end
                try("文件", function() return s:GetFilename() end)
                try("动画", function() return s:GetAnimation() end)
                try("帧", function() return s:GetFrame() end)
                try("精灵旋转", function() return s.Rotation end)
                try("实体旋转", function() return e:ToKnife().Rotation end)
                try("缩放", function() return s.Scale end)
                try("层数", function() return s:GetLayerCount() end)
                try("帧尺寸", function()
                    local f = s:GetCurrentAnimationData():GetLayer(0):GetFrame(s:GetFrame())
                    return string.format("%.0fx%.0f 中心(%.0f,%.0f)", f:GetWidth(), f:GetHeight(), f:GetPivot().X, f:GetPivot().Y)
                end)
                try("速度", function() return e.Velocity end)
                try("离角色", function() return e.Position - p.Position end)
                log(string.format("PROBE 妈刀（%s）变体 %d.%d：%s", tag, e.Variant, e.SubType, table.concat(info, "，")))
            end
        end
        describe("静止")
        simNative = Vector(1, 0)
        wait(60)
        describe("向右蓄满")
        simNative = nil
        wait(4)
        describe("向右扔出后 4 帧")
        simNative = Vector(0, 1)
        wait(10)
        describe("改为向下瞄准")
        simNative = nil
    end }
    -- 硫磺火改血光 + 标记用的原版数值：持续攻击单个敌人的 DPS（原版硫磺火 / 阿撒泻勒 / 天顶剑本身），
    -- 原版硫磺标记让硫磺火伤害提高多少，以及被标记的敌人死亡时会不会爆炸、传染标记
    local function sustained(label, character, items, frames, zenith)
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. character)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        for _, item in ipairs(items) do
            p:AddCollectible(item)
        end
        wait(10)
        local home = p.Position
        local pos = home + Vector(100, 0)
        local dummy = spawnDummy(pos)
        local st = zenith and api.getState(p)
        damageLog = {}
        simNative = not zenith and Vector(1, 0) or nil
        -- 蓄力武器：蓄满（蓄力值不再增加）就松手 1 帧，模拟玩家最优节奏
        local lastCharge, releases = -1, 0
        for _ = 1, frames do
            p.Position, p.Velocity = home, Vector.Zero
            p:SetMinDamageCooldown(60)
            dummy.Position, dummy.Velocity = pos, Vector.Zero
            if not zenith then
                local ok, c = pcall(function() return p:GetWeapon(1):GetCharge() end)
                c = ok and c or 0
                if simNative and c > 0 and c == lastCharge then
                    simNative = nil
                    releases = releases + 1
                else
                    simNative = Vector(1, 0)
                end
                lastCharge = c
            end
            if st then
                local target = st.crosshair
                if not (target and target:Exists()) then
                    target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                    st.crosshair = target
                end
                target.Position, target.Velocity = pos, Vector.Zero
            end
            wait(1)
        end
        simNative = nil
        local total = 0
        for _, d in ipairs(damageTo(dummy)) do
            total = total + d.amount
        end
        damageLog = nil
        log(string.format("PROBE DPS %s：伤害 %.2f，MaxFireDelay %.2f，%d 帧总伤害 %.1f，每帧 %.3f = 角色伤害 × %.4f / 帧（每秒 %.2f 倍），松手 %d 次",
            label, p.Damage, p.MaxFireDelay, frames, total, total / frames, total / frames / p.Damage, total / frames / p.Damage * 30, releases))
        dummy:Remove()
    end
    local probeOnlyVanilla = false
    probeB[10] = { id = 10, name = "硫磺火 DPS 与硫磺标记实测", fn = function()
        local I = CollectibleType
        sustained("原版硫磺火", PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_BRIMSTONE }, 600, false)
        sustained("原版阿撒泻勒", PlayerType.PLAYER_AZAZEL, {}, 600, false)
        if probeOnlyVanilla then
            return
        end
        sustained("天顶剑（以撒）", PlayerType.PLAYER_ISAAC, { api.item }, 600, true)
        sustained("天顶剑（阿撒泻勒）", PlayerType.PLAYER_AZAZEL, { api.item }, 600, true)

        -- 硫磺标记的加伤：同一角色的硫磺火打普通假人 / 已标记假人，比较每次伤害
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(I.COLLECTIBLE_BRIMSTONE)
        wait(10)
        local home = p.Position
        for _, marked in ipairs({ false, true }) do
            local pos = home + Vector(100, 0)
            local dummy = spawnDummy(pos)
            local okMark, err = true, nil
            if marked then
                okMark, err = pcall(function() dummy:AddBrimstoneMark(EntityRef(p), 600) end)
            end
            damageLog = {}
            simNative = Vector(1, 0)
            local countdown = -1
            for f = 1, 150 do
                p.Position, p.Velocity = home, Vector.Zero
                dummy.Position, dummy.Velocity = pos, Vector.Zero
                if f == 1 then
                    local ok, c = pcall(function() return dummy:GetBrimstoneMarkCountdown() end)
                    countdown = ok and c or -2
                end
                wait(1)
            end
            simNative = nil
            local amounts = {}
            for _, d in ipairs(damageTo(dummy)) do
                local k = string.format("%.2f", d.amount)
                amounts[k] = (amounts[k] or 0) + 1
            end
            local parts = {}
            for k, v in pairs(amounts) do
                parts[#parts + 1] = k .. "×" .. v
            end
            damageLog = nil
            log(string.format("PROBE 硫磺标记（%s）：上标记 %s %s，标记计时 %d，FLAG_BRIMSTONE_MARKED=%s；伤害 %.2f，每次伤害 %s",
                marked and "已标记" or "未标记", tostring(okMark), tostring(err or ""), countdown,
                tostring(dummy:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED)), p.Damage, table.concat(parts, " ")))
            dummy:Remove()
            wait(40)
        end

        -- 被标记的敌人死亡：周围敌人会不会受伤、被标记，生成了什么
        clearRoom()
        local center0 = home + Vector(120, 0)
        local victims = {}
        for k = 0, 4 do
            local e = Isaac.Spawn(ENTITY_GAPER, 0, 0, center0 + Vector(math.cos(k * 1.3) * 45, math.sin(k * 1.3) * 45), Vector.Zero, nil):ToNPC()
            e.MaxHitPoints, e.HitPoints = 500, 500
            victims[#victims + 1] = e
        end
        local doomed = victims[1]
        doomed.HitPoints = 5
        pcall(function() doomed:AddBrimstoneMark(EntityRef(p), 600) end)
        wait(5)
        local seen = {}
        for _, e in ipairs(Isaac.GetRoomEntities()) do
            seen[GetPtrHash(e)] = true
        end
        damageLog = {}
        doomed:TakeDamage(50, 0, EntityRef(p), 0)
        local spawned = {}
        for _ = 1, 90 do
            for _, v in ipairs(victims) do
                if v:Exists() then
                    v.Velocity = Vector.Zero
                end
            end
            for _, e in ipairs(Isaac.GetRoomEntities()) do
                local key = GetPtrHash(e)
                if not seen[key] then
                    seen[key] = true
                    local k = e.Type .. "." .. e.Variant
                    spawned[k] = (spawned[k] or 0) + 1
                end
            end
            wait(1)
        end
        local others = {}
        for i = 2, #victims do
            local v = victims[i]
            local ok, c = pcall(function() return v:GetBrimstoneMarkCountdown() end)
            local dmg = 0
            for _, d in ipairs(damageTo(v)) do
                dmg = dmg + d.amount
            end
            others[#others + 1] = string.format("敌人%d[标记计时 %s，受伤 %.1f，存活 %s]", i, ok and tostring(c) or "×", dmg, tostring(v:Exists() and not v:IsDead()))
        end
        damageLog = nil
        local sp = {}
        for k, v in pairs(spawned) do
            sp[#sp + 1] = k .. "×" .. v
        end
        log("PROBE 标记敌人死亡：" .. table.concat(others, "；") .. "；生成 " .. table.concat(sp, " "))
    end }
    probeB[11] = { id = 11, name = "原版硫磺火 DPS、标记加伤与硫磺火击杀实测", fn = function()
        probeOnlyVanilla = true
        probeB[10].fn()
        probeOnlyVanilla = false
        local I = CollectibleType
        -- 标记加伤：蓄满松手的硫磺火打未标记 / 已标记假人
        for _, marked in ipairs({ false, true }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(I.COLLECTIBLE_BRIMSTONE)
            wait(10)
            local home = p.Position
            local pos = home + Vector(100, 0)
            local dummy = spawnDummy(pos)
            damageLog = {}
            local lastCharge = -1
            for _ = 1, 240 do
                p.Position, p.Velocity = home, Vector.Zero
                dummy.Position, dummy.Velocity = pos, Vector.Zero
                if marked then
                    dummy:AddBrimstoneMark(EntityRef(p), 300)
                end
                local c = p:GetWeapon(1):GetCharge()
                if simNative and c > 0 and c == lastCharge then
                    simNative = nil
                else
                    simNative = Vector(1, 0)
                end
                lastCharge = c
                wait(1)
            end
            simNative = nil
            local amounts = {}
            for _, d in ipairs(damageTo(dummy)) do
                local k = string.format("%.2f", d.amount)
                amounts[k] = (amounts[k] or 0) + 1
            end
            local parts = {}
            for k, v in pairs(amounts) do
                parts[#parts + 1] = k .. "×" .. v
            end
            damageLog = nil
            log(string.format("PROBE 硫磺标记加伤（%s）：伤害 %.2f，每次伤害 %s", marked and "已标记" or "未标记", p.Damage, table.concat(parts, " ")))
            dummy:Remove()
        end
        -- 被标记的敌人被硫磺火打死：周围敌人会不会受伤、被标记
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(I.COLLECTIBLE_BRIMSTONE)
        wait(10)
        local home = p.Position
        local center0 = home + Vector(130, 0)
        local victims = {}
        for k = 0, 4 do
            local offset = k == 0 and Vector.Zero or Vector(math.cos(k * 1.57) * 50, math.sin(k * 1.57) * 50 + 0)
            local e = Isaac.Spawn(ENTITY_GAPER, 0, 0, center0 + offset, Vector.Zero, nil):ToNPC()
            e.MaxHitPoints, e.HitPoints = 500, 500
            victims[#victims + 1] = e
        end
        local doomed = victims[1]
        doomed.HitPoints = 3
        local seen = {}
        for _, e in ipairs(Isaac.GetRoomEntities()) do
            seen[GetPtrHash(e)] = true
        end
        local spawned, lastCharge = {}, -1
        damageLog = {}
        -- 只让硫磺火打到中间那个（其余敌人放在激光两侧，激光朝右）
        for _ = 1, 150 do
            p.Position, p.Velocity = home, Vector.Zero
            for i, v in ipairs(victims) do
                if v:Exists() then
                    v.Velocity = Vector.Zero
                    if i == 1 then
                        v:AddBrimstoneMark(EntityRef(p), 300)
                    end
                end
            end
            local c = p:GetWeapon(1):GetCharge()
            if doomed:Exists() and not doomed:IsDead() then
                if simNative and c > 0 and c == lastCharge then
                    simNative = nil
                else
                    simNative = Vector(1, 0)
                end
            else
                simNative = nil
            end
            lastCharge = c
            for _, e in ipairs(Isaac.GetRoomEntities()) do
                local key = GetPtrHash(e)
                if not seen[key] then
                    seen[key] = true
                    local k = e.Type .. "." .. e.Variant
                    spawned[k] = (spawned[k] or 0) + 1
                end
            end
            wait(1)
        end
        simNative = nil
        local others = {}
        for i = 2, #victims do
            local v = victims[i]
            local dmg = 0
            for _, d in ipairs(damageTo(v)) do
                dmg = dmg + d.amount
            end
            others[#others + 1] = string.format("敌人%d[标记计时 %d，受伤 %.1f]", i, v:GetBrimstoneMarkCountdown(), dmg)
        end
        damageLog = nil
        local sp = {}
        for k, v in pairs(spawned) do
            sp[#sp + 1] = k .. "×" .. v
        end
        log("PROBE 标记敌人被硫磺火打死：中间敌人死亡=" .. tostring(not doomed:Exists() or doomed:IsDead()) .. "；" .. table.concat(others, "；")
            .. "；生成 " .. table.concat(sp, " "))
    end }
    -- 硫磺火固定节奏（按住 hold 帧、松开 release 帧）持续攻击的 DPS；标记加伤在两种伤害下的数值；
    -- 被硫磺火打死的标记敌人：上方不同距离的敌人受到多少伤害、是否被传染标记、死亡时生成的激光
    local function restartBrim(damageBonus)
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(CollectibleType.COLLECTIBLE_BRIMSTONE)
        probeDamage = damageBonus or 0
        p:AddCacheFlags(CacheFlag.CACHE_DAMAGE)
        p:EvaluateItems()
        wait(10)
        return p
    end
    local function holdRelease(p, frames, hold, release, onFrame)
        local t = 0
        for f = 1, frames do
            simNative = (t < hold) and Vector(1, 0) or nil
            t = (t + 1) % (hold + release)
            if onFrame then
                onFrame(f)
            end
            wait(1)
        end
        simNative = nil
    end
    probeB[12] = { id = 12, name = "硫磺火节奏 DPS、标记公式与死亡传染实测", fn = function()
        for _, hold in ipairs({ 25, 35, 45, 60 }) do
            local p = restartBrim(0)
            local home = p.Position
            local pos = home + Vector(100, 0)
            local dummy = spawnDummy(pos)
            damageLog = {}
            holdRelease(p, 600, hold, 25, function()
                p.Position, p.Velocity = home, Vector.Zero
                dummy.Position, dummy.Velocity = pos, Vector.Zero
            end)
            local total, n = 0, 0
            for _, d in ipairs(damageTo(dummy)) do
                total, n = total + d.amount, n + 1
            end
            damageLog = nil
            log(string.format("PROBE 硫磺火节奏 按住 %d 松开 25：600 帧命中 %d 次，总伤害 %.1f，每秒 %.2f 倍角色伤害", hold, n, total, total / 600 * 30 / p.Damage))
            dummy:Remove()
        end
        for _, bonus in ipairs({ 0, 3.5, 10 }) do
            local p = restartBrim(bonus)
            local home = p.Position
            local pos = home + Vector(100, 0)
            local dummy = spawnDummy(pos)
            damageLog = {}
            holdRelease(p, 200, 60, 40, function()
                p.Position, p.Velocity = home, Vector.Zero
                dummy.Position, dummy.Velocity = pos, Vector.Zero
                dummy:AddBrimstoneMark(EntityRef(p), 300)
            end)
            local amounts = {}
            for _, d in ipairs(damageTo(dummy)) do
                local k = string.format("%.2f", d.amount)
                amounts[k] = (amounts[k] or 0) + 1
            end
            local parts = {}
            for k, v in pairs(amounts) do
                parts[#parts + 1] = k .. "×" .. v
            end
            damageLog = nil
            log(string.format("PROBE 标记加伤：角色伤害 %.2f，已标记假人每次受伤 %s", p.Damage, table.concat(parts, " ")))
            dummy:Remove()
        end
        -- 死亡传染：中间敌人被标记、只剩 3 血，被朝右的硫磺火打死；上方 40/80/120/160 处各一个敌人（不在激光上）
        local p = restartBrim(0)
        probeDamage = 0
        local home = p.Position
        local center0 = home + Vector(130, 0)
        local doomed = Isaac.Spawn(ENTITY_GAPER, 0, 0, center0, Vector.Zero, nil):ToNPC()
        doomed.MaxHitPoints, doomed.HitPoints = 500, 3
        local around = {}
        for _, dist in ipairs({ 40, 80, 120, 160 }) do
            local e = Isaac.Spawn(ENTITY_GAPER, 0, 0, center0 + Vector(0, -dist), Vector.Zero, nil):ToNPC()
            e.MaxHitPoints, e.HitPoints = 500, 500
            around[#around + 1] = { e = e, dist = dist, pos = e.Position }
        end
        local seen = {}
        for _, e in ipairs(Isaac.GetRoomEntities()) do
            seen[GetPtrHash(e)] = true
        end
        local lasers, deathFrame, marksAtDeath = {}, nil, nil
        damageLog = {}
        holdRelease(p, 200, 60, 140, function(f)
            p.Position, p.Velocity = home, Vector.Zero
            if doomed:Exists() and not doomed:IsDead() then
                doomed.Position, doomed.Velocity = center0, Vector.Zero
                doomed:AddBrimstoneMark(EntityRef(p), 300)
            elseif not deathFrame then
                deathFrame = f
            end
            for _, a in ipairs(around) do
                if a.e:Exists() then
                    a.e.Position, a.e.Velocity = a.pos, Vector.Zero
                end
            end
            if deathFrame and f == deathFrame + 3 then
                local m = {}
                for _, a in ipairs(around) do
                    m[#m + 1] = a.dist .. ":" .. a.e:GetBrimstoneMarkCountdown()
                end
                marksAtDeath = table.concat(m, ",")
            end
            for _, e in ipairs(Isaac.GetRoomEntities()) do
                local key = GetPtrHash(e)
                if not seen[key] then
                    seen[key] = true
                    local laser = e:ToLaser()
                    if laser then
                        lasers[#lasers + 1] = string.format("第%d帧 变体%d 位置偏移(%.0f,%.0f) 角度%.0f timeout%d 长度%.0f 伤害%.2f 父=%s", f, e.Variant,
                            e.Position.X - center0.X, e.Position.Y - center0.Y, laser.AngleDegrees, laser.Timeout, laser.MaxDistance,
                            laser.CollisionDamage, tostring(laser.Parent and laser.Parent.Type))
                    end
                end
            end
        end)
        local res = {}
        for _, a in ipairs(around) do
            local dmg, hits = 0, {}
            for _, d in ipairs(damageTo(a.e)) do
                dmg = dmg + d.amount
                hits[#hits + 1] = string.format("%.2f", d.amount)
            end
            res[#res + 1] = string.format("距离%d[受伤 %s，标记计时 %d]", a.dist, table.concat(hits, "+"), a.e:GetBrimstoneMarkCountdown())
        end
        damageLog = nil
        log(string.format("PROBE 死亡传染：死亡帧 %s，死亡 3 帧后标记计时 %s；%s", tostring(deathFrame), tostring(marksAtDeath), table.concat(res, "；")))
        log("PROBE 死亡传染期间生成的激光：" .. table.concat(lasers, " | "))
    end }
    -- 英灵剑：原版剑（刀实体）和剑气泪弹的精灵文件、动画、朝向，近处挥剑 / 远处剑气对假人的伤害；满血与不满血对比
    probeB[13] = { id = 13, name = "英灵剑实测", fn = function()
        for _, fullHealth in ipairs({ true, false }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(CollectibleType.COLLECTIBLE_SPIRIT_SWORD)
            if not fullHealth then
                p:AddHearts(-2)
            end
            wait(10)
            local home = p.Position
            local nearPos, farPos = home + Vector(45, 0), home + Vector(220, 0)
            local nearD, farD = spawnDummy(nearPos), spawnDummy(farPos)
            local seen, info = {}, {}
            local function describe(e, tag)
                local s = e:GetSprite()
                local parts = { tag .. " " .. e.Type .. "." .. e.Variant .. "." .. e.SubType }
                local function try(name, fn)
                    local ok, v = pcall(fn)
                    parts[#parts + 1] = name .. "=" .. (ok and tostring(v) or "×")
                end
                try("文件", function() return s:GetFilename() end)
                try("动画", function() return s:GetAnimation() end)
                try("精灵旋转", function() return s.Rotation end)
                try("实体旋转", function() return e:ToKnife() and e:ToKnife().Rotation or (e:ToTear() and e.Velocity:GetAngleDegrees()) end)
                try("帧尺寸", function()
                    local f = s:GetCurrentAnimationData():GetLayer(0):GetFrame(s:GetFrame())
                    return string.format("%.0fx%.0f 中心(%.0f,%.0f)", f:GetWidth(), f:GetHeight(), f:GetPivot().X, f:GetPivot().Y)
                end)
                try("伤害", function() return e.CollisionDamage end)
                try("速度", function() return e.Velocity end)
                info[#info + 1] = table.concat(parts, "，")
            end
            damageLog = {}
            for f = 1, 120 do
                -- 每 30 帧轻点一次射击键（挥剑），朝右
                simNative = (f % 30 < 3) and Vector(1, 0) or nil
                p.Position, p.Velocity = home, Vector.Zero
                p:SetMinDamageCooldown(60)
                nearD.Position, nearD.Velocity = nearPos, Vector.Zero
                farD.Position, farD.Velocity = farPos, Vector.Zero
                for _, e in ipairs(Isaac.GetRoomEntities()) do
                    local key = GetPtrHash(e)
                    if (e.Type == EntityType.ENTITY_KNIFE or e.Type == EntityType.ENTITY_TEAR) and not seen[key] then
                        seen[key] = true
                        describe(e, "第" .. f .. "帧")
                    end
                    if e.Type == EntityType.ENTITY_KNIFE and f == 2 then
                        describe(e, "挥剑中")
                    end
                end
                wait(1)
            end
            simNative = nil
            local function amounts(d)
                local t = {}
                for _, h in ipairs(damageTo(d)) do
                    t[#t + 1] = string.format("%.2f", h.amount)
                end
                return table.concat(t, ",")
            end
            log(string.format("PROBE 英灵剑（%s，红心 %d / 容器 %d，有效上限 %d，魂心 %d）：伤害 %.2f；近处每次伤害 %s；远处每次伤害 %s",
                fullHealth and "满血" or "不满血", p:GetHearts(), p:GetMaxHearts(), p:GetEffectiveMaxHearts(), p:GetSoulHearts(), p.Damage,
                amounts(nearD), amounts(farD)))
            for _, line in ipairs(info) do
                log("PROBE   " .. line)
            end
            damageLog = nil
            nearD:Remove()
            farD:Remove()
        end
    end }
    -- 英灵剑补充：剑气泪弹在两种角色伤害下的伤害（推公式）、蓄力旋转斩的伤害，以及两个精灵文件里的动画和帧
    local probeSkipSpiritDamage = true -- 伤害公式已实测（见 config.lua），只看动画时设为 true
    probeB[14] = { id = 14, name = "英灵剑公式与动画实测", fn = function()
        for _, cfg in ipairs(probeSkipSpiritDamage and {} or { { 0, "tap" }, { 3.5, "tap" }, { 0, "spin" }, { 3.5, "spin" } }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(CollectibleType.COLLECTIBLE_SPIRIT_SWORD)
            probeDamage = cfg[1]
            p:AddCacheFlags(CacheFlag.CACHE_DAMAGE)
            p:EvaluateItems()
            wait(10)
            local home = p.Position
            local nearPos, farPos = home + Vector(45, 0), home + Vector(220, 0)
            local nearD, farD = spawnDummy(nearPos), spawnDummy(farPos)
            damageLog = {}
            for f = 1, 150 do
                if cfg[2] == "tap" then
                    simNative = (f % 30 < 3) and Vector(1, 0) or nil
                else
                    simNative = (f < 90) and Vector(1, 0) or nil -- 按住蓄满再松手
                end
                p.Position, p.Velocity = home, Vector.Zero
                p:SetMinDamageCooldown(60)
                nearD.Position, nearD.Velocity = nearPos, Vector.Zero
                farD.Position, farD.Velocity = farPos, Vector.Zero
                wait(1)
            end
            simNative = nil
            local function amounts(d)
                local t = {}
                for _, h in ipairs(damageTo(d)) do
                    t[#t + 1] = string.format("%.2f", h.amount)
                end
                return table.concat(t, ",")
            end
            local tears = {}
            log(string.format("PROBE 英灵剑 %s：角色伤害 %.2f；近处 %s；远处 %s", cfg[2] == "tap" and "轻点挥剑" or "蓄力旋转斩", p.Damage, amounts(nearD), amounts(farD)))
            damageLog = nil
            nearD:Remove()
            farD:Remove()
        end
        probeDamage = 0
        for _, file in ipairs({ "gfx/008.010_Spirit Sword.anm2", "gfx/002.047_sword tear.anm2" }) do
            local s = Sprite()
            s:Load(file, true)
            local parts = {}
            local ok, err = pcall(function()
                for _, anim in ipairs(s:GetAllAnimationData()) do
                    local layer = anim:GetLayer(0)
                    local frames = {}
                    for i = 0, math.min(anim:GetLength(), 12) - 1 do
                        local f = layer:GetFrame(i)
                        if f then
                            frames[#frames + 1] = string.format("%d:旋转%.0f 偏移(%.0f,%.0f) 中心(%.0f,%.0f) %.0fx%.0f 可见%s", i, f:GetRotation(),
                                f:GetPos().X, f:GetPos().Y, f:GetPivot().X, f:GetPivot().Y, f:GetWidth(), f:GetHeight(), tostring(f:IsVisible()))
                        end
                    end
                    parts[#parts + 1] = string.format("[%s 共 %d 帧 层数 %d] %s", anim:GetName(), anim:GetLength(), #anim:GetAllLayers(), table.concat(frames, "; "))
                end
            end)
            log("PROBE 动画 " .. file .. "：" .. (ok and table.concat(parts, " || ") or ("读取失败 " .. tostring(err))))
        end
    end }
    -- DPS 对比（以撒，持续攻击单个固定假人 600 帧）：原版英灵剑（轻点挥剑 / 蓄力旋转斩，取几种节奏）、单独天顶剑、
    -- 天顶剑 + 英灵剑（满血 = 剑气，不满血 = 英灵剑）。满血 / 不满血用 AddHearts(-2) 区分
    local function dpsRun(label, items, opts)
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        for _, item in ipairs(items) do
            p:AddCollectible(item)
        end
        if opts.hurt then
            p:AddHearts(-2)
        end
        wait(10)
        local home = p.Position
        local pos = home + Vector(opts.dist or 100, 0)
        local dummy = spawnDummy(pos)
        local st = opts.zenith and api.getState(p)
        local frames = 600
        damageLog = {}
        local t = 0
        for _ = 1, frames do
            p.Position, p.Velocity = home, Vector.Zero
            p:SetMinDamageCooldown(60)
            dummy.Position, dummy.Velocity = pos, Vector.Zero
            if st then
                local target = st.crosshair
                if not (target and target:Exists()) then
                    target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                    st.crosshair = target
                end
                target.Position, target.Velocity = pos, Vector.Zero
            else
                simNative = (t < opts.hold) and Vector(1, 0) or nil
                t = (t + 1) % (opts.hold + opts.release)
            end
            if opts.onFrame then
                opts.onFrame(p, pos)
            end
            wait(1)
        end
        simNative = nil
        local total, hist = 0, {}
        for _, d in ipairs(damageTo(dummy)) do
            total = total + d.amount
            local k = string.format("%.2f", d.amount)
            hist[k] = (hist[k] or 0) + 1
        end
        local parts = {}
        for k, v in pairs(hist) do
            parts[#parts + 1] = k .. "×" .. v
        end
        table.sort(parts)
        damageLog = nil
        log(string.format("PROBE DPS对比 %s：红心 %d/%d，角色伤害 %.2f，MaxFireDelay %.2f，600 帧总伤害 %.1f，每秒 %.2f 点 = 角色伤害 × %.2f / 秒；每次伤害 %s",
            label, p:GetHearts(), p:GetEffectiveMaxHearts(), p.Damage, p.MaxFireDelay, total, total / frames * 30, total / frames * 30 / p.Damage,
            #parts <= 12 and table.concat(parts, " ") or (#parts .. " 种")))
        dummy:Remove()
    end
    probeB[15] = { id = 15, name = "英灵剑与天顶剑 DPS 对比", fn = function()
        local SS = CollectibleType.COLLECTIBLE_SPIRIT_SWORD
        for _, hurt in ipairs({ false, true }) do
            local tag = hurt and "不满血" or "满血"
            for _, rel in ipairs({ 3, 6, 10 }) do
                dpsRun(string.format("原版英灵剑（%s，轻点挥剑：按 2 帧松 %d 帧）", tag, rel), { SS }, { hold = 2, release = rel, dist = 45, hurt = hurt })
            end
            for _, hold in ipairs({ 40, 60 }) do
                dpsRun(string.format("原版英灵剑（%s，蓄力旋转斩：按 %d 帧松 10 帧）", tag, hold), { SS }, { hold = hold, release = 10, dist = 45, hurt = hurt })
            end
        end
        dpsRun("单独天顶剑", { api.item }, { zenith = true })
        dpsRun("天顶剑 + 英灵剑（满血，剑气 5.5 + 400%）", { api.item, SS }, { zenith = true })
        dpsRun("天顶剑 + 英灵剑（不满血，英灵剑 3.5 + 300%）", { api.item, SS }, { zenith = true, hurt = true })
    end }
    -- 原版英灵剑轻点挥剑的上限：更快的节奏
    probeB[16] = { id = 16, name = "原版英灵剑最快节奏", fn = function()
        local SS = CollectibleType.COLLECTIBLE_SPIRIT_SWORD
        for _, hurt in ipairs({ false, true }) do
            for _, pat in ipairs({ { 1, 1 }, { 1, 2 }, { 2, 2 } }) do
                dpsRun(string.format("原版英灵剑（%s，轻点挥剑：按 %d 帧松 %d 帧）", hurt and "不满血" or "满血", pat[1], pat[2]), { SS },
                    { hold = pat[1], release = pat[2], dist = 45, hurt = hurt })
            end
        end
    end }
    -- 第二批联动用的原版数值：科技 2（持续激光 + 眼泪）、科技 X（蓄力激光环，几种节奏）、卢多维科（大眼泪一直压在假人上）
    probeB[17] = { id = 17, name = "科技 2 / 科技 X / 卢多维科原版数值", fn = function()
        local I = CollectibleType
        dpsRun("原版科技 2（一直按住）", { I.COLLECTIBLE_TECHNOLOGY_2 }, { hold = 600, release = 1 })
        for _, hold in ipairs({ 20, 30, 45 }) do
            dpsRun(string.format("原版科技 X（按 %d 帧松 10 帧）", hold), { I.COLLECTIBLE_TECH_X }, { hold = hold, release = 10 })
        end
        dpsRun("原版卢多维科（大眼泪压在假人上）", { I.COLLECTIBLE_LUDOVICO_TECHNIQUE }, { hold = 600, release = 1, onFrame = function(p, pos)
            for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                local tear = t:ToTear()
                if tear and tear:HasTearFlags(TearFlags.TEAR_LUDOVICO) then
                    tear.Position, tear.Velocity = pos, Vector.Zero
                end
            end
        end })
        dpsRun("原版以撒（对照）", {}, { hold = 600, release = 1 })
    end }
    -- 背刺：同一只走向角色的敌人，从背后 / 正面射眼泪的伤害；铅笔：按住射击键时每帧出现的眼泪数（找齐射）
    probeB[18] = { id = 18, name = "背刺与铅笔原版数值", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(CollectibleType.COLLECTIBLE_BACKSTABBER)
        wait(10)
        local home = p.Position
        local e = Isaac.Spawn(ENTITY_GAPER, 0, 0, home + Vector(200, 0), Vector.Zero, nil):ToNPC()
        e.MaxHitPoints, e.HitPoints = 100000, 100000
        for _, side in ipairs({ "背后", "正面" }) do
            damageLog = {}
            for f = 1, 120 do
                p.Position, p.Velocity = home, Vector.Zero
                p:SetMinDamageCooldown(60)
                if e.Position:Distance(home) < 80 then
                    e.Position = home + Vector(200, 0)
                end
                if f % 15 == 0 then
                    local dir = (home - e.Position):Normalized() -- 敌人朝角色走，背后 = 敌人远离角色的那一侧
                    local from = side == "背后" and (e.Position - dir * 40) or (e.Position + dir * 40)
                    local vel = side == "背后" and dir * 10 or dir * -10
                    p:FireTear(from, vel, false, true, false, p, 1)
                end
                wait(1)
            end
            local parts = {}
            for _, d in ipairs(damageTo(e)) do
                parts[#parts + 1] = string.format("%.2f", d.amount)
            end
            damageLog = nil
            log(string.format("PROBE 背刺（%s射入）：角色伤害 %.2f，每次伤害 %s", side, p.Damage, table.concat(parts, ",")))
        end
        e:Remove()
        -- 铅笔
        clearRoom()
        p:AddCollectible(CollectibleType.COLLECTIBLE_LEAD_PENCIL)
        wait(5)
        local seen, perFrame, total = {}, {}, 0
        simNative = Vector(1, 0)
        for f = 1, 360 do
            p.Position, p.Velocity = home, Vector.Zero
            local n = 0
            for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                if not seen[GetPtrHash(t)] then
                    seen[GetPtrHash(t)] = true
                    n = n + 1
                end
            end
            if n > 0 then
                total = total + n
                perFrame[#perFrame + 1] = string.format("%d:%d", f, n)
            end
            wait(1)
        end
        simNative = nil
        log("PROBE 铅笔：360 帧共 " .. total .. " 颗眼泪；每帧新眼泪（帧:数量）" .. table.concat(perFrame, " "))
    end }
    -- 鬼椒 / 鸟眼椒：按住射击键时眼泪数和火焰数（概率）、火焰实体类型和大小（两种伤害、两种幸运对比）
    probeB[19] = { id = 19, name = "鬼椒与鸟眼椒原版数值", fn = function()
        for _, cfg in ipairs({
            { "鬼椒", CollectibleType.COLLECTIBLE_GHOST_PEPPER, 0, 0 },
            { "鬼椒（伤害 +10）", CollectibleType.COLLECTIBLE_GHOST_PEPPER, 10, 0 },
            { "鬼椒（幸运 10）", CollectibleType.COLLECTIBLE_GHOST_PEPPER, 0, 10 },
            { "鸟眼椒", CollectibleType.COLLECTIBLE_BIRDS_EYE, 0, 0 },
            { "鸟眼椒（伤害 +10）", CollectibleType.COLLECTIBLE_BIRDS_EYE, 10, 0 },
            { "鸟眼椒（幸运 10）", CollectibleType.COLLECTIBLE_BIRDS_EYE, 0, 10 },
        }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(cfg[2])
            probeDamage, probeLuck = cfg[3], cfg[4]
            p:AddCacheFlags(CacheFlag.CACHE_DAMAGE | CacheFlag.CACHE_LUCK)
            p:EvaluateItems()
            wait(5)
            local home = p.Position
            local seen, tears, flames, info = {}, 0, {}, {}
            simNative = Vector(1, 0)
            for _ = 1, 900 do
                p.Position, p.Velocity = home, Vector.Zero
                for _, e in ipairs(Isaac.GetRoomEntities()) do
                    local key = GetPtrHash(e)
                    if not seen[key] then
                        seen[key] = true
                        if e.Type == EntityType.ENTITY_TEAR then
                            tears = tears + 1
                        elseif e.Type == EntityType.ENTITY_EFFECT and e.Variant ~= api.renderer and e.Variant ~= api.crosshair
                            and e.Variant ~= EffectVariant.TEAR_POOF_A and e.Variant ~= EffectVariant.TEAR_POOF_B and e.Variant ~= 12 and e.Variant ~= 15 then
                            local k = e.Variant .. "." .. e.SubType
                            flames[k] = (flames[k] or 0) + 1
                            if not info[k] then
                                local eff = e:ToEffect()
                                info[k] = string.format("%s 缩放(%.2f,%.2f) 碰撞伤害 %.2f 速度 %.1f 生命 %d 生成者 %s", k, e.SpriteScale.X, e.SpriteScale.Y,
                                    e.CollisionDamage, e.Velocity:Length(), eff and eff.Timeout or -1, tostring(e.SpawnerType))
                            end
                        end
                    end
                end
                wait(1)
            end
            simNative = nil
            local parts, infos = {}, {}
            for k, v in pairs(flames) do
                parts[#parts + 1] = k .. "×" .. v
                infos[#infos + 1] = info[k]
            end
            log(string.format("PROBE %s：伤害 %.2f 幸运 %.1f，眼泪 %d，特效 %s；%s", cfg[1], p.Damage, p.Luck, tears, table.concat(parts, " "), table.concat(infos, " | ")))
            probeDamage, probeLuck = 0, 0
        end
    end }
    -- 清单里需要原版数值的道具：按住射击键 900 帧，统计每次射击（同一帧出现的眼泪算一次）出几颗眼泪、朝哪；
    -- 眼球突出：不同距离的假人被一颗眼泪打中的伤害；神性：眼泪从假人旁边擦过（不直接撞上）时光环的伤害
    probeB[20] = { id = 20, name = "清单道具原版数值", fn = function()
        local I = CollectibleType
        local function shotPattern(label, item, luck)
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(item)
            probeLuck = luck or 0
            p:AddCacheFlags(CacheFlag.CACHE_LUCK)
            p:EvaluateItems()
            wait(5)
            local home = p.Position
            local seen, shots, hist, dirs = {}, 0, {}, {}
            simNative = Vector(1, 0)
            for _ = 1, 900 do
                p.Position, p.Velocity = home, Vector.Zero
                local n, angles = 0, {}
                for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                    if not seen[GetPtrHash(t)] then
                        seen[GetPtrHash(t)] = true
                        n = n + 1
                        angles[#angles + 1] = string.format("%.0f", t.Velocity:GetAngleDegrees())
                    end
                end
                if n > 0 then
                    shots = shots + 1
                    hist[n] = (hist[n] or 0) + 1
                    if n > 1 and #dirs < 6 then
                        dirs[#dirs + 1] = "[" .. table.concat(angles, ",") .. "]"
                    end
                end
                wait(1)
            end
            simNative = nil
            probeLuck = 0
            local parts = {}
            for k, v in pairs(hist) do
                parts[#parts + 1] = k .. "颗×" .. v
            end
            table.sort(parts)
            log(string.format("PROBE %s（幸运 %.0f）：射击 %d 次，每次眼泪数 %s；多颗时的角度 %s", label, p.Luck, shots, table.concat(parts, " "), table.concat(dirs, " ")))
        end
        shotPattern("巫师帽", I.COLLECTIBLE_THE_WIZ)
        shotPattern("洛基之角", I.COLLECTIBLE_LOKIS_HORNS, 0)
        shotPattern("洛基之角", I.COLLECTIBLE_LOKIS_HORNS, 10)
        shotPattern("妈妈的眼", I.COLLECTIBLE_MOMS_EYE, 0)
        shotPattern("妈妈的眼", I.COLLECTIBLE_MOMS_EYE, 10)
        shotPattern("眼疮", I.COLLECTIBLE_EYE_SORE, 0)
        shotPattern("肾结石", I.COLLECTIBLE_KIDNEY_STONE, 0)

        -- 眼球突出：假人放在不同距离，一次射一颗眼泪
        for _, dist in ipairs({ 40, 100, 160, 220 }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(I.COLLECTIBLE_PROPTOSIS)
            wait(5)
            local home = p.Position
            local dummy = spawnDummy(home + Vector(dist, 0))
            damageLog = {}
            simNative = Vector(1, 0)
            for f = 1, 60 do
                p.Position, p.Velocity = home, Vector.Zero
                dummy.Position, dummy.Velocity = home + Vector(dist, 0), Vector.Zero
                if f == 3 then
                    simNative = nil
                end
                wait(1)
            end
            local hits = {}
            for _, d in ipairs(damageTo(dummy)) do
                hits[#hits + 1] = string.format("%.2f", d.amount)
            end
            damageLog = nil
            log(string.format("PROBE 眼球突出：距离 %d，角色伤害 %.2f，命中 %s", dist, p.Damage, table.concat(hits, ",")))
            dummy:Remove()
        end

        -- 神性：眼泪从假人上下 offset 处横穿，不直接撞上
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(I.COLLECTIBLE_GODHEAD)
        wait(5)
        local home = p.Position
        for _, off in ipairs({ 25, 40, 55, 70 }) do
            local pos = home + Vector(150, 0)
            local dummy = spawnDummy(pos)
            damageLog = {}
            for f = 1, 80 do
                p.Position, p.Velocity = home, Vector.Zero
                dummy.Position, dummy.Velocity = pos, Vector.Zero
                if f == 2 then
                    p:FireTear(home + Vector(0, off), Vector(8, 0), false, true, false, p, 1)
                end
                wait(1)
            end
            local hits = {}
            for _, d in ipairs(damageTo(dummy)) do
                hits[#hits + 1] = string.format("%.2f", d.amount)
            end
            damageLog = nil
            log(string.format("PROBE 神性：眼泪离假人 %d 擦过，角色伤害 %.2f，假人受伤 %s", off, p.Damage, table.concat(hits, ",")))
            dummy:Remove()
        end
    end }
    -- 肾结石：之前按住射击键一颗眼泪都不发。换几种节奏，同时记录射击冷却、武器类型和蓄力值，找出原因
    probeB[21] = { id = 21, name = "肾结石原版排查", fn = function()
        local patterns = { { "一直按住", 900, 0 }, { "按 2 松 8", 2, 8 }, { "按 60 松 30", 60, 30 } }
        for _, pat in ipairs(patterns) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(CollectibleType.COLLECTIBLE_KIDNEY_STONE)
            wait(10)
            local home = p.Position
            local seen, shots, bursts, samples, t = {}, 0, {}, {}, 0
            for f = 1, 900 do
                simNative = (t < pat[2]) and Vector(1, 0) or nil
                t = (t + 1) % (pat[2] + pat[3])
                p.Position, p.Velocity = home, Vector.Zero
                local n = 0
                for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                    if not seen[GetPtrHash(e)] then
                        seen[GetPtrHash(e)] = true
                        n = n + 1
                    end
                end
                if n > 0 then
                    shots = shots + 1
                    if n > 1 then
                        bursts[#bursts + 1] = f .. ":" .. n
                    end
                end
                if f % 150 == 0 then
                    local ok, info = pcall(function()
                        local w = p:GetWeapon(1)
                        return string.format("帧%d FireDelay %.1f 武器类型 %s 蓄力 %s 能射击 %s 射击方向 %s", f, p.FireDelay,
                            tostring(w and w:GetWeaponType()), tostring(w and w:GetCharge()), tostring(p:CanShoot()), tostring(p:GetFireDirection()))
                    end)
                    samples[#samples + 1] = ok and info or ("帧" .. f .. " 读取失败 " .. tostring(info))
                end
                wait(1)
            end
            simNative = nil
            log(string.format("PROBE 肾结石（%s）：射击 %d 次，齐射 %s；%s", pat[1], shots, table.concat(bursts, " "), table.concat(samples, " | ")))
        end
    end }
    -- 史诗胎儿原版的导弹流程：逐帧记录瞄准标记 / 导弹特效的动画、帧、高度，正在播放的声音，假人受伤（只记录变化）
    probeB[22] = { id = 22, name = "史诗胎儿导弹流程", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(CollectibleType.COLLECTIBLE_EPIC_FETUS)
        wait(10)
        local home = p.Position
        local dummy = spawnDummy(home + Vector(120, 0))
        local sounds = {}
        for name, id in pairs(SoundEffect) do
            if name:find("BEEP") or name:find("ROCKET") or name:find("EXPLOSION") or name:find("MISSILE") or name:find("TARGET") then
                sounds[#sounds + 1] = { name, id }
            end
        end
        local last, lines = "", {}
        damageLog = {}
        simNative = Vector(1, 0)
        for f = 1, 160 do
            p.Position, p.Velocity = home, Vector.Zero
            local t = Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.TARGET)[1]
            if t then
                dummy.Position, dummy.Velocity = t.Position, Vector.Zero
            end
            local parts = {}
            for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT)) do
                if e.Variant == EffectVariant.TARGET or e.Variant == EffectVariant.ROCKET then
                    local s = e:GetSprite()
                    parts[#parts + 1] = string.format("%s[%s 帧%d 高度%.0f 计时%d]", e.Variant == EffectVariant.TARGET and "标记" or "导弹",
                        s:GetAnimation(), s:GetFrame(), e.PositionOffset.Y, e:ToEffect().Timeout)
                end
            end
            for _, sd in ipairs(sounds) do
                if SFXManager():IsPlaying(sd[2]) then
                    parts[#parts + 1] = "声音:" .. sd[1]
                end
            end
            local hits = #damageTo(dummy)
            parts[#parts + 1] = "命中" .. hits
            local now = table.concat(parts, " ")
            if now ~= last then
                lines[#lines + 1] = f .. ": " .. now
                last = now
            end
            if f == 100 then
                simNative = nil
            end
            wait(1)
        end
        simNative = nil
        damageLog = nil
        for i = 1, #lines, 6 do
            log("PROBE 史诗胎儿流程 " .. table.concat(lines, " || ", i, math.min(#lines, i + 5)))
        end
    end }
    -- 自己生成的标记 / 导弹给上原版计时后，游戏会不会自己闪烁、发出提示音、生成导弹、下落、爆炸
    probeB[23] = { id = 23, name = "史诗胎儿标记与导弹自动流程", fn = function()
        for _, cfg in ipairs({ { "只生成标记（计时 50）", true, false }, { "只生成导弹（高度 -1000，计时 9）", false, true } }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(api.item)
            p:AddCollectible(CollectibleType.COLLECTIBLE_EPIC_FETUS)
            wait(10)
            local pos = p.Position + Vector(120, 0)
            local dummy = spawnDummy(pos)
            if cfg[2] then
                local m = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.TARGET, 0, pos, Vector.Zero, p):ToEffect()
                m.Timeout = 50
            end
            if cfg[3] then
                local r = Isaac.Spawn(EntityType.ENTITY_EFFECT, EffectVariant.ROCKET, 0, pos, Vector.Zero, p):ToEffect()
                r.PositionOffset = Vector(0, -1000)
                r.Timeout = 9
            end
            local last, lines = "", {}
            damageLog = {}
            for f = 1, 70 do
                dummy.Position, dummy.Velocity = pos, Vector.Zero
                local parts = {}
                for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT)) do
                    if e.Variant == EffectVariant.TARGET or e.Variant == EffectVariant.ROCKET then
                        parts[#parts + 1] = string.format("%s[%s 帧%d 高度%.0f 计时%d]", e.Variant == EffectVariant.TARGET and "标记" or "导弹",
                            e:GetSprite():GetAnimation(), e:GetSprite():GetFrame(), e.PositionOffset.Y, e:ToEffect().Timeout)
                    end
                end
                for _, sd in ipairs({ { "BEEP", SoundEffect.SOUND_BEEP }, { "爆炸", SoundEffect.SOUND_BOSS1_EXPLOSIONS } }) do
                    if SFXManager():IsPlaying(sd[2]) then
                        parts[#parts + 1] = "声音:" .. sd[1]
                    end
                end
                local dmg = {}
                for _, d in ipairs(damageTo(dummy)) do
                    dmg[#dmg + 1] = string.format("%.1f", d.amount)
                end
                parts[#parts + 1] = "伤害[" .. table.concat(dmg, ",") .. "]"
                local now = table.concat(parts, " ")
                if now ~= last then
                    lines[#lines + 1] = f .. ": " .. now
                    last = now
                end
                wait(1)
            end
            damageLog = nil
            log("PROBE 史诗胎儿自动流程（" .. cfg[1] .. "）" .. table.concat(lines, " || "))
            dummy:Remove()
        end
    end }
    probeB[3] = { id = 3, name = "塞壬魅惑跟班实测", fn = function()
        for _, withZenith in ipairs({ false, true }) do
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            waitUntil(function() return gameStarted end, 300)
            wait(30)
            clearRoom()
            local p = player()
            p:AddCollectible(CollectibleType.COLLECTIBLE_INCUBUS)
            if withZenith then
                p:AddCollectible(api.item)
            end
            wait(10)
            local siren = Isaac.Spawn(EntityType.ENTITY_SIREN, 0, 0, center() + Vector(0, -100), Vector.Zero, nil)
            local last = ""
            nativeAttacks, familiarShots = 0, 0
            local st = api.getState(p)
            for f = 1, 900 do
                p:SetMinDamageCooldown(60)
                if siren:Exists() then
                    siren.HitPoints = siren.MaxHitPoints
                end
                -- 按住射击键（拿着天顶剑时准星放在角色右边）
                simNative = Vector(1, 0)
                if withZenith then
                    local target = st.crosshair
                    if not (target and target:Exists()) then
                        target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, p.Position + Vector(80, 0), Vector.Zero, p):ToEffect()
                        st.crosshair = target
                    end
                    target.Position, target.Velocity = p.Position + Vector(80, 0), Vector.Zero
                end
                local parts = {}
                for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR)) do
                    local fam = e:ToFamiliar()
                    local okC, charmed = pcall(function() return fam:IsCharmed() end)
                    parts[#parts + 1] = string.format("跟班 %d.%d 归属=%s IsCharmed=%s FLAG_CHARM=%s 离塞壬约 %d", e.Variant, e.SubType,
                        tostring(fam.Player ~= nil), okC and tostring(charmed) or "无此接口", tostring(e:HasEntityFlags(EntityFlag.FLAG_CHARM)),
                        siren:Exists() and math.floor(e.Position:Distance(siren.Position) / 100) * 100 or -1)
                end
                for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_SIREN_HELPER)) do
                    parts[#parts + 1] = string.format("塞壬助手 %d.%d", e.Variant, e.SubType)
                end
                local now = table.concat(parts, "；")
                if now ~= last then
                    log(string.format("PROBE 塞壬（%s）第 %d 帧：%s | 角色出剑累计 %d，原生攻击 %d，跟班射击 %d", withZenith and "拿天顶剑" or "不拿",
                        f, now, withZenith and st.cycle or 0, nativeAttacks, familiarShots))
                    last = now
                end
                wait(1)
            end
            simNative = nil
            local swordsFromFam = 0
            for _, s in ipairs(st.swords or {}) do
                if s.anchor then
                    swordsFromFam = swordsFromFam + 1
                end
            end
            log(string.format("PROBE 塞壬（%s）结束：原生攻击 %d，跟班射击 %d，场上跟班的剑 %d，敌方弹幕 %d", withZenith and "拿天顶剑" or "不拿",
                nativeAttacks, familiarShots, swordsFromFam, #Isaac.FindByType(EntityType.ENTITY_PROJECTILE)))
            if siren:Exists() then
                siren:Remove()
            end
        end
    end }

    -- 闪退排查（-Suite repro_give）：用户 16:13、16:14 两次闪退都在种子 YF6V VXWR 的以撒开局输入 giveitem c733 时。
    -- 用 Isaac.ExecuteCommand 走同样的命令（中文控制台 mod 也是这样提交命令的），再连续拿猫套、生成敌人并出剑
    local reproGive = {}
    reproGive[1] = { name = "控制台给天顶剑", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(20)
        gameStarted = false
        Isaac.ExecuteCommand("seed YF6V VXWR")
        check("用种子 YF6V VXWR 开局", waitUntil(function() return gameStarted end, 300))
        wait(60)
        for _, cmd in ipairs({ "giveitem c" .. api.item, "giveitem c134", "giveitem c212", "giveitem c133", "spawn 10.0", "spawn 10.0" }) do
            local out = Isaac.ExecuteCommand(cmd)
            log(string.format("REPRO 执行 %s → %s", cmd, tostring(out):gsub("\n", " ")))
            wait(45)
        end
        local p = player()
        local st = api.getState(p)
        for f = 1, 300 do
            p:SetMinDamageCooldown(60)
            local target = st.crosshair
            if not (target and target:Exists()) then
                target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, p.Position, Vector.Zero, p):ToEffect()
                st.crosshair = target
            end
            target.Position = p.Position + Vector(math.cos(f * 0.05) * 100, math.sin(f * 0.05) * 60)
            wait(1)
        end
        check("控制台给天顶剑和猫套后正常运行 300 帧", true, string.format("天顶剑 %d 个，猫套 %s", p:GetCollectibleNum(api.item),
            tostring(p:HasPlayerForm(PlayerForm.PLAYERFORM_GUPPY))))
    end }

    -- 攻击类道具联动（-Suite weapons）：每项重开一局，拿天顶剑 + 对应道具，准星固定在假人上 frames 帧。
    -- 统计联动生成的激光 / 炸弹（带 ZenithOwned 标记）、它们出现的位置，以及假人受到的每次伤害
    local weaponTests = {}
    local function weaponRun(character, items, frames, opts)
        opts = opts or {}
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. character)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(api.item)
        for _, item in ipairs(items) do
            p:AddCollectible(item)
        end
        wait(10)
        local st = api.getState(p)
        local home = p.Position
        local pos = home + Vector(120, 0)
        local dummy = spawnDummy(pos)
        if opts.setup then
            opts.setup(p, pos)
        end
        local seen, owned, swords, knifeSwords, coloredSwords, specials = {}, {}, {}, 0, 0, {}
        local result = { lasers = {}, bombs = 0, rockets = 0, targets = 0, nearCrosshair = 0, farCrosshair = 0, vanillaKnives = 0, nearPlayer = 0,
            eyeLevel = 0, maxLive = 0, orbitSamples = 0, orbitOk = 0, rocketHigh = 0, blink = false, warning = false }
        damageLog = {}
        for _ = 1, frames do
            p.Position, p.Velocity = home, Vector.Zero
            p:SetMinDamageCooldown(60)
            dummy.Position, dummy.Velocity = pos, Vector.Zero
            local target = st.crosshair
            if not (target and target:Exists()) then
                target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                st.crosshair = target
            end
            target.Position, target.Velocity = pos, Vector.Zero
            local live = 0
            for _, l in ipairs(Isaac.FindByType(EntityType.ENTITY_LASER)) do
                if l:GetData().ZenithOwned then
                    live = live + 1
                end
            end
            result.maxLive = math.max(result.maxLive, live)
            for _, m in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.TARGET)) do
                if m:GetData().ZenithOwned and m:GetSprite():GetAnimation() == "Blink" then
                    result.blink = true
                end
            end
            result.warning = result.warning or SFXManager():IsPlaying(SoundEffect.SOUND_DRSREMOTE_WARNING)
            for _, s in ipairs(st.swords) do
                -- 卢多维科：转圈中的剑离准星应约等于绕圈半径
                if s.orbit and s.progress > 10 and s.progress < C.PATH_END then
                    local x, y = Sword.Pose(s, s.progress, pos.X, pos.Y)
                    result.orbitSamples = result.orbitSamples + 1
                    if math.abs(Vector(x, y):Distance(pos) - C.LUDO_RADIUS) < 3 then
                        result.orbitOk = result.orbitOk + 1
                    end
                end
                if not swords[s] then
                    swords[s] = true
                    if s.knife then
                        knifeSwords = knifeSwords + 1
                    end
                    if s.color then
                        coloredSwords = coloredSwords + 1
                    end
                    if s.special then
                        specials[s.special] = (specials[s.special] or 0) + 1
                    end
                end
            end
            for _, e in ipairs(Isaac.GetRoomEntities()) do
                local key = GetPtrHash(e)
                if not seen[key] then
                    seen[key] = true
                    if e:GetData().ZenithOwned then
                        owned[#owned + 1] = e
                        if e.Type == EntityType.ENTITY_LASER then
                            local laser = e:ToLaser()
                            if laser.PositionOffset.Y < -5 then
                                result.eyeLevel = result.eyeLevel + 1
                            end
                            local k = e.Variant .. "|" .. string.format("%.0f", laser.MaxDistance)
                            result.lasers[k] = (result.lasers[k] or 0) + 1
                        elseif e.Type == EntityType.ENTITY_BOMB then
                            result.bombs = result.bombs + 1
                        elseif e.Variant == EffectVariant.ROCKET then
                            result.rockets = result.rockets + 1
                            if e.PositionOffset.Y <= -900 then
                                result.rocketHigh = result.rocketHigh + 1
                            end
                        elseif e.Variant == EffectVariant.TARGET then
                            result.targets = result.targets + 1
                        end
                        -- 第 2、3 把剑瞄准准星附近的随机点（偏移最多 75），所以按 100 以内算“在准星处”
                        if e.Position:Distance(p.Position) <= 40 then
                            result.nearPlayer = result.nearPlayer + 1
                        end
                        if e.Position:Distance(pos) <= 100 then
                            result.nearCrosshair = result.nearCrosshair + 1
                        else
                            result.farCrosshair = result.farCrosshair + 1
                        end
                    elseif e.Type == EntityType.ENTITY_KNIFE then
                        result.vanillaKnives = result.vanillaKnives + 1
                    end
                end
            end
            wait(1)
        end
        -- 原版妈刀实体（拿着天顶剑时应隐藏、无碰撞）
        result.vanillaHidden = true
        local infos = {}
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_KNIFE)) do
            result.vanillaHidden = result.vanillaHidden and not e.Visible and e.EntityCollisionClass == EntityCollisionClass.ENTCOLL_NONE
            infos[#infos + 1] = string.format("%d.%d 可见=%s 碰撞=%d", e.Variant, e.SubType, tostring(e.Visible), e.EntityCollisionClass)
        end
        result.vanillaKnifeInfo = table.concat(infos, "；")
        for _ = 1, opts.tail or 30 do
            p.Position, p.Velocity = home, Vector.Zero
            dummy.Position, dummy.Velocity = pos, Vector.Zero
            wait(1)
        end
        result.hits = damageTo(dummy)
        damageLog = nil
        result.dummyMarked = dummy:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED)
        result.frames = frames
        result.swords, result.knifeSwords, result.coloredSwords, result.player, result.specials = 0, knifeSwords, coloredSwords, p, specials
        for _ in pairs(swords) do
            result.swords = result.swords + 1
        end
        -- 按伤害数值分组：amount → 次数
        result.byAmount = {}
        for _, d in ipairs(result.hits) do
            local k = string.format("%.2f", d.amount)
            result.byAmount[k] = (result.byAmount[k] or 0) + 1
        end
        local parts = {}
        for k, v in pairs(result.byAmount) do
            parts[#parts + 1] = k .. "×" .. v
        end
        table.sort(parts)
        local lasers = {}
        for k, v in pairs(result.lasers) do
            lasers[#lasers + 1] = k .. "×" .. v
        end
        log(string.format("WEAPON 剑 %d（妈刀 %d），激光 %s，炸弹 %d，瞄准标记 %d，导弹 %d，生成在准星附近 %d / 远处 %d，原版妈刀实体 %d；伤害 %.2f，每次伤害 %s",
            result.swords, knifeSwords, table.concat(lasers, ","), result.bombs, result.targets, result.rockets, result.nearCrosshair,
            result.farCrosshair, result.vanillaKnives, p.Damage, table.concat(parts, " ")))
        dummy:Remove()
        return result
    end
    local function countAmount(r, amount)
        local n = 0
        for _, d in ipairs(r.hits) do
            if near(d.amount, amount, 0.02) then
                n = n + 1
            end
        end
        return n
    end
    local function laserCount(r, variant)
        local n = 0
        for k, v in pairs(r.lasers) do
            if k:match("^" .. variant .. "|") then
                n = n + v
            end
        end
        return n
    end
    -- 硫磺火 / 阿撒泻勒：血光 + 硫磺标记。被标记的敌人每次受到 剑的伤害 × 倍率；持续攻击的 DPS 应约等于
    -- 天顶剑本身 + 原版硫磺火（实测 7.46 + 4.5 倍角色伤害/秒，见 config.lua）
    local function markTest(tag, character, items, mult, dpsTarget)
        local r = weaponRun(character, items, 300)
        local d = r.player.Damage
        local markedHit = d * C.DAMAGE_MULT * mult
        local n = countAmount(r, markedHit) + countAmount(r, markedHit * C.CRIT_MULT)
        local total = 0
        for _, h in ipairs(r.hits) do
            total = total + h.amount
        end
        local dps = total / r.frames * 30 / d
        check(tag .. "：不再喷硫磺激光", laserCount(r, 1) == 0, "硫磺激光 " .. laserCount(r, 1))
        check(tag .. "：剑全部带血光", r.swords > 0 and r.coloredSwords == r.swords, string.format("剑 %d，血光 %d", r.swords, r.coloredSwords))
        check(tag .. "：敌人被上硫磺标记", r.dummyMarked)
        check(string.format("%s：被标记后每次命中 = 剑的伤害 × %d", tag, mult), n > #r.hits * 0.8,
            string.format("%d 次命中里 %d 次是 %.3f（或暴击 %.3f）", #r.hits, n, markedHit, markedHit * C.CRIT_MULT))
        log(string.format("WEAPON %s：持续攻击 DPS = 每秒 %.2f 倍角色伤害%s", tag, dps, dpsTarget and string.format("（目标约 %.2f）", dpsTarget) or ""))
        if dpsTarget then
            check(tag .. "：持续攻击 DPS 接近目标", math.abs(dps - dpsTarget) / dpsTarget < 0.25,
                string.format("实测 %.2f，目标 %.2f 倍/秒", dps, dpsTarget))
        end
        return r
    end
    weaponTests[1] = { id = 1, name = "硫磺火联动", fn = function()
        -- 目标：天顶剑本身 7.46 + 原版硫磺火 4.5 倍/秒，×5 取整后约 12.4
        markTest("硫磺火", PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_BRIMSTONE }, C.BRIMSTONE_MARK_MULT, 7.46 / 3 * C.BRIMSTONE_MARK_MULT)

        -- 死亡传染：被标记的敌人被剑打死时，140 内的敌人被传染标记并受 角色伤害 × 2 + 3，远处的不受影响
        clearRoom()
        local p = player()
        local st = api.getState(p)
        local home = p.Position
        local pos = home + Vector(120, 0)
        -- 被打死的用 Horf（原地不动、死后不会变成别的敌人；Gaper 死后可能变成无头的身体继续走，会再次死亡传染）
        local doomed = Isaac.Spawn(EntityType.ENTITY_HORF, 0, 0, pos, Vector.Zero, nil):ToNPC()
        doomed.HitPoints = 1
        doomed:AddBrimstoneMark(EntityRef(p), 300)
        local nearE = spawnDummy(pos + Vector(0, -80))
        local farE = spawnDummy(pos + Vector(0, -220))
        local nearPos, farPos = nearE.Position, farE.Position
        damageLog = {}
        for _ = 1, 60 do
            p.Position, p.Velocity = home, Vector.Zero
            nearE.Position, nearE.Velocity = nearPos, Vector.Zero
            farE.Position, farE.Velocity = farPos, Vector.Zero
            if doomed:Exists() then
                doomed.Position, doomed.Velocity = pos, Vector.Zero
            end
            local target = st.crosshair
            if not (target and target:Exists()) then
                target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                st.crosshair = target
            end
            target.Position, target.Velocity = pos, Vector.Zero
            if not doomed:Exists() or doomed:IsDead() then
                break
            end
            wait(1)
        end
        wait(2)
        local spreadDamage = p.Damage * C.BRIMSTONE_SPREAD_DAMAGE_MULT + C.BRIMSTONE_SPREAD_DAMAGE_ADD
        local nearGot = 0
        for _, h in ipairs(damageTo(nearE)) do
            if near(h.amount, spreadDamage, 0.02) then
                nearGot = nearGot + 1
            end
        end
        -- 远处敌人可能被随机偏移的剑直接砍到（也会被标记），所以只看有没有受到传染伤害
        local farHits = 0
        for _, h in ipairs(damageTo(farE)) do
            if near(h.amount, spreadDamage, 0.02) then
                farHits = farHits + 1
            end
        end
        damageLog = nil
        check("硫磺火：标记敌人被剑打死", not doomed:Exists() or doomed:IsDead())
        check("死亡传染：附近敌人被标记并受 角色伤害 × 2 + 3", nearE:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED) and nearGot >= 1,
            string.format("标记=%s，%.2f 伤害 %d 次", tostring(nearE:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED)), spreadDamage, nearGot))
        check("死亡传染：远处敌人没有受到传染伤害", farHits == 0, string.format("传染伤害 %d 次", farHits))
        nearE:Remove()
        farE:Remove()

        -- 不是被剑打死（直接造成伤害）不传染（用户决定：只有被剑打死才传染）
        clearRoom()
        local a = Isaac.Spawn(EntityType.ENTITY_HORF, 0, 0, pos, Vector.Zero, nil):ToNPC()
        local c = spawnDummy(pos + Vector(0, -80))
        local cPos = c.Position
        a:AddBrimstoneMark(EntityRef(p), 300)
        wait(2)
        damageLog = {}
        a:TakeDamage(1000, 0, EntityRef(p), 0)
        for _ = 1, 10 do
            c.Position, c.Velocity = cPos, Vector.Zero
            wait(1)
        end
        local cHits = #damageTo(c)
        damageLog = nil
        check("不是被剑打死时不传染", (not a:Exists() or a:IsDead()) and not c:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED) and cHits == 0,
            string.format("A 死亡=%s，附近敌人标记=%s，受伤 %d 次", tostring(not a:Exists() or a:IsDead()),
                tostring(c:HasEntityFlags(EntityFlag.FLAG_BRIMSTONE_MARKED)), cHits))
        c:Remove()
    end }
    weaponTests[2] = { id = 2, name = "阿撒泻勒联动", fn = function()
        markTest("阿撒泻勒", PlayerType.PLAYER_AZAZEL, {}, C.AZAZEL_MARK_MULT)
        -- 拿到硫磺火道具：仍是弱化版倍率（原本攻击方式被覆盖，不额外叠加）
        markTest("阿撒泻勒 + 硫磺火", PlayerType.PLAYER_AZAZEL, { CollectibleType.COLLECTIBLE_BRIMSTONE }, C.AZAZEL_MARK_MULT)
    end }
    weaponTests[3] = { id = 3, name = "科技联动", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_TECHNOLOGY }, 150)
        local lasers = laserCount(r, 2)
        check("科技：每把剑第一次命中时射一道激光", lasers > 0 and lasers <= r.swords and lasers >= r.swords * 0.6,
            string.format("剑 %d，激光 %d", r.swords, lasers))
        check("科技激光从角色身上射出", r.nearPlayer == lasers, string.format("激光 %d，在角色身上生成 %d", lasers, r.nearPlayer))
        check("科技激光从眼睛的高度射出", r.eyeLevel == lasers, string.format("激光 %d，带眼睛高度偏移 %d", lasers, r.eyeLevel))
        local hits = countAmount(r, r.player.Damage * C.TECH_DAMAGE)
        check("科技激光命中敌人，伤害 = 角色伤害 × " .. C.TECH_DAMAGE, hits >= lasers * 0.8, string.format("激光 %d，命中 %d", lasers, hits))
    end }
    weaponTests[4] = { id = 4, name = "博士胎儿联动", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_DR_FETUS }, 180, { tail = 90 })
        check("博士胎儿：每个射击间隔放一颗炸弹（剑数的一半）", r.bombs > 0 and math.abs(r.bombs - r.swords / C.FIRE_RATE_MULT) <= 2,
            string.format("剑 %d，炸弹 %d", r.swords, r.bombs))
        check("炸弹放在准星处（含随机偏移）", r.nearCrosshair == r.bombs, string.format("准星附近 %d，炸弹 %d", r.nearCrosshair, r.bombs))
        local blasts = countAmount(r, r.player.Damage * 10)
        check("炸弹伤害 = 角色伤害 × 10（原版）", blasts > 0, "爆炸命中 " .. blasts .. " 次")
    end }
    weaponTests[5] = { id = 5, name = "史诗胎儿联动", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_EPIC_FETUS }, 300, { tail = 60 })
        local interval = C.EPIC_FETUS_BASE_INTERVAL + r.player.MaxFireDelay + 1
        local expected = math.floor(300 / interval)
        check("史诗胎儿：按原版间隔在准星处落导弹", r.targets >= expected - 1 and r.targets <= expected + 1 and r.rockets >= r.targets - 1,
            string.format("间隔 %.0f 帧，预期约 %d，瞄准标记 %d，导弹 %d", interval, expected, r.targets, r.rockets))
        local blasts = countAmount(r, r.player.Damage * 20)
        check("导弹伤害 = 角色伤害 × 20（原版，由导弹自己爆炸造成）", blasts >= expected - 1 and blasts <= r.rockets, "爆炸命中 " .. blasts .. " 次，导弹 " .. r.rockets)
        check("瞄准标记像原版一样闪烁", r.blink)
        check("播放“滴滴”提示音", r.warning)
        check("导弹从高处落下（原版 1000 高）", r.rockets > 0 and r.rocketHigh == r.rockets, string.format("导弹 %d，从高处出现 %d", r.rockets, r.rocketHigh))
    end }
    -- 英灵剑：1/5 换成英灵剑（满血时换成剑气），不叠加；和妈刀共用概率；能拾取掉落物、打开箱子
    weaponTests[7] = { id = 7, name = "英灵剑联动", fn = function()
        local I = CollectibleType
        local function frac(r, kind)
            return r.swords > 0 and (r.specials[kind] or 0) / r.swords or 0
        end
        -- 满血：全部是剑气，伤害 5.5 + 角色伤害 × 4；同时检查拾取掉落物和开箱子
        local chest, coins0
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_SPIRIT_SWORD }, 360, { setup = function(p, pos)
            coins0 = p:GetNumCoins()
            for k = 0, 5 do
                Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COIN, CoinSubType.COIN_PENNY,
                    pos + Vector(math.cos(k) * 40, math.sin(k) * 40), Vector.Zero, nil)
            end
            chest = Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_CHEST, ChestSubType.CHEST_CLOSED, pos + Vector(-30, 30), Vector.Zero, nil)
        end })
        local p = r.player
        local d = p.Damage
        check("英灵剑：约 1/5 的剑换成英灵剑，满血时全部是剑气", r.swords >= 40 and frac(r, "beam") > 0.1 and frac(r, "beam") < 0.32 and (r.specials.spirit or 0) == 0,
            string.format("剑 %d，剑气 %d，英灵剑 %d", r.swords, r.specials.beam or 0, r.specials.spirit or 0))
        local beamHits = countAmount(r, C.SWORD_BEAM_DAMAGE_ADD + d * C.SWORD_BEAM_DAMAGE_MULT)
        check("剑气伤害 = 5.5 + 角色伤害 × 4，每把只打一次", beamHits > 0 and beamHits <= (r.specials.beam or 0),
            string.format("剑气 %d 把，命中 %d 次", r.specials.beam or 0, beamHits))
        check("英灵剑能拾取掉落物（硬币）", p:GetNumCoins() > coins0, string.format("硬币 %d → %d", coins0, p:GetNumCoins()))
        check("英灵剑能打开箱子", chest and (not chest:Exists() or chest.SubType ~= ChestSubType.CHEST_CLOSED), "箱子子类型 " .. tostring(chest and chest.SubType))
        check("原版英灵剑实体被隐藏且没有碰撞", r.vanillaHidden, r.vanillaKnifeInfo or "")

        -- 不满血：英灵剑，伤害 3.5 + 角色伤害 × 3；拿 2 个英灵剑不叠加
        local r2 = weaponRun(PlayerType.PLAYER_ISAAC, { I.COLLECTIBLE_SPIRIT_SWORD, I.COLLECTIBLE_SPIRIT_SWORD }, 300, { setup = function(p2)
            p2:AddHearts(-2)
        end })
        local spiritHits = countAmount(r2, C.SPIRIT_SWORD_DAMAGE_ADD + r2.player.Damage * C.SPIRIT_SWORD_DAMAGE_MULT)
        check("不满血：换成英灵剑而不是剑气", (r2.specials.spirit or 0) > 0 and (r2.specials.beam or 0) == 0,
            string.format("英灵剑 %d，剑气 %d", r2.specials.spirit or 0, r2.specials.beam or 0))
        check("2 个英灵剑不叠加：仍约 1/5", frac(r2, "spirit") > 0.1 and frac(r2, "spirit") < 0.32, string.format("%.0f%%", frac(r2, "spirit") * 100))
        check("英灵剑伤害 = 3.5 + 角色伤害 × 3，每把只打一次", spiritHits > 0 and spiritHits <= (r2.specials.spirit or 0),
            string.format("英灵剑 %d 把，命中 %d 次", r2.specials.spirit or 0, spiritHits))

        -- 1 英灵剑 + 4 妈刀：80% 妈刀、20% 英灵剑；再加 1 把妈刀不变
        local items = { I.COLLECTIBLE_SPIRIT_SWORD }
        for _ = 1, 5 do
            items[#items + 1] = I.COLLECTIBLE_MOMS_KNIFE
        end
        local r3 = weaponRun(PlayerType.PLAYER_ISAAC, items, 240)
        check("1 英灵剑 + 5 妈刀：约 80% 妈刀、20% 英灵剑 / 剑气，没有普通剑", r3.swords > 0
            and frac(r3, "knife") > 0.65 and frac(r3, "knife") < 0.92 and (r3.specials.knife or 0) + (r3.specials.beam or 0) + (r3.specials.spirit or 0) == r3.swords,
            string.format("剑 %d，妈刀 %d，剑气 %d，英灵剑 %d", r3.swords, r3.specials.knife or 0, r3.specials.beam or 0, r3.specials.spirit or 0))
    end }
    local function dpsOf(r, amount)
        local total = 0
        for _, h in ipairs(r.hits) do
            if not amount or near(h.amount, amount, 0.02) then
                total = total + h.amount
            end
        end
        return total / (r.frames + 30) * 30 / r.player.Damage
    end
    weaponTests[8] = { id = 8, name = "科技 2 联动", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_TECHNOLOGY_2 }, 300)
        local tick = r.player.Damage * C.TECH2_DAMAGE
        local laserDps = dpsOf(r, tick) * (r.frames + 30) / r.frames
        check("科技 2：同时只有一道连到准星的激光", r.maxLive == 1 and laserCount(r, 2) >= 1, string.format("同时最多 %d 道，生成 %d 次", r.maxLive, laserCount(r, 2)))
        check("科技 2：激光从眼睛的高度射出", r.eyeLevel >= 1)
        -- 每 2 帧打一次（每秒 15 次）× 每次倍率
        local expectDps = 15 * C.TECH2_DAMAGE
        check(string.format("科技 2：激光每秒伤害 ≈ %.2f 倍（每次 %.2f 倍、每 2 帧一次）", expectDps, C.TECH2_DAMAGE), math.abs(laserDps - expectDps) / expectDps < 0.25,
            string.format("实测 %.2f 倍/秒（每次 %.3f）", laserDps, tick))
        log(string.format("WEAPON 科技 2：总 DPS 每秒 %.2f 倍角色伤害", dpsOf(r)))
    end }
    weaponTests[9] = { id = 9, name = "科技 X 联动", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_TECH_X }, 300)
        local rings = 0
        for k, v in pairs(r.lasers) do
            rings = rings + v
        end
        local tick = r.player.Damage * C.TECHX_DAMAGE
        local ringDps = dpsOf(r, tick) * (r.frames + 30) / r.frames
        check("科技 X：每把剑带一个激光环", rings > 0 and rings >= math.min(r.swords, C.TECHX_MAX_RINGS) * 0.8 and rings <= r.swords,
            string.format("剑 %d，环 %d，同时最多 %d", r.swords, rings, r.maxLive))
        log(string.format("WEAPON 科技 X：环每秒伤害 %.2f 倍角色伤害（目标 1.74，每次 %.3f），总 DPS %.2f 倍", ringDps, tick, dpsOf(r)))
        check("科技 X：环每秒伤害 ≈ 原版 1.74 倍", math.abs(ringDps - 1.74) / 1.74 < 0.3, string.format("实测 %.2f", ringDps))
    end }
    weaponTests[10] = { id = 10, name = "卢多维科联动", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_LUDOVICO_TECHNIQUE }, 300)
        check("卢多维科：飞剑围着准星转圈", r.orbitSamples > 0 and r.orbitOk == r.orbitSamples, string.format("采样 %d，在绕圈半径上 %d", r.orbitSamples, r.orbitOk))
        check("卢多维科：飞剑命中敌人", #r.hits > 0, "命中 " .. #r.hits)
        log(string.format("WEAPON 卢多维科：DPS 每秒 %.2f 倍角色伤害（单独天顶剑 7.46，原版卢多维科 3.0）", dpsOf(r)))
    end }
    -- 卢多维科移动准星（用户要求：不要把怪物放在准星正中）。同一局里依次测三种准星走法 × 三种配置：
    -- 卢多维科转速原值（1.5 圈）、转速 ×2.25（3.375 圈）、不拿卢多维科（单独天顶剑）。转速在运行时直接改配置表
    weaponTests[11] = { id = 11, name = "卢多维科移动准星 DPS", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(api.item)
        p:AddCollectible(CollectibleType.COLLECTIBLE_LUDOVICO_TECHNIQUE)
        wait(10)
        local st = api.getState(p)
        local home = p.Position
        local enemyPos = home + Vector(120, 0)
        local paths = {
            { "准星固定在怪物旁 45", function() return enemyPos + Vector(0, -45) end },
            { "准星绕着怪物转圈（半径 60，2 秒一圈）", function(f) return enemyPos + Vector(math.cos(f * math.pi / 30) * 60, math.sin(f * math.pi / 30) * 60) end },
            { "准星左右来回扫过怪物（±80，2 秒来回）", function(f) return enemyPos + Vector(math.sin(f * math.pi / 30) * 80, 0) end },
        }
        local SC = api.swordConfig -- mod 里飞剑实际用的配置表
        local turns0 = SC.LUDO_TURNS
        local configs = {
            { "卢多维科 转速原值 1.5 圈", 1.5, true },
            { "卢多维科 转速 ×2.25（3.375 圈）", 3.375, true },
        }
        for _, cfg in ipairs(configs) do
            SC.LUDO_TURNS = cfg[2]
            if not cfg[3] and p:HasCollectible(CollectibleType.COLLECTIBLE_LUDOVICO_TECHNIQUE) then
                p:RemoveCollectible(CollectibleType.COLLECTIBLE_LUDOVICO_TECHNIQUE)
                wait(5)
            end
            for _, path in ipairs(paths) do
                clearRoom()
                p.Position = home
                local dummy = spawnDummy(enemyPos)
                damageLog = {}
                for f = 1, 300 do
                    p.Position, p.Velocity = home, Vector.Zero
                    dummy.Position, dummy.Velocity = enemyPos, Vector.Zero
                    local target = st.crosshair
                    local at = path[2](f)
                    if not (target and target:Exists()) then
                        target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, at, Vector.Zero, p):ToEffect()
                        st.crosshair = target
                    end
                    target.Position, target.Velocity = at, Vector.Zero
                    wait(1)
                end
                local total = 0
                for _, h in ipairs(damageTo(dummy)) do
                    total = total + h.amount
                end
                damageLog = nil
                log(string.format("WEAPON 卢多维科 DPS | %s | %s：每秒 %.2f 倍角色伤害", cfg[1], path[1], total / 300 * 30 / p.Damage))
                dummy:Remove()
            end
        end
        SC.LUDO_TURNS = turns0
    end }
    local function freshIsaac(items)
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        for _, item in ipairs(items or {}) do
            p:AddCollectible(item)
        end
        wait(10)
        return p
    end
    local function stats(p)
        return string.format("伤害 %.2f 射击间隔 %.2f 射程 %.0f 弹速 %.2f", p.Damage, p.MaxFireDelay, p.TearRange, p.ShotSpeed)
    end
    -- 完全覆盖的道具：拿着天顶剑时屏蔽，属性和没拿这件道具时一样；失去天顶剑后解除，属性变化恢复
    weaponTests[12] = { id = 12, name = "完全覆盖的道具屏蔽", fn = function()
        local p = freshIsaac({ api.item })
        local base = stats(p)
        for _, name in ipairs(C.FULL_OVERRIDE) do
            local id = CollectibleType["COLLECTIBLE_" .. name]
            p:AddCollectible(id)
            wait(5)
            local blocked = p:IsCollectibleBlocked(id)
            local with = stats(p)
            check("拿着天顶剑：" .. name .. " 被屏蔽、属性不变", blocked and with == base, string.format("屏蔽=%s；%s（基准 %s）", tostring(blocked), with, base))
            p:RemoveCollectible(id)
            wait(3)
        end
        -- 失去天顶剑：解除屏蔽，道具重新生效（用溶血症看属性变化）
        p:AddCollectible(CollectibleType.COLLECTIBLE_HAEMOLACRIA)
        wait(5)
        local withZenith = stats(p)
        p:RemoveCollectible(api.item)
        wait(5)
        local without = stats(p)
        check("失去天顶剑后解除屏蔽、属性变化恢复", not p:IsCollectibleBlocked(CollectibleType.COLLECTIBLE_HAEMOLACRIA) and without ~= withZenith,
            string.format("拿着 %s → 失去后 %s", withZenith, without))
        p:AddCollectible(api.item)
        wait(5)
        check("重新拿到天顶剑后再次屏蔽", p:IsCollectibleBlocked(CollectibleType.COLLECTIBLE_HAEMOLACRIA) and stats(p) == base, stats(p))
    end }
    -- 背刺：每次命中 ×2（暴击再 ×2），并让敌人流血
    weaponTests[13] = { id = 13, name = "背刺百分百触发", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_BACKSTABBER }, 150)
        local d = r.player.Damage * C.DAMAGE_MULT * C.BACKSTAB_MULT
        local n = countAmount(r, d) + countAmount(r, d * C.CRIT_MULT)
        -- 只看飞剑的命中（来源是角色）；其余是流血等状态伤害，单独列出
        local swordHits, others = 0, {}
        for _, h in ipairs(r.hits) do
            if h.srcType == EntityType.ENTITY_PLAYER then
                swordHits = swordHits + 1
            else
                others[#others + 1] = string.format("%.2f(来源 %s)", h.amount, tostring(h.srcType))
            end
        end
        check("背刺：飞剑每次命中都是 ×2", swordHits > 0 and n == swordHits,
            string.format("飞剑命中 %d 次里 %d 次是 %.3f（或暴击）；其他伤害 %s", swordHits, n, d, table.concat(others, " ")))
    end }
    -- 硫酸：飞剑打碎石头；打开隐藏房的墙（找一个挨着隐藏房的房间进去，准星压到那面墙上）
    weaponTests[14] = { id = 14, name = "硫酸碎石与隐藏房", fn = function()
        local function rockRun(withAcid)
            local p = freshIsaac(withAcid and { api.item, CollectibleType.COLLECTIBLE_SULFURIC_ACID } or { api.item })
            local st = api.getState(p)
            local room = Game():GetRoom()
            local pos = p.Position + Vector(120, 0)
            local cells = {}
            for _, off in ipairs({ Vector(0, -40), Vector(0, 40), Vector(40, 0) }) do
                local idx = room:GetGridIndex(pos + off)
                Isaac.GridSpawn(GridEntityType.GRID_ROCK, 0, room:GetGridPosition(idx), true)
                cells[#cells + 1] = idx
            end
            for _ = 1, 120 do
                local target = st.crosshair
                if not (target and target:Exists()) then
                    target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                    st.crosshair = target
                end
                target.Position, target.Velocity = pos, Vector.Zero
                wait(1)
            end
            local broken = 0
            for _, idx in ipairs(cells) do
                local g = room:GetGridEntity(idx)
                if not g or g.CollisionClass == GridCollisionClass.COLLISION_NONE then
                    broken = broken + 1
                end
            end
            return broken, #cells
        end
        local b0, n0 = rockRun(false)
        check("对照：没有硫酸时飞剑不打碎石头", b0 == 0, b0 .. " / " .. n0)
        local b1, n1 = rockRun(true)
        check("硫酸：飞剑打碎石头", b1 == n1, b1 .. " / " .. n1)

        -- 隐藏房的墙
        local p = player()
        local level = Game():GetLevel()
        local secretIdx
        for i = 0, level:GetRooms().Size - 1 do
            local desc = level:GetRooms():Get(i)
            if desc.Data and desc.Data.Type == RoomType.ROOM_SECRET then
                secretIdx = desc.SafeGridIndex
            end
        end
        local neighbor
        if secretIdx then
            for _, off in ipairs({ -1, 1, -13, 13 }) do
                local d = level:GetRoomByIdx(secretIdx + off)
                if d and d.Data and d.Data.Type == RoomType.ROOM_DEFAULT and d.Data.Shape == RoomShape.ROOMSHAPE_1x1 then
                    neighbor = secretIdx + off
                end
            end
        end
        if not neighbor then
            log("SKIP 硫酸隐藏房：本层没有挨着 1x1 普通房间的隐藏房")
            return
        end
        Game():ChangeRoom(neighbor)
        wait(30)
        clearRoom()
        local room = Game():GetRoom()
        local door
        for slot = 0, DoorSlot.NUM_DOOR_SLOTS - 1 do
            local d = room:GetDoor(slot)
            if d and d.TargetRoomType == RoomType.ROOM_SECRET then
                door = d
            end
        end
        if not door then
            log("SKIP 硫酸隐藏房：相邻房间里没找到通往隐藏房的墙")
            return
        end
        local st = api.getState(p)
        local wallPos = room:GetClampedPosition(door.Position, 0)
        p.Position = wallPos + (room:GetCenterPos() - wallPos):Resized(100)
        local opened = false
        for _ = 1, 150 do
            p.Velocity = Vector.Zero
            local target = st.crosshair
            if not (target and target:Exists()) then
                target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, wallPos, Vector.Zero, p):ToEffect()
                st.crosshair = target
            end
            target.Position, target.Velocity = wallPos, Vector.Zero
            if door:IsOpen() then
                opened = true
                break
            end
            wait(1)
        end
        check("硫酸：飞剑打开隐藏房的墙", opened)
    end }
    -- 铅笔：每第 15 次出剑一次扔出 13 把剑
    weaponTests[15] = { id = 15, name = "铅笔齐射", fn = function()
        local p = freshIsaac({ api.item, CollectibleType.COLLECTIBLE_LEAD_PENCIL })
        local st = api.getState(p)
        local pos = p.Position + Vector(120, 0)
        local perShot, lastCycle, lastCount = {}, st.cycle, #st.swords
        local seen = {}
        for _, s in ipairs(st.swords) do
            seen[s] = true
        end
        for _ = 1, 400 do
            local target = st.crosshair
            if not (target and target:Exists()) then
                target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                st.crosshair = target
            end
            target.Position, target.Velocity = pos, Vector.Zero
            local new = 0
            for _, s in ipairs(st.swords) do
                if not seen[s] then
                    seen[s] = true
                    new = new + 1
                end
            end
            if st.cycle ~= lastCycle then
                perShot[#perShot + 1] = { shots = st.cycle - lastCycle, swords = new }
                lastCycle = st.cycle
            end
            wait(1)
        end
        local bursts, total, desc = 0, 0, {}
        for _, ps in ipairs(perShot) do
            total = total + ps.shots
            if ps.swords >= C.PENCIL_BURST then
                bursts = bursts + 1
            end
            desc[#desc + 1] = tostring(ps.swords)
        end
        local expected = math.floor(total / C.PENCIL_PERIOD)
        check("铅笔：每第 15 次出剑扔出 13 把剑", bursts >= 1 and math.abs(bursts - expected) <= 1,
            string.format("出剑 %d 次，齐射 %d 次（预期约 %d）；每次出剑的剑数 %s", total, bursts, expected, table.concat(desc, ",")))
    end }
    -- 清单道具（docs/道具兼容清单.md）
    local function holdCrosshair(p, st, pos, frames, onFrame)
        for f = 1, frames do
            p.Velocity = Vector.Zero
            local target = st.crosshair
            if not (target and target:Exists()) then
                target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                st.crosshair = target
            end
            target.Position, target.Velocity = pos, Vector.Zero
            if onFrame then
                onFrame(f)
            end
            wait(1)
        end
    end
    local function setLuck(p, luck)
        probeLuck = luck
        p:AddCacheFlags(CacheFlag.CACHE_LUCK)
        p:EvaluateItems()
    end
    weaponTests[16] = { id = 16, name = "完全覆盖补充（轨迹类道具、虫子饰品）", fn = function()
        local p = freshIsaac({ api.item })
        for _, name in ipairs({ "ANTI_GRAVITY", "CONTINUUM", "RUBBER_CEMENT", "FLAT_STONE", "TRACTOR_BEAM" }) do
            local id = CollectibleType["COLLECTIBLE_" .. name]
            p:AddCollectible(id)
            wait(3)
            check("拿着天顶剑：" .. name .. " 被屏蔽", p:IsCollectibleBlocked(id))
            p:RemoveCollectible(id)
        end
        for _, name in ipairs(C.FULL_OVERRIDE_TRINKETS) do
            local id = TrinketType["TRINKET_" .. name]
            p:AddTrinket(id)
            wait(3)
            check("拿着天顶剑：饰品 " .. name .. " 被屏蔽", p:IsTrinketBlocked(id))
            p:TryRemoveTrinket(id)
        end
    end }
    weaponTests[17] = { id = 17, name = "命中特效替身（小魔角、圣光）", fn = function()
        -- 小魔角：幸运拉满，普通敌人（高血量）应被替身眼泪按原版效果处理
        local p = freshIsaac({ api.item, CollectibleType.COLLECTIBLE_LITTLE_HORN })
        setLuck(p, 30)
        local st = api.getState(p)
        local pos = p.Position + Vector(120, 0)
        local e = spawnDummy(pos)
        local proxies, seen = 0, {}
        damageLog = {}
        holdCrosshair(p, st, pos, 240, function()
            if e:Exists() then
                e.Position, e.Velocity = pos, Vector.Zero
            end
            for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                if t:GetData().ZenithProxy and not seen[GetPtrHash(t)] then
                    seen[GetPtrHash(t)] = true
                    proxies = proxies + 1
                end
            end
        end)
        local maxHit = 0
        for _, d in ipairs(damageTo(e)) do
            maxHit = math.max(maxHit, d.amount)
        end
        damageLog = nil
        check("小魔角：飞剑第一次命中时放出替身眼泪", proxies > 0, "替身 " .. proxies)
        check("小魔角：原版效果生效（高血量敌人被秒杀或受到远超飞剑的伤害）", not e:Exists() or e:IsDead() or maxHit > p.Damage * 10,
            string.format("敌人存活=%s，最大单次伤害 %.1f", tostring(e:Exists() and not e:IsDead()), maxHit))
        setLuck(p, 0)
        -- 圣光：幸运拉满，应召唤光柱
        p = freshIsaac({ api.item, CollectibleType.COLLECTIBLE_HOLY_LIGHT })
        setLuck(p, 30)
        st = api.getState(p)
        e = spawnDummy(pos)
        local beams = 0
        seen = {}
        holdCrosshair(p, st, pos, 180, function()
            e.Position, e.Velocity = pos, Vector.Zero
            for _, b in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.CRACK_THE_SKY)) do
                if not seen[GetPtrHash(b)] then
                    seen[GetPtrHash(b)] = true
                    beams = beams + 1
                end
            end
        end)
        check("圣光：飞剑命中时按原版召唤光柱", beams > 0, "光柱 " .. beams)
        setLuck(p, 0)
        e:Remove()
    end }
    weaponTests[18] = { id = 18, name = "改变发射方向的道具", fn = function()
        local cases = {
            { "THE_WIZ", 0, function(n, back) return n == 3 end, "每次出剑 3 把（1 + 2）" },
            { "LOKIS_HORNS", 30, function(n, back) return n == 4 end, "幸运拉满时每次出剑 4 把（1 + 3）" },
            { "MOMS_EYE", 10, function(n, back) return n == 2 and back == 1 end, "幸运 10 时每次出剑 2 把，其中 1 把飞向背后" },
        }
        for _, cs in ipairs(cases) do
            local p = freshIsaac({ api.item, CollectibleType["COLLECTIBLE_" .. cs[1]] })
            setLuck(p, cs[2])
            local st = api.getState(p)
            local pos = p.Position + Vector(120, 0)
            local seen, ok, total, last = {}, 0, 0, st.cycle
            local perCycle = {}
            holdCrosshair(p, st, pos, 150, function()
                local n, back = 0, 0
                for _, s in ipairs(st.swords) do
                    if not seen[s] then
                        seen[s] = true
                        n = n + 1
                        if s.vx < 0 then
                            back = back + 1
                        end
                    end
                end
                if st.cycle ~= last then
                    last = st.cycle
                    total = total + 1
                    if cs[3](n, back) then
                        ok = ok + 1
                    end
                    perCycle[#perCycle + 1] = n .. (back > 0 and ("(后" .. back .. ")") or "")
                end
            end)
            setLuck(p, 0)
            check(cs[1] .. "：" .. cs[4], total > 0 and ok >= total - 1, string.format("%d / %d 次符合；每次 %s", ok, total, table.concat(perCycle, ",")))
        end
        -- 眼疮：概率多出 1～3 把剑
        local p = freshIsaac({ api.item, CollectibleType.COLLECTIBLE_EYE_SORE })
        local st = api.getState(p)
        local hist, seen, last = {}, {}, st.cycle
        holdCrosshair(p, st, p.Position + Vector(120, 0), 300, function()
            local n = 0
            for _, s in ipairs(st.swords) do
                if not seen[s] then
                    seen[s] = true
                    n = n + 1
                end
            end
            if st.cycle ~= last then
                last = st.cycle
                hist[n] = (hist[n] or 0) + 1
            end
        end)
        local parts = {}
        for k, v in pairs(hist) do
            parts[#parts + 1] = k .. "把×" .. v
        end
        check("眼疮：有的出剑多出 1～3 把", (hist[2] or 0) + (hist[3] or 0) + (hist[4] or 0) > 0 and (hist[1] or 0) > 0, table.concat(parts, " "))
    end }
    weaponTests[19] = { id = 19, name = "小行星：飞剑绕角色转", fn = function()
        local p = freshIsaac({ api.item, CollectibleType.COLLECTIBLE_TINY_PLANET })
        local st = api.getState(p)
        local samples, okN = 0, 0
        holdCrosshair(p, st, p.Position + Vector(120, 0), 120, function()
            local o = p.Position + C.ORIGIN_OFFSET
            for _, s in ipairs(st.swords) do
                if s.orbit == "player" and s.progress > 10 and s.progress < C.PATH_END then
                    local x, y = Sword.Pose(s, s.progress, o.X, o.Y)
                    samples = samples + 1
                    if math.abs(Vector(x, y):Distance(o) - C.TINY_PLANET_RADIUS) < 3 then
                        okN = okN + 1
                    end
                end
            end
        end)
        check("小行星：飞剑围着角色转圈", samples > 0 and okN == samples, string.format("采样 %d，在半径上 %d", samples, okN))
    end }
    weaponTests[20] = { id = 20, name = "鬼椒、鸟眼椒火焰", fn = function()
        for _, cs in ipairs({ { "GHOST_PEPPER", 10 }, { "BIRDS_EYE", 52 } }) do
            local p = freshIsaac({ api.item, CollectibleType["COLLECTIBLE_" .. cs[1]] })
            setLuck(p, 20)
            local st = api.getState(p)
            local pos = p.Position + Vector(120, 0)
            local flames, near, seen, scaleOk = 0, 0, {}, true
            holdCrosshair(p, st, pos, 150, function()
                for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, cs[2])) do
                    if not seen[GetPtrHash(e)] then
                        seen[GetPtrHash(e)] = true
                        flames = flames + 1
                        if e.Position:Distance(pos) <= 100 then
                            near = near + 1
                        end
                        scaleOk = scaleOk and e.SpriteScale.X > 0.5
                    end
                end
            end)
            setLuck(p, 0)
            check(cs[1] .. "：在准星处生成火焰", flames > 0 and near == flames and scaleOk, string.format("火焰 %d，在准星附近 %d", flames, near))
        end
    end }
    weaponTests[21] = { id = 21, name = "神性光环、眼球突出、死亡之眼", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_GODHEAD }, 150)
        check("神性：光环造成 2 点伤害", countAmount(r, C.GODHEAD_DAMAGE) > 0, "2 点伤害 " .. countAmount(r, C.GODHEAD_DAMAGE) .. " 次")
        -- 眼球突出：假人离角色 120，伤害倍率按曲线 = 2.28 + (0.75 - 2.28) × 20 / 60
        local r2 = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_PROPTOSIS }, 120)
        local m = 2.28 + (0.75 - 2.28) * 20 / 60
        local expect = r2.player.Damage * C.DAMAGE_MULT * m
        local n = countAmount(r2, expect) + countAmount(r2, expect * C.CRIT_MULT)
        check("眼球突出：命中伤害按距离倍率", n > 0, string.format("预期 %.3f（倍率 %.2f），符合 %d / %d", expect, m, n, #r2.hits))
        -- 死亡之眼：连续命中后出现 ×2 的伤害
        local r3 = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_DEAD_EYE }, 150)
        local top = r3.player.Damage * C.DAMAGE_MULT * (1 + C.DEAD_EYE_STEP * C.DEAD_EYE_MAX)
        check("死亡之眼：连续命中叠到最高层", countAmount(r3, top) + countAmount(r3, top * C.CRIT_MULT) > 0, string.format("最高层伤害 %.3f", top))
    end }
    -- 肾结石原版：按住射击键 1800 帧，统计眼泪、齐射和石头（只记录，不判定）
    weaponTests[22] = { id = 22, name = "肾结石原版实测（只记录）", fn = function()
        local p = freshIsaac({ CollectibleType.COLLECTIBLE_KIDNEY_STONE })
        local home = p.Position
        local seen, shots, bursts, variants = {}, 0, {}, {}
        simNative = Vector(1, 0)
        for f = 1, 1800 do
            p.Position, p.Velocity = home, Vector.Zero
            local n = 0
            for _, t in ipairs(Isaac.FindByType(EntityType.ENTITY_TEAR)) do
                if not seen[GetPtrHash(t)] then
                    seen[GetPtrHash(t)] = true
                    n = n + 1
                    variants[t.Variant] = (variants[t.Variant] or 0) + 1
                end
            end
            if n > 0 then
                shots = shots + 1
                if n > 1 then
                    bursts[#bursts + 1] = f .. ":" .. n
                end
            end
            wait(1)
        end
        simNative = nil
        local v = {}
        for k, c in pairs(variants) do
            v[#v + 1] = k .. "×" .. c
        end
        log(string.format("WEAPON 肾结石原版：射击 %d 次，齐射（帧:眼泪数）%s；眼泪变体 %s；射击间隔 %.2f", shots, table.concat(bursts, " "), table.concat(v, " "), p.MaxFireDelay))
    end }
    -- 控制台命令 zenith_give：给 1P 一个天顶剑，返回里带实际道具编号；玩家编号不存在时不给。
    -- 注意：测试在协程里，用 Isaac.ExecuteCommand 执行 mod 自己定义的命令会让游戏崩溃（实测两次，地址相同），
    -- 所以用 Isaac.RunCallback 直接调用命令回调（玩家在控制台输入时不经过这条路）
    local function runCommand(cmd, params)
        return Isaac.RunCallback(ModCallbacks.MC_EXECUTE_CMD, cmd, params or "")
    end
    weaponTests[23] = { id = 23, name = "控制台命令 zenith_give", fn = function()
        local p = freshIsaac({})
        local before = p:GetCollectibleNum(api.item)
        local out = runCommand("zenith_give")
        wait(3)
        check("zenith_give：给 1P 一个天顶剑", p:GetCollectibleNum(api.item) == before + 1 and tostring(out):find(tostring(api.item), 1, true) ~= nil,
            tostring(out))
        local out2 = runCommand("zenith_give", "5")
        check("zenith_give 5：没有这个玩家时不给", p:GetCollectibleNum(api.item) == before + 1 and tostring(out2):find("No player", 1, true) ~= nil, tostring(out2))
    end }
    -- 原版史诗胎儿标记阶段正在播放的所有声音（找“滴滴”提示音，只记录）
    weaponTests[24] = { id = 24, name = "史诗胎儿提示音实测（只记录）", fn = function()
        local p = freshIsaac({ CollectibleType.COLLECTIBLE_EPIC_FETUS })
        local home = p.Position
        local heard = {}
        simNative = Vector(1, 0)
        for f = 1, 60 do
            p.Position, p.Velocity = home, Vector.Zero
            for id = 1, 900 do
                if SFXManager():IsPlaying(id) and not heard[id] then
                    heard[id] = f
                end
            end
            wait(1)
        end
        simNative = nil
        local names = {}
        for name, id in pairs(SoundEffect) do
            names[id] = name
        end
        local parts = {}
        for id, f in pairs(heard) do
            parts[#parts + 1] = string.format("%d(%s)@%d", id, names[id] or "?", f)
        end
        log("WEAPON 史诗胎儿标记阶段的声音：" .. (#parts > 0 and table.concat(parts, " ") or "无"))
    end }
    -- 设置：模组配置菜单注册、默认道具池、关掉的道具池抽不到天顶剑（测完恢复原来的设置）
    weaponTests[25] = { id = 25, name = "设置页面与道具池", fn = function()
        local Settings = include("scripts.zenith.settings")
        freshIsaac({})
        if ModConfigMenu and ModConfigMenu.GetCategoryIDByName then
            local id = ModConfigMenu.GetCategoryIDByName("天顶剑")
            local subs = id and ModConfigMenu.MenuData[id].Subcategories or {}
            check("模组配置菜单里有“天顶剑”设置页（两个分页）", id ~= nil and #subs == 2, "分页 " .. #subs)
        else
            log("SKIP 没装模组配置菜单")
        end
        local backup = {}
        for k, v in pairs(Settings.values.pools or {}) do
            backup[k] = v
        end
        local defaults = {}
        for _, e in ipairs(Settings.POOLS) do
            if Settings.DEFAULTS.pools[e.key] then
                defaults[#defaults + 1] = e.name
            end
        end
        check("默认道具池：天使房、恶魔房、宝箱房、商店", #defaults == 4 and Settings.DEFAULTS.pools.angel and Settings.DEFAULTS.pools.devil
            and Settings.DEFAULTS.pools.treasure and Settings.DEFAULTS.pools.shop, table.concat(defaults, "、"))
        -- 只开商店：宝箱房抽 3000 次不该出现，商店抽 3000 次应该出现
        Settings.values.pools = { shop = true }
        local pool = Game():GetItemPool()
        local function draws(poolType)
            local n = 0
            for seed = 1, 3000 do
                if pool:GetCollectible(poolType, false, seed * 7919) == api.item then
                    n = n + 1
                end
            end
            return n
        end
        local inTreasure, inShop = draws(ItemPoolType.POOL_TREASURE), draws(ItemPoolType.POOL_SHOP)
        Settings.values.pools = backup
        check("关掉的道具池（宝箱房）抽不到天顶剑", inTreasure == 0, "3000 次里 " .. inTreasure .. " 次")
        check("开启的道具池（商店）能抽到天顶剑", inShop > 0, "3000 次里 " .. inShop .. " 次")
    end }
    weaponTests[6] = { id = 6, name = "妈刀联动", fn = function()
        local r = weaponRun(PlayerType.PLAYER_ISAAC, { CollectibleType.COLLECTIBLE_MOMS_KNIFE }, 300)
        local frac = r.swords > 0 and r.knifeSwords / r.swords or 0
        check("1 把妈刀：约 1/5 的剑换成妈刀", r.swords >= 40 and frac > 0.08 and frac < 0.35,
            string.format("剑 %d，妈刀 %d（%.0f%%）", r.swords, r.knifeSwords, frac * 100))
        local knifeHits = countAmount(r, r.player.Damage * C.KNIFE_DAMAGE_MULT)
        check("妈刀伤害 = 角色伤害 × 6，每把刀对假人只打一次", knifeHits > 0 and knifeHits <= r.knifeSwords,
            string.format("妈刀 %d 把，6 倍伤害命中 %d 次", r.knifeSwords, knifeHits))
        check("原版妈刀实体被隐藏且没有碰撞", r.vanillaHidden, r.vanillaKnifeInfo or "")
        local five = {}
        for _ = 1, 5 do
            five[#five + 1] = CollectibleType.COLLECTIBLE_MOMS_KNIFE
        end
        local r5 = weaponRun(PlayerType.PLAYER_ISAAC, five, 120)
        check("5 把妈刀：全部是妈刀", r5.swords > 0 and r5.knifeSwords == r5.swords, string.format("剑 %d，妈刀 %d", r5.swords, r5.knifeSwords))
    end }

    -- 攻击类道具扫描（-Suite items）：同一局以撒拿着天顶剑，逐个加上会改变攻击方式的道具，
    -- 模拟按住射击键 60 帧（准星固定在假人上）再松手 20 帧，检查：原版攻击没有漏出（眼泪 / 激光 / 跟班射击）、飞剑出剑且命中、
    -- 射击权限关闭、没有残留可见的原版刀实体；然后移除道具进入下一个。日志里的 Lua 报错由测试脚本统一计为失败
    local ITEM_SWEEP = {
        "TECHNOLOGY", "TECHNOLOGY_2", "TECH_X", "TECH_5", "TECHNOLOGY_ZERO", "BRIMSTONE", "MAW_OF_THE_VOID", "REVELATION",
        "LUDOVICO_TECHNIQUE", "MOMS_KNIFE", "SPIRIT_SWORD", "DR_FETUS", "EPIC_FETUS", "IPECAC", "C_SECTION",
        "CHOCOLATE_MILK", "CURSED_EYE", "MONSTROS_LUNG", "MARKED", "EYE_OF_THE_OCCULT", "SOY_MILK", "ALMOND_MILK",
        "NEPTUNUS", "HAEMOLACRIA", "TRISAGION", "GODHEAD", "TINY_PLANET", "ANTI_GRAVITY", "EVIL_EYE", "LEAD_PENCIL",
        "20_20", "INNER_EYE", "MUTANT_SPIDER", "THE_WIZ", "LOKIS_HORNS", "MOMS_EYE", "EYE_SORE", "KIDNEY_STONE",
        "FIRE_MIND", "CONTINUUM", "JACOBS_LADDER", "HOLY_LIGHT", "DEAD_EYE", "EUTHANASIA", "TERRA", "ROCK_BOTTOM",
        "BONE_SPURS", "COMPOUND_FRACTURE", "PARASITE", "CRICKETS_BODY", "TOUGH_LOVE", "APPLE", "BACKSTABBER",
        "CHEMICAL_PEEL", "PSY_FLY", "SINUS_INFECTION", "EYE_OF_BELIAL", "GHOST_PEPPER", "BIRDS_EYE",
        "MONSTRANCE", "STAPLER", "LACHRYPHAGY", "TRACTOR_BEAM", "STRANGE_ATTRACTOR", "BRIMSTONE_BOMBS",
    }
    local itemTests = {}
    local sweepOnly = nil -- -Only 传道具名（逗号分隔，如 TRACTOR_BEAM,TECH_X）时只扫这些
    itemTests[1] = { name = "攻击类道具扫描", fn = function()
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
        waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        local p = player()
        p:AddCollectible(api.item)
        wait(10)
        local st = api.getState(p)
        local home = p.Position
        local pos = home + Vector(120, 0)
        watched = p
        local problems = {}
        local list = ITEM_SWEEP
        if sweepOnly and sweepOnly:match("%a") then
            list = {}
            for n in sweepOnly:gmatch("[%w_]+") do
                list[#list + 1] = n
            end
        end
        for _, name in ipairs(list) do
            local item = CollectibleType["COLLECTIBLE_" .. name]
            if not item then
                log("SKIP 道具 " .. name .. "：枚举里没有")
            else
                clearRoom()
                p.Position = home
                p:AddCollectible(item)
                wait(5)
                local dummy = spawnDummy(pos)
                local seen, swords = {}, 0
                damageLog, nativeAttacks, familiarShots, electricArcs, needleBursts = {}, 0, 0, 0, 0
                -- 小行星：飞剑绕角色转（半径 60），假人放在绕圈范围内
                local itemPos = name == "TINY_PLANET" and (home + Vector(C.TINY_PLANET_RADIUS, 0)) or pos
                dummy.Position = itemPos
                local visibleKnives, strayLasers = 0, 0
                for f = 1, 80 do
                    simNative = f <= 60 and Vector(1, 0) or nil
                    p.Position, p.Velocity = home, Vector.Zero
                    p:SetMinDamageCooldown(60)
                    if dummy:Exists() then
                        dummy.Position, dummy.Velocity = itemPos, Vector.Zero
                    end
                    local target = st.crosshair
                    if not (target and target:Exists()) then
                        target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, pos, Vector.Zero, p):ToEffect()
                        st.crosshair = target
                    end
                    target.Position, target.Velocity = pos, Vector.Zero
                    for _, s in ipairs(st.swords) do
                        if not seen[s] then
                            seen[s] = true
                            swords = swords + 1
                        end
                    end
                    if f == 40 then
                        for _, k in ipairs(Isaac.FindByType(EntityType.ENTITY_KNIFE)) do
                            if k.Visible then
                                visibleKnives = visibleKnives + 1
                            end
                        end
                        for _, l in ipairs(Isaac.FindByType(EntityType.ENTITY_LASER)) do
                            -- 隐藏的不算（牵引光束的引导光束被隐藏，不造成伤害）
                            if not l:GetData().ZenithOwned and l.Visible and l.Variant ~= LaserVariant.ELECTRIC then
                                strayLasers = strayLasers + 1
                            end
                        end
                    end
                    wait(1)
                end
                simNative = nil
                local hits = #damageTo(dummy)
                damageLog = nil
                local issues = {}
                if p:CanShoot() then issues[#issues + 1] = "射击权限没关" end
                if swords == 0 then issues[#issues + 1] = "没有出剑" end
                if hits == 0 then issues[#issues + 1] = "没有命中" end
                if nativeAttacks > 0 then issues[#issues + 1] = "原版攻击漏出 " .. nativeAttacks end
                if familiarShots > 0 then issues[#issues + 1] = "跟班射击 " .. familiarShots end
                if visibleKnives > 0 then issues[#issues + 1] = "可见的原版刀 " .. visibleKnives end
                if strayLasers > 0 then issues[#issues + 1] = "原版激光 " .. strayLasers end
                local detail = string.format("出剑 %d，命中 %d，原生 %d，跟班 %d，刀 %d，激光 %d，电弧 %d，针 %d", swords, hits, nativeAttacks, familiarShots, visibleKnives, strayLasers, electricArcs, needleBursts)
                check("道具 " .. name .. "：兼容", #issues == 0, #issues == 0 and detail or (table.concat(issues, "；") .. "（" .. detail .. "）"))
                if #issues > 0 then
                    problems[#problems + 1] = name
                end
                dummy:Remove()
                p:RemoveCollectible(item)
                for _, e in ipairs(Isaac.GetRoomEntities()) do
                    if e.Type == EntityType.ENTITY_LASER or e.Type == EntityType.ENTITY_KNIFE then
                        e:Remove()
                    end
                end
                wait(10)
            end
        end
        watched = nil
        log("ITEMS 有问题的道具：" .. (#problems > 0 and table.concat(problems, "、") or "无"))
    end }

    -- 空跑（-Suite idle）：开一局后什么都不做，留 2 分钟给外部脚本模拟按键（例如控制台输入）
    local idleTests = {}
    idleTests[1] = { name = "空跑", fn = function()
        wait(30)
        log("IDLE READY")
        wait(3600)
        check("空跑结束", true)
    end }

    -- 特殊角色（-Suite special）：遗骸与灵魂切换、里遗骸的本体与灵魂、里拉撒路翻转、雅各和以扫都拿剑、伯大尼的魂火。
    -- 每项重开一局，检查切换 / 翻转后谁持有天顶剑、谁出剑、准星有几个、原生攻击是否关闭、失去后能否恢复
    local specialTests = {}
    local function special(id, name, fn)
        specialTests[#specialTests + 1] = { id = id, name = name, fn = fn }
    end

    local function restartAs(id)
        gameStarted = false
        Isaac.ExecuteCommand("restart " .. id)
        local ok = waitUntil(function() return gameStarted end, 300)
        wait(30)
        clearRoom()
        return ok
    end

    -- 所有角色实体，包括遗骸不活动的另一半（GetSubPlayer）和里拉撒路的另一形态（GetFlippedForm）
    local function everyPlayer()
        local out, seen = {}, {}
        local function add(p)
            if p and not seen[GetPtrHash(p)] then
                seen[GetPtrHash(p)] = true
                out[#out + 1] = p
            end
        end
        for i = 0, Game():GetNumPlayers() - 1 do
            local p = Isaac.GetPlayer(i)
            add(p)
            local ok, sub = pcall(p.GetSubPlayer, p)
            if ok then
                add(sub)
            end
            local ok2, flipped = pcall(p.GetFlippedForm, p)
            if ok2 then
                add(flipped)
            end
        end
        return out
    end

    local function describePlayers()
        local parts = {}
        for _, p in ipairs(everyPlayer()) do
            local st = p:GetData().Zenith
            parts[#parts + 1] = string.format("%d %s[有剑=%s 状态=%s 飞剑=%d CanShoot=%s]", p:GetPlayerType(), p:GetName(),
                tostring(p:HasCollectible(api.item)), tostring(st ~= nil), st and #st.swords or 0, tostring(p:CanShoot()))
        end
        return table.concat(parts, "；")
    end

    local function countEffects(variant)
        local n = 0
        for _, e in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, variant)) do
            if e:Exists() then
                n = n + 1
            end
        end
        return n
    end

    -- players 里每个角色同时把准星固定在自己右侧的敌人上攻击 frames 帧（期间模拟按住射击键），
    -- 返回每个角色的出剑数 / 敌人被命中次数，以及原生攻击数、跟班射击数
    local function attack(players, frames)
        local entries = {}
        for _, p in ipairs(players) do
            local home = p.Position
            local pos = home + Vector(120, 0)
            entries[#entries + 1] = { p = p, home = home, pos = pos, dummy = spawnDummy(pos), seen = {}, n = 0 }
        end
        damageLog, nativeAttacks, familiarShots = {}, 0, 0
        simNative = Vector(1, 0)
        for _ = 1, frames do
            for _, en in ipairs(entries) do
                en.p.Position, en.p.Velocity = en.home, Vector.Zero
                if en.dummy:Exists() then
                    en.dummy.Position, en.dummy.Velocity = en.pos, Vector.Zero
                end
                local st = en.p:GetData().Zenith
                if st then
                    local target = st.crosshair
                    if not (target and target:Exists()) then
                        target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, en.pos, Vector.Zero, en.p):ToEffect()
                        st.crosshair = target
                    end
                    target.Position, target.Velocity = en.pos, Vector.Zero
                    for _, s in ipairs(st.swords) do
                        if not en.seen[s] then
                            en.seen[s] = true
                            en.n = en.n + 1
                        end
                    end
                end
            end
            wait(1)
        end
        simNative = nil
        for _ = 1, 20 do
            for _, en in ipairs(entries) do
                en.p.Position, en.p.Velocity = en.home, Vector.Zero
            end
            wait(1)
        end
        for _, en in ipairs(entries) do
            en.hits = #damageTo(en.dummy)
            en.dummy:Remove()
        end
        damageLog = nil
        return entries, nativeAttacks, familiarShots
    end

    local function nativeControl(p, frames)
        nativeAttacks, familiarShots = 0, 0
        pressFire(p, p.Position, frames or 45, 20)
        return nativeAttacks, familiarShots
    end

    -- 除 holders 以外的角色实体都不应留有飞剑
    local function othersIdle(holders)
        local busy = {}
        for _, p in ipairs(everyPlayer()) do
            local isHolder = false
            for _, h in ipairs(holders) do
                isHolder = isHolder or GetPtrHash(h) == GetPtrHash(p)
            end
            local st = p:GetData().Zenith
            if not isHolder and st and #st.swords > 0 then
                busy[#busy + 1] = p:GetPlayerType() .. ":" .. #st.swords
            end
        end
        return #busy == 0, table.concat(busy, ",")
    end

    special(16, "遗骸与灵魂切换", function()
        if not restartAs(PlayerType.PLAYER_THEFORGOTTEN) then
            check("重开遗骸", false, "超时")
            return
        end
        local p = player()
        local hash0 = GetPtrHash(p)
        local function swap()
            local ok, err = pcall(function() p:SwapForgottenForm(true, true) end)
            wait(15)
            p = player()
            return ok, err
        end
        local ok, err = swap()
        check("切换到灵魂", ok and p:GetPlayerType() == PlayerType.PLAYER_THESOUL,
            ok and string.format("当前角色 %d，同一实体 %s", p:GetPlayerType(), tostring(GetPtrHash(p) == hash0)) or tostring(err))
        if not ok then
            return
        end
        local control = nativeControl(p)
        log("SPECIAL 灵魂对照：原生攻击 " .. control)
        swap()
        p:AddCollectible(api.item)
        wait(5)
        log("SPECIAL 遗骸拿剑后：" .. describePlayers())
        local cycle0 = p:GetData().Zenith.cycle
        local e, native = attack({ p }, 60)
        local forgottenCycles, forgottenDelay = p:GetData().Zenith.cycle - cycle0, p.MaxFireDelay
        check("遗骸：出剑并命中", e[1].n > 0 and e[1].hits > 0, string.format("出剑 %d，命中 %d", e[1].n, e[1].hits))
        check("遗骸：射击权限关闭", p:CanShoot() == false)

        swap()
        log(string.format("SPECIAL 切到灵魂后：%s；准星 %d，渲染器 %d", describePlayers(), countEffects(api.crosshair), countEffects(api.renderer)))
        check("灵魂：仍持有天顶剑", p:HasCollectible(api.item))
        check("灵魂：射击权限关闭", p:CanShoot() == false)
        cycle0 = p:GetData().Zenith.cycle
        e, native = attack({ p }, 60)
        local soulCycles = p:GetData().Zenith.cycle - cycle0
        -- 遗骸骨棒的射速惩罚已补回：同样的道具下，遗骸和灵魂的出剑次数应该相同
        check("遗骸的出剑频率与灵魂相同（骨棒射速惩罚已补回）", forgottenCycles > 0 and math.abs(forgottenCycles - soulCycles) <= 2,
            string.format("遗骸 %d 次（MaxFireDelay %.1f），灵魂 %d 次（MaxFireDelay %.1f）", forgottenCycles, forgottenDelay, soulCycles, p.MaxFireDelay))
        check("灵魂：出剑并命中", e[1].n > 0 and e[1].hits > 0, string.format("出剑 %d，命中 %d", e[1].n, e[1].hits))
        check("灵魂：原生眼泪不再发射", native == 0, string.format("对照 %d，拿剑后 %d", control, native))
        check("灵魂：场上只有 1 个准星", countEffects(api.crosshair) <= 1, "准星 " .. countEffects(api.crosshair))
        local idle, busy = othersIdle({ p })
        check("灵魂：不活动的遗骸本体没有飞剑", idle, busy)

        swap()
        log("SPECIAL 切回遗骸后：" .. describePlayers())
        check("切回遗骸：仍能出剑", (function()
            local e2 = attack({ p }, 45)
            return e2[1].n > 0
        end)())
        check("切回遗骸：场上只有 1 个准星", countEffects(api.crosshair) <= 1, "准星 " .. countEffects(api.crosshair))

        -- 在灵魂形态失去天顶剑，两种形态的射击权限都要恢复
        swap()
        p:RemoveCollectible(api.item)
        wait(5)
        check("灵魂：失去天顶剑后射击权限恢复", p:CanShoot() == true)
        if control > 0 then
            check("灵魂：失去天顶剑后原生眼泪恢复", nativeControl(p) > 0)
        end
        swap()
        log("SPECIAL 失去后切回遗骸：" .. describePlayers())
        check("遗骸：失去天顶剑后射击权限恢复", p:CanShoot() == characterCanShoot(p),
            string.format("CanShoot=%s，角色设定=%s", tostring(p:CanShoot()), tostring(characterCanShoot(p))))
        check("失去后准星全部删除", countEffects(api.crosshair) == 0)
    end)

    special(35, "里遗骸的本体与灵魂", function()
        if not restartAs(PlayerType.PLAYER_THEFORGOTTEN_B) then
            check("重开里遗骸", false, "超时")
            return
        end
        log("SPECIAL 里遗骸开局：" .. describePlayers())
        local body = findPlayerOfType(PlayerType.PLAYER_THEFORGOTTEN_B)
        local soul = findPlayerOfType(PlayerType.PLAYER_THESOUL_B)
        if not (body and soul) then
            check("找到本体和灵魂", false, describePlayers())
            return
        end
        -- 和实际游戏一样由灵魂去碰道具底座
        local pedestal = Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE, api.item, center() + Vector(0, 80), Vector.Zero, nil)
        for _ = 1, 60 do
            if pedestal:Exists() then
                soul.Position, soul.Velocity = pedestal.Position, Vector.Zero
            end
            wait(1)
        end
        wait(30)
        log("SPECIAL 灵魂碰道具后：" .. describePlayers())
        local holders = {}
        for _, q in ipairs(everyPlayer()) do
            if q:HasCollectible(api.item) then
                holders[#holders + 1] = q
            end
        end
        check("里遗骸：拾取后有人持有天顶剑", #holders > 0, describePlayers())
        if #holders == 0 then
            return
        end
        local e, native, famShots = attack(holders, 60)
        local total, hits, desc = 0, 0, {}
        for _, en in ipairs(e) do
            total, hits = total + en.n, hits + en.hits
            desc[#desc + 1] = string.format("%d 出剑 %d", en.p:GetPlayerType(), en.n)
        end
        log(string.format("SPECIAL 里遗骸出剑：%s，命中 %d，原生攻击 %d，跟班射击 %d，准星 %d", table.concat(desc, "，"), hits,
            native, famShots, countEffects(api.crosshair)))
        check("里遗骸：出剑并命中", total > 0 and hits > 0, table.concat(desc, "，") .. "，命中 " .. hits)
        check("里遗骸：准星数 = 持有者数", countEffects(api.crosshair) == #holders,
            string.format("准星 %d，持有者 %d", countEffects(api.crosshair), #holders))
        for _, q in ipairs(holders) do
            q:RemoveCollectible(api.item)
        end
        wait(5)
        log("SPECIAL 里遗骸失去后：" .. describePlayers())
        for _, q in ipairs(everyPlayer()) do
            check(string.format("里遗骸：失去后角色 %d 射击权限恢复", q:GetPlayerType()), q:CanShoot() == characterCanShoot(q),
                string.format("CanShoot=%s，角色设定=%s", tostring(q:CanShoot()), tostring(characterCanShoot(q))))
        end
        check("里遗骸：失去后准星全部删除", countEffects(api.crosshair) == 0)
    end)

    special(29, "里拉撒路翻转", function()
        if not restartAs(PlayerType.PLAYER_LAZARUS_B) then
            check("重开里拉撒路", false, "超时")
            return
        end
        local p = player()
        local hash0 = GetPtrHash(p)
        -- 和实际游戏一样碰道具底座拾取（看另一形态会不会同时得到）
        local pedestal = Isaac.Spawn(EntityType.ENTITY_PICKUP, PickupVariant.PICKUP_COLLECTIBLE, api.item, center() + Vector(0, 80), Vector.Zero, nil)
        for _ = 1, 60 do
            if pedestal:Exists() then
                p.Position, p.Velocity = pedestal.Position, Vector.Zero
            end
            wait(1)
        end
        wait(30)
        p.Position = center()
        log("SPECIAL 里拉撒路拾取后：" .. describePlayers())
        check("里拉撒路：拾取到天顶剑", p:HasCollectible(api.item))
        local e = attack({ p }, 45)
        check("里拉撒路：出剑并命中", e[1].n > 0 and e[1].hits > 0, string.format("出剑 %d，命中 %d", e[1].n, e[1].hits))
        local function flip()
            local ok, err = pcall(function() p:UseActiveItem(CollectibleType.COLLECTIBLE_FLIP, UseFlag.USE_NOANIM) end)
            wait(30)
            p = player()
            return ok, err
        end
        local ok, err = flip()
        log(string.format("SPECIAL 翻转后：角色 %d，同一实体 %s；%s；准星 %d，渲染器 %d", p:GetPlayerType(),
            tostring(GetPtrHash(p) == hash0), describePlayers(), countEffects(api.crosshair), countEffects(api.renderer)))
        check("翻转成功", ok and p:GetPlayerType() == PlayerType.PLAYER_LAZARUS2_B, ok and ("当前角色 " .. p:GetPlayerType()) or tostring(err))
        if p:HasCollectible(api.item) then
            local e2, native = attack({ p }, 45)
            check("翻转后：出剑并命中", e2[1].n > 0 and e2[1].hits > 0, string.format("出剑 %d，命中 %d", e2[1].n, e2[1].hits))
            check("翻转后：没有原生攻击", native == 0, "原生攻击 " .. native)
            check("翻转后：射击权限关闭", p:CanShoot() == false)
        else
            check("翻转后的形态没拿剑：射击权限正常", p:CanShoot() == characterCanShoot(p))
            check("翻转后的形态没拿剑：原生攻击正常", nativeControl(p) > 0)
        end
        check("翻转后：准星不超过 1 个", countEffects(api.crosshair) <= 1, "准星 " .. countEffects(api.crosshair))
        local idle, busy = othersIdle({ p })
        check("翻转后：另一形态没有飞剑", idle, busy)

        flip()
        log("SPECIAL 翻转回来：" .. describePlayers() .. "；准星 " .. countEffects(api.crosshair))
        check("翻转回来：仍持有天顶剑", p:HasCollectible(api.item))
        local e3 = attack({ p }, 45)
        check("翻转回来：出剑并命中", e3[1].n > 0 and e3[1].hits > 0, string.format("出剑 %d，命中 %d", e3[1].n, e3[1].hits))
        check("翻转回来：准星不超过 1 个", countEffects(api.crosshair) <= 1, "准星 " .. countEffects(api.crosshair))
        p:RemoveCollectible(api.item)
        wait(5)
        check("里拉撒路：失去后射击权限恢复", p:CanShoot() == true)
        check("里拉撒路：失去后原生攻击恢复", nativeControl(p) > 0)
        flip()
        log("SPECIAL 失去后翻转：" .. describePlayers())
        check("失去后翻转：射击权限正常", p:CanShoot() == characterCanShoot(p))
        check("失去后翻转：准星全部删除", countEffects(api.crosshair) == 0)
    end)

    -- 被塞壬魅惑的 Incubus 不再替角色出剑，魅惑结束后恢复（实测魅惑约 250 帧内发生，持续数百帧后自行结束）
    special(904, "塞壬魅惑跟班", function()
        if not restartAs(PlayerType.PLAYER_ISAAC) then
            check("重开以撒", false, "超时")
            return
        end
        local p = player()
        p:AddCollectible(CollectibleType.COLLECTIBLE_INCUBUS)
        p:AddCollectible(api.item)
        wait(10)
        local incubus = familiarsOf(INCUBUS)[1]
        incubus = incubus and incubus:ToFamiliar()
        if not incubus then
            check("找到 Incubus", false)
            return
        end
        local siren = Isaac.Spawn(EntityType.ENTITY_SIREN, 0, 0, center() + Vector(0, -100), Vector.Zero, nil)
        local st = api.getState(p)
        -- 准星固定在角色右侧，持续 frames 帧或直到 stop() 成立；返回期间 Incubus 新出的剑数
        local function run(frames, stop)
            local seen, n = {}, 0
            for _, s in ipairs(st.swords) do -- 开始前就在飞的剑不算
                seen[s] = true
            end
            for _ = 1, frames do
                p:SetMinDamageCooldown(60)
                if siren:Exists() then
                    siren.HitPoints = siren.MaxHitPoints
                end
                local target = st.crosshair
                if not (target and target:Exists()) then
                    target = Isaac.Spawn(EntityType.ENTITY_EFFECT, api.crosshair, 0, p.Position + Vector(80, 0), Vector.Zero, p):ToEffect()
                    st.crosshair = target
                end
                target.Position, target.Velocity = p.Position + Vector(80, 0), Vector.Zero
                for _, s in ipairs(st.swords) do
                    if not seen[s] then
                        seen[s] = true
                        if s.anchor and GetPtrHash(s.anchor) == GetPtrHash(incubus) then
                            n = n + 1
                        end
                    end
                end
                if stop and stop() then
                    break
                end
                wait(1)
            end
            return n
        end
        local before = run(60)
        check("魅惑前：Incubus 出剑", before > 0, before .. " 把")
        run(2400, function() return incubus:IsCharmed() end) -- 塞壬什么时候唱歌是随机的，偶尔 1200 帧内不魅惑
        check("塞壬魅惑了 Incubus", incubus:IsCharmed())
        if not incubus:IsCharmed() then
            siren:Remove()
            return
        end
        wait(2)
        local during = run(60, function() return not incubus:IsCharmed() end)
        check("魅惑期间：Incubus 不出剑", during == 0, during .. " 把")
        run(1500, function() return not incubus:IsCharmed() end)
        check("魅惑自行结束", not incubus:IsCharmed())
        local after = run(60)
        check("魅惑结束后：Incubus 恢复出剑", after > 0, after .. " 把")
        siren:Remove()
    end)

    special(19, "雅各和以扫都拿天顶剑", function()
        if not restartAs(PlayerType.PLAYER_JACOB) then
            check("重开雅各和以扫", false, "超时")
            return
        end
        local jacob, esau = findPlayerOfType(PlayerType.PLAYER_JACOB), findPlayerOfType(PlayerType.PLAYER_ESAU)
        if not (jacob and esau) then
            check("找到雅各和以扫", false, describePlayers())
            return
        end
        jacob:AddCollectible(api.item)
        esau:AddCollectible(api.item)
        wait(5)
        local e, native = attack({ jacob, esau }, 60)
        check("雅各：出剑", e[1].n > 0, "出剑 " .. e[1].n)
        check("以扫：出剑", e[2].n > 0, "出剑 " .. e[2].n)
        check("两人的剑都命中", e[1].hits > 0 and e[2].hits > 0, string.format("命中 %d / %d", e[1].hits, e[2].hits))
        check("两人都没有原生攻击", native == 0, "原生攻击 " .. native)
        check("两人射击权限都关闭", jacob:CanShoot() == false and esau:CanShoot() == false)

        -- 射击键同时推动两人各自的准星：先收起准星，再模拟按住右射击键
        for _, q in ipairs({ jacob, esau }) do
            Crosshair.Remove(q:GetData().Zenith)
        end
        wait(2)
        for _, q in ipairs({ jacob, esau }) do
            q:GetData().Zenith.testInput = Vector(1, 0)
        end
        wait(12)
        for _, q in ipairs({ jacob, esau }) do
            q:GetData().Zenith.testInput = nil
        end
        local function ownCrosshair(q)
            local t = q:GetData().Zenith.crosshair
            return t and t:Exists() and t.SpawnerEntity and GetPtrHash(t.SpawnerEntity) == GetPtrHash(q) and t.Position.X > q.Position.X + 20
        end
        check("按射击键后两人各有自己的准星", ownCrosshair(jacob) and ownCrosshair(esau), "准星 " .. countEffects(api.crosshair))
        check("场上正好 2 个准星", countEffects(api.crosshair) == 2, "准星 " .. countEffects(api.crosshair))

        jacob:RemoveCollectible(api.item)
        wait(5)
        check("雅各失去后：雅各射击权限恢复", jacob:CanShoot() == true)
        check("雅各失去后：以扫仍拿着剑", esau:CanShoot() == false and esau:GetData().Zenith ~= nil)
        check("雅各失去后：只剩以扫的准星", countEffects(api.crosshair) == 1, "准星 " .. countEffects(api.crosshair))
        local e2 = attack({ esau }, 45)
        check("雅各失去后：以扫仍能出剑", e2[1].n > 0, "出剑 " .. e2[1].n)
        esau:RemoveCollectible(api.item)
        wait(5)
        check("两人都失去后：射击权限恢复", jacob:CanShoot() == true and esau:CanShoot() == true)
        check("两人都失去后：准星全部删除", countEffects(api.crosshair) == 0)
    end)

    -- 伯大尼（美德之书的魂火）和里伯大尼（所罗门魔典的道具魂火）：先不拿剑测魂火会不会跟着射击，再拿剑对比
    local function wispTest(id, items, tag)
        if not restartAs(id) then
            check(tag .. "：重开", false, "超时")
            return
        end
        local p = player()
        -- 直接生成魂火（UseActiveItem 带 USE_NOANIM 时实测不生成）：伯大尼生成普通魂火，里伯大尼生成道具魂火
        for _, item in ipairs(items) do
            local ok, err = pcall(function()
                if id == PlayerType.PLAYER_BETHANY_B then
                    p:AddItemWisp(item, p.Position)
                else
                    p:AddWisp(item, p.Position)
                end
            end)
            if not ok then
                log("SPECIAL 生成魂火失败：" .. tostring(err))
            end
        end
        wait(30)
        local wisps = familiarsOf(id == PlayerType.PLAYER_BETHANY_B and FamiliarVariant.ITEM_WISP or FamiliarVariant.WISP)
        local subtypes = {}
        for _, w in ipairs(wisps) do
            subtypes[#subtypes + 1] = tostring(w.SubType)
        end
        log(string.format("SPECIAL %s：魂火 %d 个（子类型 %s）", tag, #wisps, table.concat(subtypes, ",")))
        local cNative, cFam = nativeControl(p, 60)
        log(string.format("SPECIAL %s 对照：原生攻击 %d，跟班射击 %d", tag, cNative, cFam))
        p:AddCollectible(api.item)
        wait(5)
        local e, native, famShots = attack({ p }, 60)
        log(string.format("SPECIAL %s 拿剑后：出剑 %d，命中 %d，原生攻击 %d，跟班射击 %d", tag, e[1].n, e[1].hits, native, famShots))
        check(tag .. "：出剑并命中", e[1].n > 0 and e[1].hits > 0, string.format("出剑 %d，命中 %d", e[1].n, e[1].hits))
        check(tag .. "：本人没有原生攻击", native == 0, string.format("对照 %d，拿剑后 %d", cNative, native))
        -- 魂火和普通跟班一样保留原版眼泪（用户决定，不照搬角色攻击，伤害固定）
        if cFam > 0 then
            check(tag .. "：魂火照常发射原版眼泪", famShots > 0, string.format("对照 %d，拿剑后 %d", cFam, famShots))
        end
        p:RemoveCollectible(api.item)
        wait(5)
        check(tag .. "：失去后射击权限恢复", p:CanShoot() == true)
        local rNative, rFam = nativeControl(p, 60)
        check(tag .. "：失去后原生攻击恢复", cNative == 0 or rNative > 0, "原生攻击 " .. rNative)
        if cFam > 0 then
            check(tag .. "：失去后魂火照常射击", rFam > 0, "跟班射击 " .. rFam)
        end
    end
    special(18, "伯大尼的魂火", function()
        -- 美德之书、美味的心、钉子的魂火：普通魂火会跟着角色射击
        wispTest(PlayerType.PLAYER_BETHANY, { CollectibleType.COLLECTIBLE_BOOK_OF_VIRTUES, CollectibleType.COLLECTIBLE_BOOK_OF_VIRTUES,
            CollectibleType.COLLECTIBLE_YUM_HEART, CollectibleType.COLLECTIBLE_THE_NAIL }, "伯大尼")
    end)
    special(36, "里伯大尼的道具魂火", function()
        -- 道具魂火：硫磺火、科技、天蝎座，看会不会跟着射击
        wispTest(PlayerType.PLAYER_BETHANY_B, { CollectibleType.COLLECTIBLE_BRIMSTONE, CollectibleType.COLLECTIBLE_TECHNOLOGY,
            CollectibleType.COLLECTIBLE_SCORPIO }, "里伯大尼")
    end)

    -- 全部（-Suite all）：一次启动依次跑常规、全角色、特殊角色、联动、道具扫描（省掉每个套件单独开关游戏的时间）。
    -- 每个套件前重开一局以撒，保证起始状态干净；联动第 11 项只是 DPS 实测（不判定），不放进来
    local function freshRun(name)
        return { name = "（重开一局，开始：" .. name .. "）", fn = function()
            gameStarted = false
            Isaac.ExecuteCommand("restart " .. PlayerType.PLAYER_ISAAC)
            check("重开一局（" .. name .. "）", waitUntil(function() return gameStarted end, 300))
            wait(30)
            clearRoom()
        end }
    end
    local allTests = {}
    for _, part in ipairs({ { "常规", tests }, { "全角色", charTests }, { "特殊角色", specialTests }, { "联动", weaponTests }, { "道具扫描", itemTests } }) do
        allTests[#allTests + 1] = freshRun(part[1])
        for _, t in ipairs(part[2]) do
            if not (part[2] == weaponTests and (t.id == 11 or t.id == 22 or t.id == 24)) then
                allTests[#allTests + 1] = { name = t.name, fn = t.fn }
            end
        end
    end

    local SUITES = { all = allTests, default = tests, characters = charTests, probe_clots = probeTests, probe_rates = rateTests, stress = stressTests, repro = reproTests, special = specialTests, probe_b = probeB, repro_give = reproGive, idle = idleTests, weapons = weaponTests, items = itemTests }

    -- 只跑指定角色：only 为逗号分隔的角色编号（如 "13,19"），只对角色扫描有效
    local function filterSuite(list, only)
        if not only or only == "" then
            return list
        end
        local want, out = {}, {}
        for n in tostring(only):gmatch("%d+") do
            want[tonumber(n)] = true
        end
        for _, t in ipairs(list) do
            if t.id == nil or want[t.id] then
                out[#out + 1] = t
            end
        end
        return out
    end

    -- 原生攻击计数：角色发射的眼泪 / 激光，跟班发射的眼泪 / 激光（每个只数一次）
    local function countShot(e)
        local data = e:GetData()
        if data.ZenithTestCounted then
            return
        end
        data.ZenithTestCounted = true
        if data.ZenithOwned then -- 攻击类道具联动生成的激光（weapons.lua），不是原生攻击
            return
        end
        -- 雅各的梯子的电弧（激光变体 10）：是替身眼泪触发的原版命中效果，不是原生攻击，单独计数
        if e.Type == EntityType.ENTITY_LASER and e.Variant == LaserVariant.ELECTRIC then
            electricArcs = electricArcs + 1
            return
        end
        -- 命中效果产生的眼泪（安乐死击杀时爆出的针 / 血泪等）：出现在敌人身上、离角色很远，原生攻击出生时离角色不超过几十，
        -- 所以第 2 帧时离角色超过 60 的角色眼泪按命中效果单独计数，不算原生攻击
        if e.Type == EntityType.ENTITY_TEAR and e.SpawnerType == EntityType.ENTITY_PLAYER and watched
            and (e.Variant == TearVariant.NEEDLE or e.Position:Distance(watched.Position) > 60) then
            needleBursts = needleBursts + 1
            return
        end
        if data.ZenithShard then
            shardDamages[#shardDamages + 1] = e.CollisionDamage -- 数量在 MC_POST_TEAR_INIT 里计
            return
        end
        local spawner = e.SpawnerEntity
        local owner = spawner and (spawner:ToPlayer() or (spawner:ToFamiliar() and spawner:ToFamiliar().Player))
        if watched and not (owner and GetPtrHash(owner) == GetPtrHash(watched)) then
            return
        end
        if e.SpawnerType == EntityType.ENTITY_PLAYER then
            nativeAttacks = nativeAttacks + 1
        elseif e.SpawnerType == EntityType.ENTITY_FAMILIAR then
            familiarShots = familiarShots + 1
        else
            return
        end
        if shotLog > 0 then
            shotLog = shotLog - 1
            local nearest, nearestDist = "无", math.huge
            for _, fam in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR)) do
                local d = fam.Position:Distance(e.Position)
                if d < nearestDist then
                    nearest, nearestDist = tostring(fam.Variant), d
                end
            end
            log(string.format("SHOT %s 变体 %d，生成者 %d.%d，最近的跟班 %s（距离 %.0f），离角色 %.0f",
                e.Type == EntityType.ENTITY_LASER and "激光" or "眼泪", e.Variant, e.SpawnerType, e.SpawnerVariant,
                nearest, nearestDist, watched and watched.Position:Distance(e.Position) or -1))
        end
    end
    -- 骨片生成时角色数据上带 ZenithSpawningOwn 标记（tearflags.lua BoneShards），在出生时计数：
    -- 骨片撞到敌人当帧就可能消失，等到更新回调再数会漏
    mod:AddCallback(ModCallbacks.MC_POST_TEAR_INIT, function()
        for i = 0, Game():GetNumPlayers() - 1 do
            if Isaac.GetPlayer(i):GetData().ZenithSpawningOwn then
                boneShards = boneShards + 1
                return
            end
        end
    end)
    -- 在第 2 帧计数：main.lua 会在第 0～1 帧删除跟班漏出的原生攻击，只有活过这一步的才算真正漏网
    mod:AddCallback(ModCallbacks.MC_POST_TEAR_UPDATE, function(_, tear)
        if tear.FrameCount == 2 then
            countShot(tear)
        end
    end)
    mod:AddCallback(ModCallbacks.MC_POST_LASER_UPDATE, function(_, laser)
        if laser.FrameCount == 2 then
            countShot(laser)
        end
    end)

    -- 模拟按住射击键（只给游戏自己的输入检测用；Lua 里 Input.GetActionValue 读不到这里的值）
    local SHOOT = {
        [ButtonAction.ACTION_SHOOTLEFT] = function(v) return math.max(0, -v.X) end,
        [ButtonAction.ACTION_SHOOTRIGHT] = function(v) return math.max(0, v.X) end,
        [ButtonAction.ACTION_SHOOTUP] = function(v) return math.max(0, -v.Y) end,
        [ButtonAction.ACTION_SHOOTDOWN] = function(v) return math.max(0, v.Y) end,
    }
    mod:AddCallback(ModCallbacks.MC_INPUT_ACTION, function(_, _, hook, action)
        if not simNative or not SHOOT[action] then
            return nil
        end
        local value = SHOOT[action](simNative)
        if hook == InputHook.GET_ACTION_VALUE then
            return value
        end
        return value > 0
    end)

    local function runAll(list)
        passed, failed = 0, 0
        wait(30) -- 等开局动画和房间稳定
        log("START " .. #list .. " groups")
        for _, t in ipairs(list) do
            log("== " .. t.name)
            local ok, err = pcall(t.fn)
            if not ok then
                check(t.name .. "：脚本出错", false, tostring(err))
            end
            damageLog, simNative, watched, shotLog = nil, nil, nil, 0
            local st = state()
            if st then
                st.testInput = nil
            end
        end
        log(string.format("DONE passed=%d failed=%d", passed, failed))
    end

    local function start(suite, only)
        local list = SUITES[suite or "default"]
        if not list then
            return false
        end
        list = filterSuite(list, only)
        sweepOnly = suite == "items" and only or nil
        co = coroutine.create(function() runAll(list) end)
        sleep = 0
        return true
    end

    mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
        if not co then
            return
        end
        if sleep > 0 then
            sleep = sleep - 1
            return
        end
        local ok, frames = coroutine.resume(co)
        if not ok then
            log("FAIL 测试框架出错：" .. tostring(frames))
            log(string.format("DONE passed=%d failed=%d", passed, failed + 1))
            co = nil
        elseif coroutine.status(co) == "dead" then
            co = nil
        else
            sleep = (frames or 1) - 1
        end
    end)

    mod:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, function(_, entity, amount, flags, source)
        if damageLog then
            damageLog[#damageLog + 1] = { hash = GetPtrHash(entity), amount = amount, flags = flags, srcType = source and source.Type, frame = Game():GetFrameCount() }
        end
    end)

    mod:AddCallback(ModCallbacks.MC_POST_FIRE_TEAR, function(_, tear)
        local p = tear.SpawnerEntity and tear.SpawnerEntity:ToPlayer()
        if p then
            tearsFired = tearsFired + 1
        end
    end)

    mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
        gameStarted = true
    end)

    mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, cmd, params)
        if cmd == "zenith_test" then
            local suite, only = (params or ""):match("^(%S*)%s*(.*)$")
            suite = (suite and suite ~= "") and suite or "default"
            if not start(suite, only) then
                return "Unknown suite: " .. suite .. " (default / characters)"
            end
            return "Zenith self test (" .. suite .. ") started; close the console. Results go to log.txt ([ZenithTest])."
        end
    end)

    -- 自动模式：跳过标题画面 → 在选存档界面把光标固定到指定存档 → 测试脚本在后台给游戏窗口发回车
    -- （REPENTOGON 的 MC_MENU_INPUT_ACTION 模拟确认对选存档界面无效，实测）→ 选中正确的存档后开局并运行测试
    local flag = autoRequested()
    if not flag or not REPENTOGON or not ModCallbacks.MC_MAIN_MENU_RENDER then
        return
    end
    local wantSlot = flag.slot or 2
    log("auto mode requested, save slot " .. wantSlot)
    local slotReady, slotRejected, saveMenuReported, newGameRequested, autoStarted = false, false, false, false, false
    mod:AddCallback(ModCallbacks.MC_POST_SAVESLOT_LOAD, function(_, slot, selected)
        if not selected or slotReady or slotRejected then
            return
        end
        if slot == wantSlot then
            slotReady = true
        else
            slotRejected = true
            log("WRONG SLOT selected " .. tostring(slot) .. ", expected " .. wantSlot .. "; not starting")
        end
    end)
    mod:AddCallback(ModCallbacks.MC_MAIN_MENU_RENDER, function()
        if slotRejected then
            return
        end
        if slotReady then
            if not newGameRequested then
                newGameRequested = true
                log("starting a new custom-seed run")
                Isaac.StartNewGame(PlayerType.PLAYER_ISAAC, 0, 0, AUTO_START_SEED, true)
            end
            return
        end
        pcall(function()
            local menu = MenuManager.GetActiveMenu()
            if menu == MainMenuType.TITLE then
                MenuManager.SetActiveMenu(MainMenuType.SAVES)
            elseif menu == MainMenuType.SAVES then
                SaveMenu.SetSelectedElement(wantSlot - 1)
                if not saveMenuReported then
                    saveMenuReported = true
                    log("save menu ready, selected element " .. tostring(SaveMenu.GetSelectedElement()))
                end
            end
        end)
    end)
    mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
        if newGameRequested and not autoStarted then
            autoStarted = true
            start(flag.suite, flag.only)
        end
    end)
end
