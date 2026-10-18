-- 玩家设置：画面、声音、道具池。可在模组配置菜单（按 L）里修改，随 mod 存档保存（mod:SaveData）。
-- 每个文件 include 到的表是各自独立的一份，所以设置挂在全局 ZenithSettings 上，保证所有文件读到同一份。

ZenithSettings = ZenithSettings or {}
local S = ZenithSettings

-- 天顶剑可能出现的道具池（itempools.xml 里都放了天顶剑，没开启的池在抽到时换掉，见 main.lua）。
-- key：设置里的名字；pools：对应的道具池（贪婪模式各有一份）；name：菜单里显示的名字
S.POOLS = {
    { key = "treasure", name = "宝箱房", pools = { "POOL_TREASURE", "POOL_GREED_TREASURE" } },
    { key = "shop", name = "商店", pools = { "POOL_SHOP", "POOL_GREED_SHOP" } },
    { key = "angel", name = "天使房", pools = { "POOL_ANGEL", "POOL_GREED_ANGEL" } },
    { key = "devil", name = "恶魔房", pools = { "POOL_DEVIL", "POOL_GREED_DEVIL" } },
    { key = "boss", name = "Boss 房", pools = { "POOL_BOSS", "POOL_GREED_BOSS" } },
    { key = "secret", name = "隐藏房", pools = { "POOL_SECRET", "POOL_GREED_SECRET" } },
    { key = "ultraSecret", name = "究极隐藏房", pools = { "POOL_ULTRA_SECRET" } },
    { key = "curse", name = "诅咒房", pools = { "POOL_CURSE", "POOL_GREED_CURSE" } },
    { key = "goldenChest", name = "金箱子", pools = { "POOL_GOLDEN_CHEST" } },
    { key = "redChest", name = "红箱子", pools = { "POOL_RED_CHEST" } },
}

-- 准星颜色预设
S.CROSSHAIR_COLORS = {
    { name = "浅绿", rgb = { 0.70, 1.00, 0.72 } },
    { name = "白", rgb = { 1.00, 1.00, 1.00 } },
    { name = "红", rgb = { 1.00, 0.40, 0.40 } },
    { name = "黄", rgb = { 1.00, 0.90, 0.35 } },
    { name = "蓝", rgb = { 0.45, 0.75, 1.00 } },
    { name = "紫", rgb = { 0.80, 0.55, 1.00 } },
}

-- 默认值（用户定：道具池默认天使房、恶魔房、宝箱房、商店）
S.DEFAULTS = {
    damageText = true,
    trail = true,
    glow = true,
    swingVolume = 60,
    hitVolume = 50,
    crosshairColor = 1,
    pools = { treasure = true, shop = true, angel = true, devil = true },
}

local function copy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = type(v) == "table" and copy(v) or v
    end
    return out
end

S.values = S.values or copy(S.DEFAULTS)

function S.Get(key)
    local v = S.values[key]
    if v == nil then
        return S.DEFAULTS[key]
    end
    return v
end

function S.PoolEnabled(key)
    local pools = S.values.pools or S.DEFAULTS.pools
    return pools[key] == true
end

-- 设置变化时通知（例如发光效果要立即改精灵的混合方式）
S.listeners = S.listeners or {}
function S.OnChange(fn)
    S.listeners[#S.listeners + 1] = fn
end

function S.Set(key, value)
    S.values[key] = value
    for _, fn in ipairs(S.listeners) do
        pcall(fn, key, value)
    end
    if S.mod then
        S.Save()
    end
end

function S.SetPool(key, enabled)
    S.values.pools = S.values.pools or copy(S.DEFAULTS.pools)
    S.values.pools[key] = enabled or nil
    if S.mod then
        S.Save()
    end
end

function S.Save()
    local ok, json = pcall(require, "json")
    if ok and S.mod then
        pcall(function() S.mod:SaveData(json.encode(S.values)) end)
    end
end

-- 读取存档里的设置；缺的项用默认值补上，坏掉的存档直接用默认值
function S.Load(mod)
    S.mod = mod
    local ok, json = pcall(require, "json")
    if not (ok and mod:HasData()) then
        return
    end
    local okDecode, data = pcall(function() return json.decode(mod:LoadData()) end)
    if okDecode and type(data) == "table" then
        for k, v in pairs(S.DEFAULTS) do
            if data[k] == nil or type(data[k]) ~= type(v) then
                data[k] = type(v) == "table" and copy(v) or v
            end
        end
        S.values = data
        for _, fn in ipairs(S.listeners) do
            for k, v in pairs(S.values) do
                pcall(fn, k, v)
            end
        end
    end
end

return S
