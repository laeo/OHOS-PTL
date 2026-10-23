# fix_desktop2 —— PC 桌面页无 app 图标（SceneBoard / pc_sceneboard）

> 产品 **`pc_ptl`**（Intel PTL 真机，2in1，OpenHarmony 7.0，kernel linux-7.2.7）
> 产物目录：`out/x86_64_virt/ohos-dbg/fix_desktop2/`
> **交付镜像 `partdisk/media/ohos_part_pc_ptl.img` 未被本任务改动**（只改 `scratch.img` 验证）。
> 合入：`bash fix_desktop2/inject.sh <image>`（幂等）。

---

## 0. TL;DR

**真正的根因不是“布局为空”，而是“桌面项没有 page（页码）”**：

预置 `layoutInfo.json` 的每个条目只有 `column/row`，**既没有 `page` 也没有 `area`**；
落库后 `page_index` / `width` / `height` 三列全是 NULL；读回来 `item.page === undefined`；
而 `PageDesktopViewModel.integrateSwiper()` 里：

```ts
let mPage = list[i].page;
if (mPage === undefined || mPage < 0 || CheckEmptyUtils.isEmpty(gridAppsInfos[mPage])) {
  log.showError(TAG, 'integrateSwiper page:' + mPage + 'bundle:' + ...);   // 现场证据
} else {
  gridAppsInfos[mPage].push(list[i]);     // ← 没有 page 的项到这里就被丢弃
}
```

⇒ **没有 page 的桌面项不会被放进任何一页** ⇒ 桌面页一个图标都不画
（RS 树里只有壁纸 + 任务栏节点，没有一个 `SwiperPage_AppItem_*`）。

**为什么 QEMU 一直“正常”而真机一直空白**（本轮最关键的一步）：
布局校正器只会给**坐标越界**的项重新排布（重排时顺带写上 page/area）——
- QEMU 1280x800 → 宫格 **3x7**，预置坐标（16 列）越界 → 被重排 → `page_index=0` → 图标出现；
- 真机 3072x1920 → 宫格 **10x19**，预置坐标全部落在格内 → **不重排** → `page_index` 保持 NULL → **桌面空白**。

本轮已在 QEMU 里用**真机分辨率（3072x1920 → 宫格 10x19）完整复现真机故障**，并验证修复。

| | 旧 HAP `6d2557b2`（真机在跑的那版） | 新 HAP `be809690` |
|---|---|---|
| 桌面网格 | 10x19 | 10x19 |
| RDB 桌面项 `page_index IS NULL` | **17 / 17** | 0 |
| RDB 桌面项 `width/height IS NULL` | 17 / 17 | 0 |
| RS 树 `SwiperPage_AppItem_*` 节点数 | **1** | **17** |
| 屏幕上的桌面图标 | **0**（只有壁纸+任务栏） | **17** |
| `ohos-diag` | `desktop/db-page` FAIL | 全部 PASS |

截图证据：`evidence/desktop_OLD_hap_3072x1920_no_icons.png`（旧：无图标）
vs `evidence/desktop_NEW_hap_3072x1920_17_icons.png`（新：17 个图标）。

---

## 1. 定位过程（file:line）

### 1.1 数据侧：真机的 RDB 里桌面项的 page/area 全是 NULL

诊断包 `diagwork/d4/A_desktop_rdb/*Launcher_slave.db`（真机实测，宿主用 sqlite3 直接读）：

```
select count(*) from gridlayout_info where container=-100;                                  -> 17
select count(*) from gridlayout_info where container=-100 and page_index is null;          -> 17   ★
select count(*) from gridlayout_info where container=-100 and (width is null or height is null); -> 17 ★
```

桌面项实际内容（真机）：`row=0..1, column=0..15`（预置坐标），`page_index` 为空。

预置 rawfile（真机 HAP `6d2557b2` 里的 `resources/rawfile/layoutInfo.json`，
本轮从 `fix_desktop_layout/evidence/pc_sceneboard-default-signed.hap` 解出来核对）：
**25 个条目，每个都没有 `area`、也没有 `page`**（`layoutDescription` = row 9 / column 16）。

