-- 模组配置菜单（Mod Config Menu，按 L 打开）里的“天顶剑”设置页。装了该菜单才注册，没装时什么都不做。
-- 两个分页：画面与声音、道具池。设置的读写和保存在 settings.lua。

local Settings = include("scripts.zenith.settings")

local CATEGORY = "天顶剑"
local registered = false

local function onOff(v)
    return v and "开" or "关"
end

local function register()
    if registered or ModConfigMenu == nil or ModConfigMenu.AddSetting == nil then
        return
    end
    registered = true
    local MCM = ModConfigMenu
    local BOOLEAN, NUMBER = MCM.OptionType.BOOLEAN, MCM.OptionType.NUMBER

    local function bool(sub, key, label, info)
        MCM.AddSetting(CATEGORY, sub, {
            Type = BOOLEAN,
            CurrentSetting = function() return Settings.Get(key) end,
            Display = function() return label .. "：" .. onOff(Settings.Get(key)) end,
            OnChange = function(v) Settings.Set(key, v) end,
            Info = { info },
        })
    end
    local function number(sub, key, label, min, max, step, format, info)
        MCM.AddSetting(CATEGORY, sub, {
            Type = NUMBER,
            CurrentSetting = function() return Settings.Get(key) end,
            Minimum = min,
            Maximum = max,
            ModifyBy = step,
            Display = function() return label .. "：" .. format(Settings.Get(key)) end,
            OnChange = function(v) Settings.Set(key, v) end,
            Info = { info },
        })
    end

    local VISUAL = "画面与声音"
    MCM.AddTitle(CATEGORY, VISUAL, "画面")
    bool(VISUAL, "damageText", "伤害数字", "飞剑命中时弹出伤害数字")
    bool(VISUAL, "trail", "拖尾", "飞剑的拖尾光带；同屏剑很多时关掉可以减轻负担")
    bool(VISUAL, "glow", "发光效果", "拖尾、星闪、粒子用叠加发光（关掉为普通混合）")
    number(VISUAL, "crosshairColor", "准星颜色", 1, #Settings.CROSSHAIR_COLORS, 1,
        function(i) return Settings.CROSSHAIR_COLORS[i] and Settings.CROSSHAIR_COLORS[i].name or "?" end, "准星的颜色")
    MCM.AddSpace(CATEGORY, VISUAL)
    MCM.AddTitle(CATEGORY, VISUAL, "声音")
    number(VISUAL, "swingVolume", "挥剑音量", 0, 100, 10, function(v) return v .. "%" end, "飞剑出手时的挥剑声")
    number(VISUAL, "hitVolume", "命中音量", 0, 100, 10, function(v) return v .. "%" end, "飞剑命中敌人时的受击声")

    local POOLS = "道具池"
    MCM.AddText(CATEGORY, POOLS, "天顶剑会出现在哪些道具池")
    for _, entry in ipairs(Settings.POOLS) do
        MCM.AddSetting(CATEGORY, POOLS, {
            Type = BOOLEAN,
            CurrentSetting = function() return Settings.PoolEnabled(entry.key) end,
            Display = function() return entry.name .. "：" .. onOff(Settings.PoolEnabled(entry.key)) end,
            OnChange = function(v) Settings.SetPool(entry.key, v) end,
            Info = { "开启后天顶剑可能出现在" .. entry.name .. "（贪婪模式同理）" },
        })
    end
end

return function(mod)
    Settings.Load(mod)
    register()
    -- 模组配置菜单比本 mod 晚加载时，开局后再注册一次
    mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, register)
    return register
end
