# 概述
面向 Rockchip RK3588 系列（LubanCat-4/5/5-V2/5IO）的 deepin 25 构建工程，可生成服务器版与桌面版镜像。

## 主要特性
- **系统**：deepin 25（crimson）
- **内核**：Linux 6.1.172（Rockchip BSP）
- **桌面**：DDE（deepin-desktop-environment-core）+ lightdm，默认中文语言环境
- **软件源**：华为云 deepin 镜像（可用 `DEEPIN_MIRROR` 覆盖）
- **启动**：U-Boot + boot.scr 启动脚本，支持 SD / eMMC / NVMe

# 获取与校验
镜像由下方编译流程生成，产物同时附带 `.sha256` 校验文件。

# 安装

## SD 卡
1. 推荐使用 rufus（免安装、小体积）。若需其他版本可从 https://rufus.ie/zh/ 获取。
2. 打开 rufus，选择 SD 卡与镜像（可直接选择 .xz），开始写入，等待完成。

## eMMC 启动
1. 用 RKDevTool 进入 maskrom 模式。
2. 选择 “下载镜像”：`boot` 选 `rk3588_MiniLoaderAll.bin`；`system` 选解压后的 `.img`。
3. 勾选 “强制按地址写”，点击执行，等待完成。

## NVMe 启动
- 方案 A（先从 SD 引导到系统后写 NVMe）：
  ```bash
  xz -dc deepin-25-desktop-arm64-lubancat-5.img.xz | sudo dd of=/dev/nvme0n1 bs=4k
  sync
  ```
  断电拔卡后，按 MR 进入 maskrom，将 `rkspi_loader_lubancat_5.img` 刷入 eMMC 作为 NVMe 引导。
- 方案 B（从已启动系统直接写 NVMe，流程同上）。
- 停止 NVMe 启动（清除分区）：
  ```bash
  sudo dd if=/dev/zero of=/dev/nvme0n1 bs=8M count=1
  ```

# 登录信息
- 预设账户：用户 `cat` / 密码 `temppwd`；`root` / 密码 `root`
- 支持 HDMI 与串口登录。

# 编译

## 安装依赖
```bash
sudo apt-get install -y build-essential gcc-aarch64-linux-gnu bison \
qemu-user-static qemu-system-arm u-boot-tools binfmt-support python-is-python3 fdisk \
debootstrap flex libssl-dev bc rsync kmod cpio xz-utils fakeroot parted \
udev dosfstools uuid-runtime git-lfs device-tree-compiler python3

```

### 配置 ARM64 跨架构构建环境
在 x86_64/amd64 主机上构建 ARM64 rootfs 前，需要启用 QEMU binfmt：
```bash
sudo update-binfmts --enable qemu-aarch64
update-binfmts --display qemu-aarch64
```
确认输出中包含 `qemu-aarch64 (enabled)`，构建脚本通过 binfmt 执行 ARM64 程序。

## 获取源码
```bash
git clone https://github.com/erd-yunmu/deepin-rk35xx
cd deepin-rk35xx
git lfs fetch && git lfs checkout
```

## 构建镜像

### 选择目标板
首次使用先交互式选择板卡，结果保存在 `build/.board`，之后构建不用再指定：
```bash
sudo ./build.sh config
```
界面会列出 `config/boards/` 下所有板卡：
```
可选的板卡配置：
  1) [rk3576] lubancat-3 (LubanCat 3)
  2) [rk3576] lubancat-3io (LubanCat 3IO)
  3) [rk3588] lubancat-4 (LubanCat 4)
  ...
请选择板卡 [1-7] (q/exit 退出):
```
输入编号回车即保存；输入 `q` 或 `exit` 取消并退出。

### 构建
```bash
sudo ./build.sh all          # 全量构建：内核 + U-Boot + rootfs + 镜像
sudo ./build.sh kernel       # 仅编译内核
sudo ./build.sh uboot        # 仅编译 U-Boot
sudo ./build.sh server       # 仅构建服务器版镜像
sudo ./build.sh desktop      # 仅构建桌面版镜像
sudo ./build.sh clean        # 删除 build 目录
```

也可以跳过 `config`，直接指定板卡：
```bash
sudo ./build.sh -b lubancat-5
```

常用命令：

| 命令 | 说明 |
| --- | --- |
| `board, -b <BOARD>` | 指定目标板 |
| `config` | 列出并保存目标板（写入 `build/.board`） |
| `all` | 全量构建 |
| `clean, -c` | 删除 `build` 目录 |
| `kernel, -k` | 仅编译内核 |
| `uboot, -u` | 仅编译 U-Boot |
| `server, -so` | 仅构建服务器版镜像 |
| `desktop, -do` | 仅构建桌面版镜像 |
| `help, -h` | 显示帮助 |

可选板卡：`lubancat-3`、`lubancat-3io`、`lubancat-4`、`lubancat-4io`、`lubancat-5`、`lubancat-5io`、`lubancat-5-v2`。

未配置板卡时执行构建会提示：
```
错误：尚未配置目标板，请先执行: sudo ./build.sh config
```

产物位于 `images/`，命名格式：

```
deepin-25-{server,desktop}-arm64-<board>.img.xz
deepin-25-{server,desktop}-arm64-<board>.img.xz.sha256
```