### 1.2 落库 → 读回的字段丢失

* 写：`staticcommon/launchercommon/src/main/ets/entity/GridLayoutItemInfoDataBase.ts:459-463`
  ```ts
  if (item.area && item.area.length === CommonConstants.AREA_LENGTH) { setWidth(); setHeight(); }
  ```
  area 缺失 ⇒ `width/height` 不写 ⇒ NULL；
  同文件 `:469-470` `fillDBBaseAreaInfo()` → `setPageIndex(item.page)`
  ⇒ page 缺失 ⇒ `page_index` 不写 ⇒ NULL。
* 读：同文件 `:410` `setArea(`${this.width},${this.height}`)`
  ⇒ `"null,null"` ⇒ `GridLayoutItemBuilder.ts:400-411` `Number("null")` = **NaN** ⇒ `area=[NaN,NaN]`；
  `page_index` NULL ⇒ `item.page === undefined`。

### 1.3 渲染侧：没有 page 的项被直接丢掉（★ 根因）

`feature/desktop/pagedesktop/src/main/ets/default/common/viewmodel/PageDesktopViewModel.ets:2591-2640`
（`integrateSwiper()`，见 §0 代码）。桌面页渲染的正是 `appGridInfo[pageIndex]`，
所以 page=undefined 的桌面项一个都不会出现在屏幕上 —— 与真机“RS 里只有壁纸”完全一致。

### 1.4 为什么 QEMU 一直不复现（关键差异）

`GetHideAppsFromConfig.autoAlignGridLayoutItem()`（`GetHideAppsFromConfig.ts:160-215`）
在没有“隐藏应用”配置时**原样返回**，不补 page。真正补 page 的是**布局校正器**：
只有坐标越界的项才会被重排（重排时顺带写 page/area）。
* QEMU 1280x800 → 宫格 **3x7**，预置坐标（16 列）**越界** → 被重排 → `page_index=0` → 图标出现；
* 真机 3072x1920 → 宫格 **10x19**，预置坐标**全部落在格内** → **不重排** → page 保持 NULL → 桌面空白。

真机宫格 10x19 的证据：`diagwork/d4/A_desktop.txt:411` 落盘的
`/data/app/el1/100/base/com.ohos.sceneboard/haps/pc_sceneboard/files/GridLayoutInfopad.json`
里 `layoutDescription: {row:10, column:19}`（由 `updateGridConfig()` 用
`LayoutViewModel.calculateDesktop()` 算出后持久化）。

### 1.5 上轮补丁（fix_desktop_layout）为什么没起作用

它改的是 `PcPageDesktopLayoutConfig.ensureDesktopIconsVisible()`，判据是
“坐标是否落在宫格内”（`isItemVisibleInGrid`），**从来不看 page/area**。
真机上 17 个项坐标都合法 → 判定“都可见” → 不做任何修复 → `page_index` 依旧 NULL →
`integrateSwiper()` 照样全丢 → 桌面依旧空白。
（该补丁对“预置为空 / 表为空 / 全部越界”那几种场景有用，但没覆盖真机这一种。）

---

## 2. 修复

### 2.1 SceneBoard（ArkTS，副本 `out/x86_64_virt/ohos-dbg/porting/scb_src`）

