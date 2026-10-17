# cfr-override

[English](README.md) | 简体中文

用纯 PowerShell 读写 Windows **CFR**（受控功能推送）功能开关，**不需要任何第三方二进制**。

Windows 把功能开关存在这里：

```
HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\<组号>\<功能ID>
```

这个位置的属主是 `NT SERVICE\TrustedInstaller`，`Administrators` 只有 `ReadKey`，所以哪怕你是管理员也**写不进去**。本仓库做的事和 ViVeTool 内部一样，只是用可审计的 PowerShell 实现：

1. 启用 `SeTakeOwnershipPrivilege` 与 `SeRestorePrivilege` 特权
2. 夺取组键的所有权（只改 owner 字段）
3. 向 DACL 插入一条 `BUILTIN\Administrators` 的允许项
4. 写入功能开关的值
5. 把原始 DACL 还回去，所有权交还 `TrustedInstaller`

第 5 步**无论成功失败都会执行**。原始安全描述符在动手前就已保存，结束时再比对一次。

## 它不是什么

* **不是**功能 ID 数据库。ID 会随 Windows 版本变化，有些功能甚至不再受开关控制，ID 需要你自己提供。
* **不是**"一键还原某功能"的按钮。写进去但外壳不再读的开关，不会有任何可见效果。真实案例见 [docs/case-study-start-menu.md](docs/case-study-start-menu.md)。

## 为什么不直接推荐 ViVeTool

ViVeTool 很成熟，能用就用它。

这个仓库面向的是**不能下载运行未签名二进制**的环境：受控的企业镜像、离线机器，或者任何想在执行前把每一行代码看完的人。两个可读的 `.ps1`，没有编译产物。

## 环境要求

* Windows 10/11，Windows PowerShell 5.1 或 PowerShell 7+
* `Set-FeatureOverride.ps1` 需要管理员窗口才能真的改动
* `Get-FeatureOverrides.ps1` 和 `-WhatIf` 不需要提权

## 快速开始

```powershell
# 1. 看看最近有哪些功能状态被改过（只读，无需提权）
.\Get-FeatureOverrides.ps1 -Recent 7 | Format-Table Group, FeatureId, Meaning, LastWriteTime

# 2. 空跑：只报告将要做什么，不修改任何东西
.\Set-FeatureOverride.ps1 -FeatureId 12345678 -State Disabled -WhatIf

# 3. 真正写入（管理员窗口），之后重启
.\Set-FeatureOverride.ps1 -FeatureId 12345678 -State Disabled

# 4. 撤销：删掉这个开关，回到系统默认状态
.\Set-FeatureOverride.ps1 -FeatureId 12345678 -Remove

# 5. 上次运行被中断、键被留在了 Administrators 名下时
.\Set-FeatureOverride.ps1 -Repair
```

每次运行都会在 `.\logs\` 下留一份日志。

`Set-FeatureOverride.ps1` 声明了 `ConfirmImpact = 'High'`，真正改动前会请求确认。放进脚本或无人值守运行时加上 `-Confirm:$false`：

## 安全设计

* **先备份**：改动前读取组键的 SDDL，结束时写回，并报告是否与原始一致；
* **不假定成功**：夺取所有权后会重新读取 owner 校验，不通过就**在写入前中止**；
* **出错回滚**：owner 与 DACL 在 `finally` 中恢复，失败也不会留下半开状态；
* **默认可空跑**：`-WhatIf` 走完所有只读检查后直接退出；
* **幂等**：标记 ACE 已存在时不重复插入；
* **残留检测**：发现键已被 Administrators 所有时，提示上次运行未完成，并指向 `-Repair`。

## 排错

| 现象 | 含义 |
|---|---|
| `SetOwner failed: access denied` | 令牌没有 `SeTakeOwnershipPrivilege`，在管理员窗口里执行 `whoami /priv` 确认 |
| `privilege not held by this token (1300)` | 同上，通常意味着那个"管理员窗口"其实没提权 |
| `RegOpenKeyEx(WRITE_DAC) failed` | 所有权拿到了但没拿到 `WRITE_DAC`，执行 `-Repair` |
| `dacl differs from the original` | 运行期间有其他进程改了 ACL，用 `regedit` 手工核对 |
| 写入成功但界面没变 | ID 不对，或该功能在此版本不受开关控制 |

## 实测记录

在 Windows 11 25H2 build `26200.8457`（即案例研究那台机器）上验证过：

| 检查项 | 结果 |
|---|---|
| 两个脚本的语法解析 | OK |
| 纯 ASCII 源码（Windows PowerShell 5.1 安全） | OK，非 ASCII 字符 0 个 |
| `Get-FeatureOverrides.ps1` 真机运行 | OK，各组均能读出真实时间戳 |
| `-WhatIf` | OK，不修改、无副作用 |
| 端到端高权限路径 | OK：启用特权 → 夺取所有权 → 授予 DACL → 删除键 → 还原 DACL → 所有权交还 TrustedInstaller → 还原后的 DACL 与原始一致 |
| 错误路径（基键不存在） | OK，报错信息明确 |

### 一个调用上的坑

`-Confirm:$false` 只有**直接从 PowerShell 会话调用脚本**时才是开关。如果外面再套一层
`powershell -File ...`，外层会先把 `$false` 展开成字符串 `False`，参数绑定就会失败。

```powershell
& .\Set-FeatureOverride.ps1 -FeatureId 12345678 -Remove -Confirm:$false   # 直接调用
powershell -ExecutionPolicy Bypass -File .\Set-FeatureOverride.ps1 -FeatureId 12345678 -Remove   # 让它问一句
```

## 许可证

MIT，见 [LICENSE](LICENSE)。

本工具会**临时改变受保护注册表键的属主与权限**。这是高权限操作，中断时有真实风险。请先在虚拟机验证。作者不对系统损坏承担责任。
