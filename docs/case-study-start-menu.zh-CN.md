# 案例研究：那个回不去的开始菜单

[English](case-study-start-menu.md) | 简体中文

这个工具就是这次排查的副产品。之所以值得公开，是因为**失败的结论比代码更有用**：
**写入一个功能开关可以成功，却什么也不改变。**

## 症状

Windows 11 25H2，build `26200.8457`。Windows 更新已暂停到 2126 年，`2026-08-05`
之后再没装过累积更新，开始菜单却在某一次开机后从旧版设计变成了新版。

以下所有数据都在那台机器上实测。

## 排除了什么

| 假设 | 反证 |
|---|---|
| 装了更新 | `Get-HotFix` 最新一条是 `KB5089549`（2026-08-05）；`Get-WindowsPackage` 显示最近 7 天零安装 |
| 外壳包被更新了 | `StartMenuExperienceHost` 10.0.26100.4768，安装目录时间戳 `2026-08-05 22:42` |
| 把更新卸掉就行 | `DISM /Online /Remove-Package` 返回 `0x800f0825`（`CBS_E_CANNOT_UNINSTALL`）：该累积更新是 25H2 启用包的基线，被标记为永久 |
| 最近有功能开关被翻动 | 第一轮判断是否定的：`Overrides\0` 下所有键的最后写入时间都是 `2026-08-05 22:42`。**这个测量不完整**——见下 |

最后一行正是本文档第一版写错的地方，值得当作教训记下来：**开关存储不止一个桶。**
`Overrides` 下面有多个优先级分组，而当时只查了其中一个。

查完所有分组，画面完全变了：

```
10-17 14:21   写入 38 个开关   ← 当天第一次开机
10-17 14:23   写入 6 个开关
10-16 19:18   写入 11 个开关
```

也就是说：在这台机器上，功能状态**确实**在被大量写入，发生在开机时刻，落在组 4，
而且是在 Windows 更新暂停的情况下。8 月那份组 0 快照只是另一个从不变化的桶。

实际结论：排查“界面自己变了”时，要查**所有分组**，不要只看组 0。
`Get-FeatureOverrides.ps1 -Recent 7` 默认就是这么做的。

附注：.NET 的注册表 API 读不出键的最后写入时间（`Get-Item` 返回空值）。上面的时间戳
来自 `RegQueryInfoKey`，这也是 `Get-FeatureOverrides.ps1` 单独暴露这个字段的原因。

## 第一次尝试

网上流传的新版开始菜单（合并 Pinned/Recommended）功能 ID 是 `47205210`。把它写成
`EnabledState=1` 是成功的：

```
step 2: become owner      -> owner is now: BUILTIN\Administrators
step 3: grant DACL        -> DACL updated
step 4: write values      -> 47205210 -> EnabledState=1 (off)
step 5: restore protection-> DACL restore: success, owner restore: success
```

重启后，开始菜单毫无变化。

## 这说明什么

第一次猜的 ID 对这个 build 就是错的。`47205210` 属于 build-7019 那个年代，而这台机器
是 `.8457`。

## 结论：找到了

用定向二分法找到了真正的那个。

起点是 `Get-FeatureOverrides.ps1 -Recent 3`：最近三天有 186 个开关被写入，其中最大的
一批是组 4 的 38 个，全部集中在同一分钟——当天第一次开机的那一刻。

把这些过滤到 `EnabledState = 2` 后剩 33 个候选。把 33 个全部禁用，开始菜单恢复旧版，
证明开关就在这批里。然后按半数二分，每轮重启一次：

```
33 -> 16 -> 8 -> 4 -> 2 -> 1
```

在 Windows 11 25H2 build `26200.8457` 上的结果：

| | |
|---|---|
| 分组 | `4` |
| 功能 ID | **`3036241548`** |
| `EnabledState = 2` | 新版开始菜单 |
| `EnabledState = 1` | 旧版开始菜单 |
| 原始 `EnabledStateOptions` | `1`（工具写入的是 `0`，未观察到差异） |
| 原始 `Variant` | `0` |

```powershell
# 旧版开始菜单
.\Set-FeatureOverride.ps1 -FeatureId 3036241548 -Group 4 -State Disabled
# 换回新版
.\Set-FeatureOverride.ps1 -FeatureId 3036241548 -Group 4 -State Enabled
```

两种操作后都要重启。这个 ID **只对 `26200.8457` 有效**，不要假设它能跨 build 通用。

## 可迁移的经验

* 功能 ID 离开 build 号就毫无价值，两者必须一起记录。
* CFR 的「状态」和「代码」是分开存放的。卸载更新能回滚代码，却把状态留在原地，这就是
  某个界面为什么会"自己回来"。
* 累积更新返回 `0x800f0825` 意味着它是基线包。再怎么折腾 DISM 也卸不掉。
* 暂停 Windows 更新**不会**阻止 Defender 病毒库更新和商店应用更新，它们走同一个客户端。
* 界面"自己变了"时，按最后写入时间**跨所有分组**排序，找开机时刻的那一批写入。
  那一批就是候选集。
* 二分 33 个功能只需 6 次重启，远比盲猜 ID 便宜。