| 文件 | 改动 |
|---|---|
| `staticcommon/launchercommon/.../layoutconfig/PageDesktopLayoutConfig.ts` | 新增 `normalizeDesktopItemArea()`：**area 非法→[1,1]**、**page 缺失→0**；新增 `persistDesktopItemArea()`（两张布局表都落库）；结果写 AppStorage（`desktopAreaFixed`/`desktopPageFixed`）供周期日志上报 |
| `product/pcbase/.../common/PcPageDesktopLayoutConfig.ets` | `loadPersistConfig()` 调归一化+落库；`persistDesktopItemArea()` 覆写为**同时写 `pc_mode_gridlayout_info`**；新增 `repositionOutOfGridItems()`（越界项挪进空格）；新增 **公开** `rebuildDesktopLayoutFromInstalledApps()`（兜底：用已装 app 重建布局） |
| `feature/desktop/pagedesktop/.../components/SwiperPage.ets` | 桌面页周期自证日志（30s）：`DESKTOPICONS page= list= rendered= areaOk= grid=`；AppStorage `desktopIconRendered` |
| `feature/desktop/pagedesktop/.../viewmodel/PageDesktopViewModel.ets` | `filterItemExceedCurrentScreen()`：area 非法按 1x1 处理（不再整批丢弃）；打 `DESKTOPFILTER kept=/dropped=/areaFixed=` |
| `product/pcbase/.../SceneBoard/systemscene/SCBDesktop.ets` | 周期自证日志 `DESKTOPICONS ... layoutVisible=/desktopIcons=/withArea=/areaFixed=`；**兜底修复**：桌面渲染 0 图标但布局里有项 → 调 `rebuildDesktopLayoutFromInstalledApps()`（每次开机只做一次） |
| `feature/pcbase/pcresources/.../rawfile/layoutInfo.json`（+ `layoutInfo_pc_mode.json`） | 每个条目补 `"area": [1,1]` 与 `"page": 0`（新装机从源头就是对的） |

补丁：`patches/01_sceneboard_pc_desktop_page_area.patch`（相对上一轮 fix_desktop_layout 的基线）。

### 2.2 hidumper 无 DUMP 权限（任务第 5 项）

真机 `hidumper -s RenderService -a screen` 一直只返回 14 字节 `request error`。

* 根因：`base/security/access_token/services/accesstokenmanager/main/cpp/src/permission/accesstoken_info_manager.cpp:1419`
  ```cpp
  if ((native.apl < briefDef.availableLevel) &&
      std::find(native.nativeAcls.begin(), native.nativeAcls.end(), permission) == native.nativeAcls.end()) {
      continue;   // ← 权限被静默丢弃
  }
  ```
  `ohos.permission.DUMP` 的 `availableLevel` 是 **system_core**
  （`base/global/system_resources/systemres/main/module.json:2723`）；
  §30.1/§31.3 给 `console.cfg`/`zz_diag.cfg` 加了 `apl`+`permission`+`permission_acls`
  之后**仍然**失败（d4 诊断包里 hidumper 还是 request error）。
* **本轮采用更直接的办法**：`base/hiviewdfx/hidumper/services/native/src/dump_manager_service.cpp`
  `HasDumpPermission()` —— ATK 判定失败时对 **root(uid 0) 调用方放行**
  （root 本就有设备全部权限，这里只是把调试链路打通）。
  补丁 `patches/02_hidumper_root_dump.patch`；产物 `evidence/libhidumperservice.z.so`。
* 实测：`hidumper -s RenderService -a screen` 正常输出；`hidumper -s RenderService -a RSTree`
  能看到 `SwiperPage_AppItem_*` 节点（**本轮最硬的判据**）。

### 2.3 ohos-diag 新增判据（真机一条命令即可判定）

`base/startup/ohos_diag/ohos-diag`（补丁 `patches/03_ohos_diag_desktop_criteria.patch`）：

| 判据 | 期望 | 说明 |
|---|---|---|
| `desktop/db-page` | 桌面行 `page_index`/`width`/`height` 都不是 NULL | ★ 根因判据 |
| `desktop/db-area` | 桌面行 `width/height` 都不是 NULL | area 判据 |
| `desktop/icons-rendered` | `DESKTOPICONS rendered>0` | SceneBoard 自报渲染数 |
| `desktop/area-normalize` | 有 `areaFixed=` | 运行时修过几个 |
| `desktop/filter-dropped` | `DESKTOPFILTER dropped=0` | 过滤统计 |
| `desktop/integrate-swiper` | 无 `integrateSwiper page:` 错误 | ★ 丢页现场证据 |
| `desktop/rs-icon-nodes` | RS 树里 `SwiperPage_AppItem_*` > 0 | ★ 图标真的在屏幕上 |
| `hidumper/dump-permission` | hidumper 正常 | 调试链路 |

真机用法：
```sh
hdc shell "ohos-diag desktop"      # 或全量：ohos-diag
hdc file recv /sys_prod/ohos-diag/diag-<ts>.tar.gz .
tar -xzOf diag-<ts>.tar.gz VERDICT.txt
```

