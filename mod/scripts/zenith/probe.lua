-- 控制台命令 zenith_give：直接给天顶剑（不用管道具编号）。
-- 调试命令 zenith_debug：把天顶剑的道具配置、角色道具历史、右侧道具栏（HistoryHUD）的内容写进 log.txt，
-- 用来排查道具图标、道具栏显示一类问题；另外记录推炸弹用到的眼泪质量和房间里炸弹的质量。
-- 只在输入控制台命令时运行，不影响正常游戏。

local C = include("scripts.zenith.config")
local Sword = include("scripts.zenith.sword")

local function logDebug(itemId)
    local out = {}
    local function add(s)
        out[#out + 1] = s
        Isaac.DebugString("[ZenithDebug] " .. s)
    end
    local cfg = Isaac.GetItemConfig():GetCollectible(itemId)
    if cfg then
        add(string.format("config id=%d name=%s hidden=%s type=%s quality=%s gfx=%s",
            itemId, tostring(cfg.Name), tostring(cfg.Hidden), tostring(cfg.Type), tostring(cfg.Quality), tostring(cfg.GfxFileName)))
    else
        add("config missing for id " .. itemId)
    end
    local player = Isaac.GetPlayer(0)
    add("player has=" .. tostring(player:HasCollectible(itemId)) .. " count=" .. player:GetCollectibleNum(itemId))
    local ok, err = pcall(function()
        local ids = {}
        for _, h in ipairs(player:GetHistory():GetCollectiblesHistory()) do
            ids[#ids + 1] = (h:IsTrinket() and "t" or "") .. h:GetItemID()
        end
        add("history: " .. table.concat(ids, ","))
        local hud = {}
        for _, h in ipairs(Game():GetHUD():GetHistoryHUD():GetCollectibles(0, nil, true)) do
            hud[#hud + 1] = h:GetItemID() .. (h:IsVisible() and "" or "(hidden)")
        end
        add("history hud: " .. table.concat(hud, ","))
    end)
    if not ok then
        add("history API unavailable: " .. tostring(err))
    end
    local okMass, mass = pcall(function() return EntityConfig.GetEntity(2, 0):GetMass() end)
    add("tear mass config=" .. tostring(okMass and mass or ("unavailable: " .. tostring(mass))) .. " used=" .. Sword.TearMass())
    for _, e in ipairs(Isaac.FindByType(C.BOMB_TYPE)) do
        add(string.format("bomb variant=%d mass=%.2f", e.Variant, e.Mass))
    end
    return table.concat(out, "\n")
end

return function(mod, getItemId)
    -- zenith_give 不在命令回调里直接加道具（实测在命令执行过程中加道具会让游戏崩溃），记下来，下一帧再加
    local pendingGives = {}
    mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
        for i = #pendingGives, 1, -1 do
            local index = table.remove(pendingGives, i)
            if index < Game():GetNumPlayers() then
                Isaac.GetPlayer(index):AddCollectible(getItemId())
            end
        end
    end)
    mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, cmd, params)
        if cmd == "zenith_debug" then
            return logDebug(getItemId())
        end
        -- zenith_give [玩家编号]：直接给天顶剑。mod 道具的编号按 mod 加载顺序分配，装了别的 mod 时不一定是 733，
        -- 用这个命令就不用管编号。玩家编号从 0 开始，默认 0（1P）
        if cmd == "zenith_give" then
            local id = getItemId()
            if id == -1 then
                return "Zenith item not loaded"
            end
            local index = tonumber(params) or 0
            if index < 0 or index >= Game():GetNumPlayers() then
                return "No player " .. index
            end
            pendingGives[#pendingGives + 1] = index
            return "Gave Zenith (item id " .. id .. ") to player " .. index
        end
    end)
end
