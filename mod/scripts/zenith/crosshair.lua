-- 准星：照搬原版标记 / 玄秘魔眼准星的移动方式。
-- 原版逻辑（isaac-ng.exe J273 反汇编）：
--   角色每帧：若有射击输入，输入向量长度限制到 1，准星速度 += 输入 × 8；准星不存在时在 角色位置 + 输入 × 5 处生成
--   准星每帧：摩擦系数 × 0.5，位置限制在房间内；位置积分和渲染插值由引擎完成
-- 这里同样把准星做成真正的特效实体，让引擎做积分和 60 帧插值，手感与原版一致。
-- 操作和标记一样：丢弃键收起准星，换房间后要按一次射击键才出现。

local C = include("scripts.zenith.config")
include("scripts.zenith.settings") -- 全局 ZenithSettings（准星颜色）

local Crosshair = {}

local function mouseEnabled(player)
    return player.ControllerIndex == 0 and Options ~= nil and Options.MouseControl
end

local function capLength(v, max)
    if v:Length() > max then
        return v:Resized(max)
    end
    return v
end

function Crosshair.MaxReach(player)
    return math.max(C.REACH_MIN, player.TearRange * C.REACH_MULT)
end

function Crosshair.Get(state)
    local e = state.crosshair
    if e and e:Exists() then
        return e
    end
    state.crosshair = nil
    return nil
end

-- “刚按下”只持续一个渲染帧（每秒 60 次），逻辑更新每秒只有 30 次，直接在更新里检测会漏掉约一半按键。
-- 所以每个渲染帧都检查一次，记下来留给下一次逻辑更新处理。
function Crosshair.PollDrop(player, state)
    if Input.IsActionTriggered(ButtonAction.ACTION_DROP, player.ControllerIndex) then
        state.dropPressed = true
    end
end

-- 射击输入。以下情况直接读四个射击键的原始数值（与原版 0x772030 的做法相同），镜像世界里左右对调：
--   1. 射击被天顶剑锁定（SetCanShoot(false)）时，游戏可能不再汇报射击方向
--   2. 持有标记 / 玄秘魔眼时，游戏会替角色朝它们的准星自动射击，射击方向可能被带偏
local function rawShootInput(player)
    local i = player.ControllerIndex
    local x = Input.GetActionValue(ButtonAction.ACTION_SHOOTRIGHT, i) - Input.GetActionValue(ButtonAction.ACTION_SHOOTLEFT, i)
    local y = Input.GetActionValue(ButtonAction.ACTION_SHOOTDOWN, i) - Input.GetActionValue(ButtonAction.ACTION_SHOOTUP, i)
    local ok, mirror = pcall(function() return Game():GetRoom():IsMirrorWorld() end)
    if ok and mirror then
        x = -x
    end
    return Vector(x, y)
end

function Crosshair.ShootInput(player, state)
    -- 游戏内自动测试（selftest.lua）注入的射击方向：游戏不会把 Lua 模拟的按键传给 Input.GetActionValue
    if state.testInput then
        return state.testInput
    end
    if state.shootingLocked
        or player:HasCollectible(CollectibleType.COLLECTIBLE_MARKED)
        or player:HasCollectible(CollectibleType.COLLECTIBLE_EYE_OF_THE_OCCULT) then
        return rawShootInput(player)
    end
    return player:GetShootingJoystick()
end

-- 拿着天顶剑时隐藏标记 / 玄秘魔眼自己的准星（它们的攻击方式被覆盖，属性加成由游戏照常计算）
function Crosshair.HideVanilla(player)
    local target = player:GetMarkedTarget()
    if target and target.Visible then
        target.Visible = false
    end
end

-- 准星加速度：原版固定为 8；本道具让它随弹速成长（弹速 1.0 时为基础值）
function Crosshair.Accel(player)
    local mult = 1 + (player.ShotSpeed - 1) * C.CROSSHAIR_SHOTSPEED_SCALING
    mult = math.max(C.CROSSHAIR_SPEED_MULT_MIN, math.min(C.CROSSHAIR_SPEED_MULT_MAX, mult))
    return C.CROSSHAIR_ACCEL * mult