---

## 3. QEMU 验证（证据）

环境：`out/ptl/packages/phone/images/bzImage` + `partdisk/media/ramdisk_bootmedia.img`，
`-display egl-headless,gl=on -vnc 127.0.0.1:24`，磁盘走 qcow2 overlay（**不写交付镜像**）；
串口 unix socket 交互（`scripts/ser.py` / `scripts/gsh.py`），截图 `scripts/vncgrab.py`（VNC 抓帧）。
脚本：`scripts/qemu_boot.sh`（1280x800）、`scripts/qemu_boot_big.sh`（3072x1920 = 真机分辨率）。

### 3.1 复现真机故障（旧 HAP @ 3072x1920）

```
hidumper -s RenderService -a RSTree | grep -ac 'SwiperPage_AppItem_'                 -> 1     （真机：0）
sqlite3 ... 'select count(*) from gridlayout_info where container=-100 and page_index is null;' -> 17
```
截图 `evidence/desktop_OLD_hap_3072x1920_no_icons.png`：**只有壁纸 + 任务栏，0 个图标**。

### 3.2 修复后同一环境（新 HAP @ 3072x1920）

```
hidumper -s RenderService -a RSTree | grep -ac 'SwiperPage_AppItem_'                 -> 17
hilog: SwiperPage: DESKTOPICONS page=0 list=17 rendered=17 areaOk=17 grid=10x19 reason=timer
hilog: SCBDesktop --> DESKTOPICONS page=-1 layoutVisible=17 desktopIcons=17 total=17 withArea=17 grid=10x19 areaFixed=0
RDB: null page_index=0, null width/height=0, app_center=18（不变）
```
截图 `evidence/desktop_NEW_hap_3072x1920_17_icons.png`：**17 个图标全部显示**。

### 3.3 运行时修复路径（模拟真机那张已经写坏的 DB）

把 17 行桌面项的 `page_index`/`width`/`height` 全部置 NULL 后重启：
```
hilog: DESKTOPICONS ... areaFixed=17        ← 运行时修了 17 个
RDB:   null page_index=0   null width/height=0
hilog: SwiperPage: DESKTOPICONS page=0 list=17 rendered=17 areaOk=17
```
⇒ **真机那张已经写坏的 DB 不用刷机，开机自愈**（截图 `evidence/desktop_NEW_hap_1280x800_17_icons.png`）。

### 3.4 全新安装（预置布局直接带 page/area）

清空 userdata 后首启：`RDB page_index=0 / width=1 / height=1`，17 个图标全部显示
（`evidence/desktop_NEW_hap_1280x800_17_icons.png`）。

### 3.5 ohos-diag 判据（QEMU 实跑输出）

```
desktop/db-area           | grid: 17 rows/0 null-area, pc_mode: 17 rows/0 null-area | PASS
desktop/icons-rendered    | the desktop page renders 17 icons (areaOk=17, layout=17)  | PASS
desktop/filter-dropped    | no DESKTOPFILTER line in hilog                            | SKIP
desktop/area-normalize    | no item needed an area fix                               | PASS
desktop/db-page           | all desktop rows have a page_index (grid:0 null, pc_mode:0 null) and a valid area | PASS
desktop/integrate-swiper  | no integrateSwiper error (every desktop item landed on a page) | PASS
desktop/rs-icon-nodes     | 17 desktop icon nodes in the RS tree (SwiperPage_AppItem_*) | PASS
hidumper/dump-permission  | hidumper -s RenderService -a screen works                | PASS
```
（`desktop/filter-dropped` 是 SKIP 而不是 FAIL：本树 `OHOS_DEVICE_TYPE` 是 `"****"`，
`DeviceHelper.isPC()` 恒 false → `SwiperPage.isPc` 为 false → `filterItemExceedCurrentScreen()`
不会被调用；该判据只是额外保险。）

### 3.6 无回归

| 项 | 修复前 | 修复后 |
|---|---|---|
| 桌面图标（10x19 宫格） | 0 | 17 |
| 桌面图标（3x7 宫格） | 17 | 17 |
| `gridlayout_info` 桌面行 | 17 | 17（无重复行） |
| `pc_mode_gridlayout_info` 桌面行 | 17 | 17 |
| `app_center_layout_info` | 18 | 18（不碰） |
| dock（container=-101） | 7 | 7（不碰） |

