-- 天顶剑的全部可调数值。带“泰拉像素”的值直接照搬泰拉原版，再统一乘 PX_TO_UNIT 换算成以撒的世界单位。

return {
    -- 装了 REPENTOGON 时道具名是字符串表的键（用于中文等翻译），没装时是英文名
    ITEM_NAME_KEY = "#ZENITH_ITEM_NAME",
    ITEM_NAME = "Zenith",
    RENDERER_NAME = "Zenith Renderer",
    CROSSHAIR_NAME = "Zenith Crosshair",
    SWING_SOUND_NAME = "Zenith Swing",
    HIT_SOUND_NAME = "Zenith Hit",

    -- 单位换算
    PX_TO_UNIT = 0.5,          -- 1 泰拉像素 = 多少以撒世界单位（决定轨迹尺寸）
    SWORD_SCALE = 0.75,        -- 剑贴图绘制倍率（贴图已缩小一半；1.0 时剑偏大）
    UPDATES_PER_FRAME = 4,     -- 泰拉每秒 60 帧 × extraUpdates 2 = 120 次更新；以撒逻辑每秒 30 帧

    -- 准星：数值取自原版标记 / 玄秘魔眼准星（isaac-ng.exe J273 反汇编，见 开发计划.md）
    CROSSHAIR_ACCEL = 8,       -- 按住射击键时每帧给准星加的速度（与原版相同，输入向量长度先限制到 1）
    -- 准星速度随弹速成长（原版不受任何属性影响，这是本道具的设计）：倍率 = 1 + (弹速 - 1) × SCALING，再限制在 MIN～MAX
    CROSSHAIR_SHOTSPEED_SCALING = 1.0,
    CROSSHAIR_SPEED_MULT_MIN = 0.8,
    CROSSHAIR_SPEED_MULT_MAX = 2.5,
    CROSSHAIR_FRICTION = 0.5,  -- 准星每帧的摩擦系数（原版：特效更新里 Friction *= 0.5）
    CROSSHAIR_SPAWN_OFFSET = 5,-- 准星出现位置 = 角色位置 + 输入方向 × 5
    MOUSE_INPUT_DIST = 40,     -- 鼠标模式（未能从原版确认，近似）：准星离鼠标该距离以内时逐渐减速
    REACH_MULT = 1.5,          -- 准星离角色的最远距离 = 射程 × 该倍数（原版只限制在房间内，这是本道具的设计）
    REACH_MIN = 40,
    CROSSHAIR_COLOR = { 0.70, 1.00, 0.72 },

    -- 出剑
    FIRE_RATE_MULT = 2,        -- 每个射击间隔出几把剑（泰拉原版约每秒 6 把，以撒基础射速只有约 2.7）
    DAMAGE_MULT = 0.35,        -- 每次命中伤害 = 角色伤害 × 该倍率（所有剑相同，与原版一致）
                               -- 离线模拟：准星压在敌人身上时，一把剑约命中 5 次；按每秒约 5.5 把剑算，DPS 约为普通眼泪的 2.5 倍
    KNOCKBACK = 3,
    -- 拿到多个天顶剑：每多一个，所有飞剑（含跟班的剑、骨片、吐根爆炸）的伤害倍率 +0.8（2 个 ×1.8，3 个 ×2.6）
    STACK_DAMAGE_BONUS = 0.8,

    -- 模仿型跟班（会照搬角色攻击方式的跟班）也扔飞剑：键为跟班变体，伤害倍率取原版数值
    --   Incubus（80）：75%，莉莉丝/里莉莉丝 100%；扭曲双子（235，两只）：每只 37.5%，莉莉丝 50%；
    --   吉罗（240，里莉莉丝自带 / 道具“吉罗”）：75%，莉莉丝/里莉莉丝 100%；BFFS! 时再 ×2
    --   这些跟班自己的原生攻击在角色拿着天顶剑时会被关闭（main.lua OnMimicFamiliarUpdate），吉罗的弹出撞击保留
    --   血块（238，里夏娃的“汲血者” / 道具“小血块”）：按子类型（血块颜色）取倍率和泪弹特效，数值为游戏内实测
    --     flags：每把剑都带的泪弹标记；chance：每把剑出手时按幸运判定一次，成功则加上 flag
    --     概率为游戏内实测（各 300 发眼泪，幸运 0/10/20）：黑血块恐惧 20.1%/24.4%/24.3%，金血块点金 9.7%/12.0%/19.3%
    FAMILIAR_SWORDS = {
        [80] = { mult = 0.75, lilithMult = 1.0 },
        [235] = { mult = 0.375, lilithMult = 0.5 },
        [240] = { mult = 0.75, lilithMult = 1.0 },
        [238] = { subtypes = {
            [0] = { mult = 0.35 },                                    -- 红
            [1] = { mult = 0.35 },                                    -- 魂
            [2] = { mult = 0.4375, flags = { "TEAR_DARK_MATTER" },   -- 黑：暗物质，概率恐惧
                    chance = { flag = "TEAR_FEAR", denom = 5, denomPerLuck = -0.1, denomMin = 4 } },
            [3] = { mult = 0.525, flags = { "TEAR_HOMING" } },        -- 永恒：追踪
            [4] = { mult = 0.35,                                      -- 金：概率点金
                    chance = { flag = "TEAR_MIDAS", denom = 10, denomPerLuck = -0.25 } },
            [5] = { mult = 0.35, flags = { "TEAR_BONE" } },           -- 骨：复合骨折
            [6] = { mult = 0.35 },                                    -- 腐（眼泪带穆里根标记，但实测命中 281 次没有生成苍蝇）
            [7] = { mult = 0.35 },                                    -- 小血块（道具）
        } },
    },
    FAMILIAR_BFFS_MULT = 2,
    -- 原版不能自己攻击、只靠跟班输出的角色：本人不出剑（莉莉丝靠 Incubus，里莉莉丝靠吉罗）
    NO_OWN_SWORDS = {
        [PlayerType.PLAYER_LILITH] = true,
        [PlayerType.PLAYER_LILITH_B] = true,
    },
    FAMILIAR_SWORD_SIZE = 0.75, -- 跟班的剑比角色的小一号
    -- 角色自身攻击方式带来的射速惩罚在出剑时补回（用户决定）：遗骸、里遗骸的骨棒让射击间隔（MaxFireDelay + 1）正好翻倍
    -- （游戏内实测：以撒 11、遗骸 22；两个悲伤洋葱时 6.92、13.85）。道具带来的惩罚（硫磺火、吐根等）保留
    CHARACTER_FIRE_RATE_MULT = {
        [PlayerType.PLAYER_THEFORGOTTEN] = 2,
        [PlayerType.PLAYER_THEFORGOTTEN_B] = 2,
    },

    -- 剑的大小跟随以撒泪弹尺寸（受伤害、泪弹变大类道具影响），判定范围同步放大
    SIZE_FOLLOW_TEARS = true,
    SIZE_RESPONSE = 0.6,       -- 泪弹尺寸每变化 1，剑的大小变化多少（1 = 完全一致）
    SIZE_MIN = 0.75,
    SIZE_MAX = 1.8,
    SWING_SOUND_VOLUME = 0.6,
    SWING_SOUND_PITCH_RANDOM = 0.08, -- 每次挥剑音调随机浮动，避免连续播放太单调
    HIT_SOUND_VOLUME = 0.5,    -- 击中敌人音效（泰拉 NPC_Hit_1）
    HIT_SOUND_INTERVAL = 2,    -- 两次击中音效之间至少隔几帧，避免多把剑同时命中时叠成噪音

    -- 暴击：按“幸运类泪弹效果”计算，出剑时判定一次概率，命中时逐次判定是否暴击
    -- 暴击率 = 15% + 每点幸运 5%（17 幸运时 100%），限制在 0～100%；泪滴挂坠额外 +4 幸运（金色/妈妈的盒子每多一倍再 +2）
    CRIT_CHANCE_BASE = 0.15,
    CRIT_CHANCE_PER_LUCK = 0.05,
    TEARDROP_CHARM_LUCK = 4,
    TEARDROP_CHARM_LUCK_EXTRA = 2,
    CRIT_MULT = 2,

    -- 泪弹特效
    STATUS_DURATION = 60,      -- 中毒、燃烧、减速等状态的持续帧数（2 秒）
    -- 复合骨折（TEAR_BONE）：每把剑第一次命中敌人时碎成 1～3 块骨片，每块伤害 = 这把剑单次伤害 × 0.5（游戏内实测原版）
    BONE_SHARDS_MIN = 1,
    BONE_SHARDS_MAX = 3,
    BONE_SHARD_DAMAGE = 0.5,
    BONE_SHARD_SPEED = 10,
    BONE_SHARD_SPAWN_GAP = 12, -- 骨片生成在敌人碰撞半径外多远（骨片自身半径约 7）
    -- 穆里根：每把剑第一次命中敌人时按该概率生成 1 只蓝苍蝇。游戏内实测原版：标记不在眼泪上，命中时判定，
    --   以撒的眼泪 55/379（15%）、Incubus 的眼泪 28/191（15%），与说明的 1/6 一致。跟班的剑也生效。
    --   （里夏娃测得偏低，可能是按住射击键时造出的血块眼泪混进了命中次数，血块不触发穆里根）
    MULLIGAN_CHANCE = 1 / 6,
    -- 猫套（嗝屁猫套装）：每把剑第一次命中敌人时按该概率在角色身边生成 1 只蓝苍蝇（用户决定按每把剑判定）。
    --   游戏内实测原版：以撒的眼泪 106/164、Incubus 的眼泪 58/82，合计 164/246 = 2/3；苍蝇都生成在角色身边。跟班的剑也生效
    GUPPY_CHANCE = 2 / 3,
    -- 阶段 B 攻击类道具联动（weapons.lua）。原则：每个射击间隔里，联动部分的输出 = 原版这件武器一次射击的输出，
    -- 每个射击间隔出 FIRE_RATE_MULT（2）把剑，所以每把剑分到一半；飞剑本身的伤害另外算。原版数值均为游戏内实测（-Suite probe_b 7/8）：
    --   科技每颗 1 倍；博士胎儿炸弹 10 倍；史诗胎儿导弹 20 倍，间隔 = 51 帧 + 射击间隔（以撒 62 帧，两个悲伤洋葱 57 帧）
    -- 硫磺火（用户决定改为“血光 + 硫磺标记”，不喷激光）：剑变成血红色，命中时给敌人上原版硫磺标记；
    --   被标记的敌人受到这把剑的伤害 × BRIMSTONE_MARK_MULT。倍率按 DPS 定（-Suite probe_b 10/11/12 实测）：
    --   天顶剑持续攻击 7.46 倍角色伤害/秒，拿硫磺火后出剑只有 1/3（2.49 倍/秒）；原版硫磺火最快节奏 4.5 倍/秒；
    --   目标 = 7.46 + 4.5 = 11.96 倍/秒，需要 ×4.8，按用户“可以多一点”取 ×5（约 12.4 倍/秒）
    -- 阿撒泻勒 / 里阿撒泻勒：弱化版，倍率更低；拿到硫磺火道具也仍是弱化版（攻击方式被覆盖，不额外叠加）
    BRIMSTONE_MARK_MULT = 5,
    AZAZEL_MARK_MULT = 4,
    BRIMSTONE_MARK_DURATION = 150, -- 标记持续帧数，每次命中刷新（原版死亡传染给的标记约 150 帧）
    -- 死亡传染：原版（实测）是被标记的敌人被硫磺火打死时，周围敌人被传染标记，并各受一次 角色伤害 × 2 + 3 的伤害；
    --   这里对应为被剑打死才传染（用户决定，比较符合原版），被传染打死的继续传染
    --   （原版标记让硫磺火伤害变成 角色伤害 × 2 + 3：3.5→10、7→17、13.5→30）；120 以内传染、160 不传染，取 140
    BRIMSTONE_SPREAD_RADIUS = 140,
    BRIMSTONE_SPREAD_DAMAGE_MULT = 2,
    BRIMSTONE_SPREAD_DAMAGE_ADD = 3,
    BRIMSTONE_COLOR = { 230, 30, 30 },
    AZAZEL_COLOR = { 170, 25, 25 },
    -- 科技（用户决定）：每把剑第一次命中敌人时，从角色（跟班的剑则从跟班）身上射出一道细激光直接打向这个敌人，
    --   伤害 = 角色伤害 × TECH_DAMAGE（原版每颗 1 倍，每个射击间隔 2 把剑各分一半）
    TECH_DAMAGE = 0.5,
    TECH_TIMEOUT = 3,
    -- 第二批（用户选定方案）。原版数值实测（-Suite probe_b 17）：
    --   科技 2：射击间隔 11 → 16.5；激光每 2 帧打一次、每次 = 角色伤害 × 0.13（激光部分每秒 1.93 倍），另外照常发射眼泪
    --   科技 X：射击间隔不变；激光环每秒约 1.74 倍角色伤害（最佳蓄力节奏），每次伤害随蓄力 0.59～0.93 倍
    --   卢多维科：射击间隔不变；大眼泪压在敌人身上每 10 帧打一次、每次 1 倍（每秒 3 倍）
    -- 科技 2（方案 A）：准星显示时，从角色眼睛连一道持续的细激光到准星，激光每 2 帧打一次；
    --   每次伤害原为原版的 0.13 倍，用户要求提高到 0.2 倍
    TECH2_DAMAGE = 0.2,
    -- 科技 X（方案 B）：每把剑带着一个小激光环飞，剑飞回角色身边时环消失；环每次伤害 = 角色伤害 × TECHX_DAMAGE（生成时传入的倍率）。
    --   按“每秒环的总伤害 ≈ 原版科技 X 的 1.74 倍”调：倍率 0.23 时实测每秒 1.59 倍，按比例取 0.25
    TECHX_DAMAGE = 0.25,
    TECHX_RADIUS = 18,
    TECHX_MAX_RINGS = 40,        -- 同时存在的环最多这么多，超出的剑不带环（避免卡顿）
    -- 卢多维科（方案 B，先看效果）：飞剑不再飞向准星，而是围着准星转圈（刀尖朝外），伤害规则和普通剑相同
    LUDO_RADIUS = 45,            -- 绕圈半径（世界单位）
    LUDO_RATE = 0.5,             -- 每次更新的进度增量（普通剑 0.7～2.0），决定一把剑转多久（进度到 60 时开始淡出）
    LUDO_TURNS = 1.5,            -- 一把剑在进度 0～60 内转几圈（曾试过 ×2.25 = 3.375，实测太强，用户决定改回 1.5）
    -- 博士胎儿：剑飞到准星处（进度 PATH_END / 2）时触发
    -- 博士胎儿：每个射击间隔放一颗（FIRE_RATE_MULT 把剑里的第 1 把），伤害由游戏按原版计算（实测 10 倍）
    -- 史诗胎儿：照搬原版流程（实测）：标记计时 50 并闪烁，剩 9 时导弹从 1000 高处落下、9 帧后落地自爆（伤害由游戏按原版算，角色伤害 × 20）
    EPIC_FETUS_BASE_INTERVAL = 51, -- 导弹间隔 = 该值 + 射击间隔（MaxFireDelay + 1）
    EPIC_FETUS_TARGET_TIMEOUT = 50,
    EPIC_FETUS_FALL_FRAMES = 9,
    EPIC_FETUS_FALL_HEIGHT = 1000,
    EPIC_FETUS_BEEP_AT = 21,       -- 标记计时剩这么多时播放“滴滴”提示音（原版实测）
    -- 妈刀：每把剑有一定概率换成妈刀，每有 1 把妈刀概率 +1/5，5 把时全部是妈刀（用户决定，不写进道具介绍）。
    -- 妈刀伤害单独计算 = 角色伤害 × 6（原版满蓄力出手那一下，实测 21 = 3.5 × 6），不吃天顶剑的伤害倍率、暴击和多个天顶剑加成；
    -- 只有刀身本体判定（残影不造成伤害），每把刀对同一个敌人只造成一次伤害。跟班扔出的刀再乘跟班的倍率
    KNIFE_CHANCE_PER_ITEM = 0.2,
    KNIFE_DAMAGE_MULT = 6,
    KNIFE_ANM2 = "gfx/008.000_Moms Knife.anm2", -- 原版妈刀精灵：旋转 0 时刀尖朝下（实测朝右扔出时精灵旋转 -90）
    KNIFE_SCALE = 1.0,
    KNIFE_COLOR = { 150, 20, 20 }, -- 刀的拖尾颜色
    -- 英灵剑（用户设计）：每把剑 1/5 概率换成英灵剑模型，多个英灵剑不叠加；和妈刀共用概率：
    --   英灵剑占 1/5，妈刀占 min(妈刀数 × 1/5, 1 - 英灵剑那份)，例如 1 英灵剑 + 4 妈刀 = 80% 妈刀 + 20% 英灵剑，之后再拿哪个都不增加。
    -- 伤害单独计算，规则和妈刀一样（只有本体判定、每个敌人只打一次、不吃天顶剑倍率 / 暴击 / 多个天顶剑加成，跟班乘跟班倍率）：
    --   英灵剑 = 3.5 + 角色伤害 × 3（与原版挥剑一致，实测 3.5→14、7→24.5）
    --   出手时满血（红心 ≥ 有效心之容器，原版发射剑气的判定）则模型换成剑气泪弹，伤害 = 5.5 + 角色伤害 × 4（用户指定；
    --   原版实测：挥剑的剑气 = 角色伤害 + 2，蓄力旋转斩 = 角色伤害 × 8 + 10，旋转斩的剑气 = 角色伤害 × 4 + 4）
    -- 英灵剑和剑气都能像原版挥剑一样拾取掉落物、打开箱子（商店商品和道具底座除外）
    SPIRIT_SWORD_CHANCE = 0.2,
    SPIRIT_SWORD_DAMAGE_MULT = 3,
    SPIRIT_SWORD_DAMAGE_ADD = 3.5,
    SWORD_BEAM_DAMAGE_MULT = 4,
    SWORD_BEAM_DAMAGE_ADD = 5.5,
    -- 原版精灵（实测）：英灵剑 IdleRight 帧旋转 0 时刀尖朝下、中心点在剑柄（64x32，中心 12,16）；剑气旋转 0 时朝右、中心点在中间
    SPIRIT_SWORD_ANM2 = "gfx/008.010_Spirit Sword.anm2",
    SWORD_BEAM_ANM2 = "gfx/002.047_sword tear.anm2",
    SPIRIT_SWORD_SCALE = 0.8,
    SWORD_BEAM_SCALE = 0.8,
    SPIRIT_SWORD_COLOR = { 200, 235, 255 },
    SWORD_BEAM_COLOR = { 140, 210, 255 },
    -- 攻击方式被天顶剑完全覆盖的道具（用户定的统一规则）：拿着天顶剑时用 REPENTOGON 的 BlockCollectible 屏蔽，
    -- 游戏当作没有这件道具，效果和属性都不生效；失去天顶剑后解除。EID 说明里提示“效果和属性均不生效”
    FULL_OVERRIDE = {
        "MARKED", "EYE_OF_THE_OCCULT",                          -- 准星类（原来“属性保留”，用户改为统一不生效）
        "CHOCOLATE_MILK", "CURSED_EYE", "MONSTROS_LUNG",        -- 蓄力类
        "PARASITE", "CRICKETS_BODY", "HAEMOLACRIA", "LACHRYPHAGY", -- 分裂 / 爆裂泪弹类
        "ANTI_GRAVITY", "CONTINUUM", "RUBBER_CEMENT", "FLAT_STONE", "TRACTOR_BEAM", -- 轨迹类（docs/道具兼容清单.md，用户决定）
        "KIDNEY_STONE",                                         -- 肾结石（用户决定完全覆盖）
    },
    -- 同样完全覆盖的饰品（BlockTrinket）：改变眼泪轨迹的虫子（脑虫除外，清单里定为不处理）
    FULL_OVERRIDE_TRINKETS = {
        "PULSE_WORM", "WIGGLE_WORM", "RING_WORM", "FLAT_WORM", "HOOK_WORM", "WHIP_WORM",
        "RAINBOW_WORM", "TAPE_WORM", "LAZY_WORM", "OUROBOROS_WORM",
    },
    -- 清单里改成飞剑版本的道具（docs/道具兼容清单.md；数值为游戏内实测原版，-Suite probe_b 19/20）：
    --   巫师帽：原版每次两颗、左右斜 45°；每次出剑额外 2 把剑，落点在角色→准星方向左右各转 45°
    WIZ_ANGLE = 45,
    --   洛基之角：原版四向齐射，实测幸运 0 时 18%、10 时 71%；按 20% + 每点幸运 5% 概率额外 3 把剑飞向准星附近随机位置
    LOKI = { base = 0.2, perLuck = 0.05, swords = 3 },
    --   妈妈的眼：原版向后多一颗，实测幸运 0 时 51%、10 时 100%；按 50% + 每点幸运 10% 概率额外 1 把剑飞向角色背后
    MOMS_EYE = { base = 0.5, perLuck = 0.1 },
    --   眼疮：原版约 48% 多发，多 1 / 2 / 3 颗分别占 54% / 23% / 23%，方向随机
    EYE_SORE = { chance = 0.48, weights = { 0.54, 0.23, 0.23 } },
    --   小行星：飞剑绕角色转圈（用户决定），半径比卢多维科大一些，其余同卢多维科
    TINY_PLANET_RADIUS = 60,
    --   双瞳：剑的判定变宽
    PUPULA_WIDTH = 2,
    --   眼球突出：原版眼泪伤害随飞行距离衰减（实测距离 40/100/160/220 为 3.0/2.28/0.75/0.21 倍）；按命中时敌人离角色的距离套用
    PROPTOSIS_CURVE = { { 0, 3.0 }, { 40, 3.0 }, { 100, 2.28 }, { 160, 0.75 }, { 220, 0.21 } },
    --   奇异吸引子：剑命中敌人时，把半径内的其他敌人往这个敌人拉
    ATTRACTOR_RADIUS = 120,
    ATTRACTOR_PULL = 4,
    --   贝利尔之眼：每把剑命中第二个（及之后的）不同敌人时伤害 ×2
    BELIAL_MULT = 2,
    --   死亡之眼：每把剑第一次命中敌人时叠一层，每层伤害 +25%，最多 4 层；一把剑没打中任何敌人就清零
    DEAD_EYE_STEP = 0.25,
    DEAD_EYE_MAX = 4,
    --   鬼椒 / 鸟眼椒（用户决定）：每把剑按原版概率在准星处生成对应火焰（鬼椒蓝火、鸟眼椒红火），火焰大小随伤害变化同原版；
    --   概率实测：鬼椒 幸运 0 约 11%、10 约 46%，鸟眼椒 幸运 0 约 4%、10 约 55%，取 1 / max(2, 12 - 幸运)
    PEPPER_CHANCE = { denom = 12, denomPerLuck = -1, denomMin = 2 },
    --   神性：每把剑带一个光环，半径内的敌人每 2 帧受 2 点伤害（原版光环固定 2 点、约每 2 帧一次，实测）
    GODHEAD_RADIUS = 45,
    GODHEAD_DAMAGE = 2,
    GODHEAD_INTERVAL = 8,          -- 同一敌人两次光环伤害之间的更新次数（4 次更新 = 1 帧）
    -- 命中特效替身：剑带有下面这些泪弹标记时，第一次命中敌人时在敌人身上放一颗隐形的“替身眼泪”（只带这些标记，
    -- 伤害等于这一下剑的伤害，剑本身这一下不再另算伤害），让游戏自己按原版触发效果（小魔角、安乐死、圣光、雅各的梯子、
    -- 鼻屎、爆炸物、神秘液体、虫卵、大肠杆菌、裂隙、孢子、泰拉对石头类敌人、各种掉落……）。概率类效果由出剑时
    -- GetTearHitParams 按原版概率决定这把剑有没有这个标记
    PROXY_FLAGS = {
        "TEAR_HORN", "TEAR_NEEDLE", "TEAR_LIGHT_FROM_HEAVEN", "TEAR_JACOBS", "TEAR_BOOGER", "TEAR_STICKY",
        "TEAR_MYSTERIOUS_LIQUID_CREEP", "TEAR_EGG", "TEAR_ECOLI", "TEAR_RIFT", "TEAR_SPORE", "TEAR_ROCK",
        "TEAR_HP_DROP", "TEAR_BLACK_HP_DROP", "TEAR_COIN_DROP", "TEAR_GREED_COIN", "TEAR_COIN_DROP_DEATH",
        "TEAR_CARD_DROP_DEATH", "TEAR_RUNE_DROP_DEATH", "TEAR_TELEPORT", "TEAR_GISH",
    },
    -- 背刺（用户要求）：飞剑从四面八方砍，每次命中都算背刺：伤害 ×2 并流血。
    -- 倍率按道具说明（“背后命中造成双倍伤害”）；游戏内没能触发原版背刺来实测（-Suite probe_b 18）
    BACKSTAB_MULT = 2,
    -- 硫酸（用户要求）：飞剑像原版眼泪一样能打碎石头、打开隐藏房 / 超级隐藏房的墙
    -- 铅笔（用户要求）：原版每第 15 颗眼泪变成一次 13 颗的齐射（实测）；这里每第 15 次出剑改为一次扔出 13 把剑
    PENCIL_PERIOD = 15,
    PENCIL_BURST = 13,
    -- 模仿型跟班漏出的原生攻击：生成位置离跟班这么近、且比离角色本人近的眼泪/激光视为跟班的攻击
    MIMIC_LEAK_RADIUS = 30,
    EXPLOSION_DAMAGE_MULT = 1, -- 吐根：爆炸伤害 = 角色伤害 × 该倍率，每把剑只炸一次，会炸伤自己（纵火狂可回血）
    EXPLOSION_RADIUS_MULT = 0.6,

    -- 伤害数字（照搬泰拉 CombatText：向上弹出、减速、透明度呼吸、结束时缩小消失）
    DAMAGE_TEXT = true,
    DAMAGE_TEXT_SCALE = 0.5,   -- 字体绘制倍率（泰拉字体是 1080p 下的尺寸）
    DAMAGE_TEXT_COLOR = { 255, 160, 80 },      -- 泰拉 CombatText.DamagedHostile
    DAMAGE_TEXT_CRIT_COLOR = { 255, 100, 30 }, -- 泰拉 CombatText.DamagedHostileCrit
    DAMAGE_TEXT_MAX = 60,      -- 同屏最多数字数量，超出时丢弃最早的

    -- 可被飞剑打到的场景物件（和眼泪一样）：火堆、可推动的 TNT、商店老板、大便实体；地形中的大便和 TNT
    PROP_TYPES = { 33, 292, 17, 245 },         -- ENTITY_FIREPLACE / MOVABLE_TNT / SHOPKEEPER / POOP
    GRID_TYPES = { 12, 14 },                   -- GRID_TNT / GRID_POOP

    -- 推炸弹（和眼泪一样能推动即爆炸弹、角色放的炸弹等）：每把剑对同一颗炸弹只推一次，方向 = 这把剑出手时的瞄准方向。
    -- 力度与原版眼泪一致（游戏内对比测试验证）：推力 = (泪弹速度 - 炸弹迎面速度) × 泪弹质量 / (泪弹质量 + 炸弹质量) × BOMB_PUSH_MULT；
    -- 泪弹速度 = 弹速 × TEAR_BASE_SPEED。泪弹质量优先读游戏配置（需要 REPENTOGON），读不到时用 TEAR_MASS_FALLBACK
    BOMB_TYPE = 4,             -- ENTITY_BOMB
    TEAR_BASE_SPEED = 10,      -- 弹速 1.0 时眼泪每帧飞行的距离
    TEAR_MASS_FALLBACK = 8,
    BOMB_PUSH_MULT = 1,

    -- 以下为泰拉原版数值（泰拉像素 / 泰拉更新次数）
    HOMING_RADIUS_PX = 400,    -- 第 2、3 把剑在准星附近搜索敌人的半径
    RANDOM_OFFSET_PX = 150,    -- 落点随机偏移半径
    ELLIPSE_WIDTH_PX = 100,    -- 椭圆短半径随机范围 ±100
    MIN_MAJOR_PX = 60,         -- 椭圆长半径下限
    MAJOR_GROW_PX = 40,        -- 回程时长半径额外增加量
    RATE_DISTANCE_PX = 900,    -- 距离 ≥ 该值时飞行最慢
    RATE_NEAR = 2.0,           -- 每次更新的进度增量（近）
    RATE_FAR = 0.7,            -- 每次更新的进度增量（远）
    PATH_END = 60,             -- 进度到 60 时剑回到角色身边
    LIFE_END = 120,            -- 进度到 120 时拖尾完全消失
    HIT_COOLDOWN_UPDATES = 15, -- 每把剑对同一敌人的命中间隔（≈ 每秒 8 次）
    BLADE_HALF_PX = 40,        -- 判定线段半长
    BLADE_THICKNESS = 10,      -- 判定线段粗细（以撒单位）
    AFTERIMAGE_STEP = 15,      -- 残影间隔（更新次数）
    TRAIL_CACHE = 60,          -- 拖尾长度（更新次数）

    -- 粒子（原版：每次更新 1/9 概率生成 1～3 个，沿刀身方向飞出）
    DUST_CHANCE = 9,
    DUST_SPEED_PX = { 3, 7 },  -- 每泰拉帧的速度
    DUST_LIFE = { 10, 18 },    -- 存活逻辑帧数
    DUST_DRAG = 0.88,

    -- 拖尾绘制（需要 REPENTOGON）
    TRAIL_POINTS = 24,
    TRAIL_ALPHA = 1.0,
    TRAIL_SIDE_FLIP = false,   -- 亮边应在刀尖一侧（外侧）；如果看到在刀柄一侧，改成 true
    ADDITIVE_GLOW = true,      -- 拖尾、星闪、粒子使用叠加混合（发光效果）

    ORIGIN_OFFSET = Vector(0, -6), -- 剑的发射原点相对角色位置的偏移（大致在身体中心）
}