end

-- 角色更新时调用：处理收起、生成和加速度
function Crosshair.Update(player, state, variant)
    local target = Crosshair.Get(state)

    local input
    if mouseEnabled(player) and Input.IsMouseBtnPressed(0) then
        -- 鼠标：把“准星到鼠标”的偏移当作输入，离得远时满速，接近鼠标时逐渐减速
        local from = target and target.Position or player.Position
        input = (Input.GetMousePosition(true) - from) * (1 / C.MOUSE_INPUT_DIST)
    else
        input = Crosshair.ShootInput(player, state)
    end
    -- 暂时不能攻击时（巨型蘑菇等）准星不响应按键，靠摩擦自然停下
    local firing = input:LengthSquared() > 0 and not state.suppressed

    -- 丢弃键：立即收起准星。如果射击键还按着，要等松开后重新按下才再出现，否则准星会在同一帧又生成出来
    if state.dropPressed or Input.IsActionTriggered(ButtonAction.ACTION_DROP, player.ControllerIndex) then
        state.dropPressed = false
        state.waitRelease = true
        if target then
            target:Remove()
            target = nil
            state.crosshair = nil
        end
    end
    if state.waitRelease then
        if firing then
            firing = false
        else
            state.waitRelease = false
        end
    end

    if firing then
        input = capLength(input, 1)
        if not target then
            target = Isaac.Spawn(EntityType.ENTITY_EFFECT, variant, 0,
                player.Position + input * C.CROSSHAIR_SPAWN_OFFSET, Vector.Zero, player):ToEffect()
            target.DepthOffset = -100
            state.crosshair = target
        end
        target.Velocity = target.Velocity + input * Crosshair.Accel(player)
    end

    -- 暂时不能攻击（巨型蘑菇变身等）时隐藏准星，结束后原位重新显示
    if target then
        target.Visible = not state.suppressed
    end

    state.active = target ~= nil
    state.pos = target and target.Position or nil
end

-- 失去天顶剑时删除场上的准星
function Crosshair.Remove(state)
    local target = Crosshair.Get(state)
    if target then
        target:Remove()
    end
    state.crosshair = nil
end

-- 准星特效更新后调用：摩擦、限制在房间内、限制最远距离、颜色呼吸
function Crosshair.OnEffectUpdate(effect)
    -- 保险：生成它的角色已经没有天顶剑（D4 重随、角色死亡等）时自行删除
    local owner = effect.SpawnerEntity and effect.SpawnerEntity:ToPlayer()
    if not (owner and owner:GetData().Zenith) then
        effect:Remove()
        return
    end
    effect.Friction = C.CROSSHAIR_FRICTION

    local pos = effect.Position
    local player = effect.SpawnerEntity and effect.SpawnerEntity:ToPlayer()
    if player then
        local offset = pos - player.Position
        local reach = Crosshair.MaxReach(player)
        if offset:Length() > reach then
            pos = player.Position + offset:Resized(reach)
            -- 去掉朝外的速度分量，避免贴着边界抖动
            local outward = offset:Normalized()
            local along = effect.Velocity.X * outward.X + effect.Velocity.Y * outward.Y
            if along > 0 then
                effect.Velocity = effect.Velocity - outward * along
            end
        end
    end
    effect.Position = Game():GetRoom():GetClampedPosition(pos, 0)

    local preset = ZenithSettings.CROSSHAIR_COLORS[ZenithSettings.Get("crosshairColor")]
    local c = preset and preset.rgb or C.CROSSHAIR_COLOR
    local pulse = 0.75 + 0.25 * math.sin(effect.FrameCount * 0.3)
    effect:GetSprite().Color = Color(c[1], c[2], c[3], pulse)
end

return Crosshair