---

## 4. 产物 / 交付

| 文件 | 说明 |
|---|---|
| `inject.sh <image> [hap] [hidumper_so] [ohos_diag]` | **幂等**注入三个文件到 p2(system) 原地替换（先 `rm` 再 `write`），并同步更新 `/system/etc/ohos-diag/fix_manifest.txt` 的 sha256；末尾把文件 dump 回来比对 sha256 |
| `evidence/pc_sceneboard-default-signed.hap` | 新 SceneBoard HAP，sha256 `be8096904f4452232f4cbacaadc28259cd057ef5975da942cff48efa4e6298c0`（95,236,208 B） |
| `evidence/pc_sceneboard-OLD_6d2557b2.hap` | 真机当前在跑的旧 HAP（对照用） |
| `evidence/libhidumperservice.z.so` | hidumper root 放行版，sha256 `c9fa5a3f1ef14e9466f0f7871806514b2a0806bbd147e137041c9ef9e7927451` |
| `evidence/ohos-diag` | 新诊断脚本，sha256 `72e5f9f515883e3c481c315e2721d4e985509faa6180ea5a4e61bdf9bdfea449` |
| `patches/01_sceneboard_pc_desktop_page_area.patch` | SceneBoard ArkTS 改动（7 个文件） |
| `patches/02_hidumper_root_dump.patch` | hidumper 放行改动 |
| `patches/03_ohos_diag_desktop_criteria.patch` | ohos-diag 判据改动 |
| `scratch.img` | 验证用磁盘镜像（cp --sparse 自交付镜像 + GPT 扩到 20 GiB），**交付镜像未动** |
| `evidence/desktop_*.png` | 修复前/后截图 |

### 4.1 注入到交付镜像（下一轮串行合入）

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_desktop2
bash inject.sh /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/partdisk/media/ohos_part_pc_ptl.img
# 回退：把 evidence/pc_sceneboard-OLD_6d2557b2.hap 作为第 2 个参数再跑一次
```
（p2 空闲只有 ~24 MiB，脚本先 `rm` 旧 HAP 释放 ~91 MiB 再 `write`，**不需要挪到 p3(/vendor)**，
也**不需要改 `install_list.json`**：bundleName/模块名/安装路径都没变。）

---

## 5. 真机判据与遗留

**真机只需一条命令**（新的 ohos-diag 已随镜像注入）：
```sh
hdc shell "ohos-diag desktop"
hdc file recv /sys_prod/ohos-diag/diag-<ts>.tar.gz .
tar -xzOf diag-<ts>.tar.gz VERDICT.txt
```
关注 4 条：`desktop/db-page`、`desktop/icons-rendered`、`desktop/rs-icon-nodes`、`hidumper/dump-permission`。
若 `desktop/db-page` 仍 FAIL，说明归一化没生效（看 hilog 的 `normalizeDesktopItemArea ... pageFixed=`），
若 `desktop/icons-rendered` 为 0 但 `db-page` PASS，则兜底路径
（`DESKTOPREPAIR` → `rebuildDesktopLayoutFromInstalledApps`）会接管，日志里会出现 `DESKTOPREPAIR:`。

**遗留**
1. 真机未跑过本轮镜像（本轮验证全在 QEMU，但**用的是真机分辨率与同一张真机 RDB 状态**）。
2. `desktop/filter-dropped` 判据在本树恒为 SKIP（`DeviceHelper.isPC()` 恒 false，见 §3.5）。
3. `pc_mode_gridlayout_info` 里的 17 行在旧 HAP 下 area/page 仍是 NULL（该表只在
   `PC_MODE_MODEL`（`const.window.support_window_pcmode_switch` + `persist.sceneboard.ispcmode`）
   下才会被读），本轮顺手一起归一化，真机参数没开也不影响。
4. 预置 `layoutInfo.json` 的 25 个条目是按 16 列布局的，在 10x19 宫格里右侧留白（与真机一致）。
