---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: d416cdbc31135fae8f7b0f5b78e64e94_48ada679acd811f1af37525400826444
    ReservedCode1: arzJhSX3fQ9ml7bWqVnk2nCRsUiuPPb+J3yBjFwZJqnZG6drlzV/ZQJ0IcC60k2jA3KeTcaMklssBd27il6BcOqGpSpgJSc2JZenHrF6qQ+kexOI7+86vBgqV3tJTiNHkau2K5f/1Uq5IU/WSyF1G1koBUYRSRSyv7zj3WVjQKEJisbuBObVYOshkkM=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: d416cdbc31135fae8f7b0f5b78e64e94_48ada679acd811f1af37525400826444
    ReservedCode2: arzJhSX3fQ9ml7bWqVnk2nCRsUiuPPb+J3yBjFwZJqnZG6drlzV/ZQJ0IcC60k2jA3KeTcaMklssBd27il6BcOqGpSpgJSc2JZenHrF6qQ+kexOI7+86vBgqV3tJTiNHkau2K5f/1Uq5IU/WSyF1G1koBUYRSRSyv7zj3WVjQKEJisbuBObVYOshkkM=
---

# WeMM 素材检索 · 一键部署

一个跑在自己电脑上的 **AI 素材检索工具**：用中文描述画面内容（如"工厂流水线设备""海边日落"），即可在你的图片 / 视频素材库中按画面语义检索，不需要给文件起名、打标签。

- 界面：Electron + Vue3 桌面程序（免安装绿色版）
- 后端：本地 Python 服务，向量模型 [WeMM-Embedding-4B](https://hf-mirror.com/tencent/WeMM-Embedding-4B)（4bit 量化，约 9.66 GB）
- 全部在本机运行，不上传你的素材，不依赖任何在线服务额度

本仓库提供**一键部署脚本与配套工具**，让没有开发环境的人也能在自己的 Windows 电脑上把环境、模型、程序一次装好。

---

## 一、下载与安装

### 1. 先下载完整部署包（必需）

程序本体（约 260 MB 绿色版）体积较大，放在 **Releases** 中，不在本仓库里：

**→ 前往 [Releases](../../releases/latest) 下载 `WeMM素材检索-一键部署包-v1.0.0.zip`**

压缩包解压后约 300 MB，包含：

```
WeMM素材检索-一键部署包\
├─ 一键部署.bat          ← 双击这个就能装
├─ deploy_wemm.ps1       ← 部署主脚本（本仓库同步维护）
├─ README.md
├─ app\win-unpacked\     ← 免安装绿色版程序
└─ tools\                ← 检测 / 下载 / 索引初始化脚本
```

### 2. 双击部署

1. 把压缩包**完整解压**到任意目录（例：`D:\WeMM-Deploy`，路径避免特殊符号）；
2. 双击 **`一键部署.bat`**，按中文提示等待（首次约 30～90 分钟，取决于网速）。

脚本会自动完成 8 个环节，**每一步都先检测现状，已装好的自动跳过；中途关闭窗口后再次双击可从断点继续**：

| 步骤 | 内容 |
| --- | --- |
| 1 | 环境预检：NVIDIA 显卡与显存、磁盘可用空间、系统与 Python |
| 2 | 创建独立 Python 环境（不污染系统 Python；缺少 Python 3.11 时自动静默安装） |
| 3 | 用国内镜像安装后端依赖（清华 PyPI + 上海交大 PyTorch cu128 版 torch） |
| 4 | 从 hf-mirror.com 下载模型权重（约 9.66 GB，支持断点续传与字节级校验） |
| 5 | 初始化索引目录与素材库目录 |
| 6 | 部署免安装绿色版程序 |
| 7 | 生成启动器与桌面快捷方式 |
| 8 | 输出部署报告（各目录、占用、跳过项、日志位置） |

### 3. 开始使用

1. 双击桌面 **「WeMM素材检索」** 快捷方式（首次启动加载模型约 1 分钟，界面显示"模型加载中"）；
2. 把图片 / 视频**拖进窗口** → 点右上角 **「导入文件」** → 等进度条走完（导入会把素材复制到素材库目录并建立索引）；
3. 在搜索框输入中文描述回车，即可按画面内容检索。

> 已有大批素材、不想再复制一份？用原位索引（只读原文件、不复制不移动）：
> ```
> 一键部署.bat -SourceDir "你的素材目录"
> ```

---

## 二、硬件与系统要求

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| 操作系统 | Windows 10 / 11（64 位） | 已在 Windows 11 验证 |
| 显卡 | **NVIDIA 独显（必须）** | 后端使用 CUDA 推理，AMD / Intel 显卡不可用 |
| 显存 | **≥ 8 GB** | 模型以 4bit 量化加载；低于 8 GB 脚本会明确提示，可选择中止 |
| 显卡驱动 | 较新版本 | 命令行 `nvidia-smi` 能正常输出即可，报驱动过旧请先更新 |
| 磁盘空间 | **≥ 20 GB，建议预留 25 GB** | 模型 9.66 GB + 依赖约 4.7 GB + 程序 0.26 GB + 索引/缩略图 |
| 内存 | 建议 ≥ 16 GB | 8 GB 可运行，导入大批素材时较慢 |
| 网络 | 需联网，全程下载约 14.5 GB | 全部走国内镜像，无需科学上网 |
| 权限 | 普通用户即可 | 免安装绿色版不写注册表、不装服务、不需要管理员权限 |

> 当前版本后端推理固定跑在 `cuda:0`，**未内置纯 CPU 慢速模式**；没有 N 卡或显存不足需要二次开发才能适配。

---

## 三、仓库内容说明

本仓库只放**源码 / 脚本 / 文档**，程序与模型等大文件通过 Releases 分发：

| 路径 | 内容 |
| --- | --- |
| `一键部署.bat` | 部署入口（双击运行，支持参数透传） |
| `deploy_wemm.ps1` | 部署主脚本（预检 / 安装 / 下载 / 配置，幂等可重跑） |
| `tools/check_python.py` | 探测系统 Python 版本（3.10～3.12 可用） |
| `tools/check_env.py` | 依赖与 CUDA 自检（决定依赖环节是否跳过） |
| `tools/requirements-lock.txt` | 依赖锁定清单 |
| `tools/download_model.py` | 模型权重下载器（幂等 / 断点续传 / 国内镜像 / 禁用 xet） |
| `tools/model_manifest.json` | 模型文件清单与字节数（完整性校验） |
| `tools/init_index.py` | 索引目录初始化与校验（空索引也可先用导入功能建库） |
| `tools/build_index_local.py` | 可选：为已有素材目录原位批量建索引（不复制文件） |

> 本仓库**不含**：绿色版程序（`app/win-unpacked`）、部署包 zip、模型权重、向量索引、日志 —— 这些体积过大，请从 Releases 获取或由脚本自动下载（相关路径已写入 `.gitignore`）。

---

## 四、常见问题（FAQ）

| 现象 | 处理 |
| --- | --- |
| 双击 bat 窗口一闪而过 | 改用右键「在终端中运行」，或执行 `powershell -ExecutionPolicy Bypass -File deploy_wemm.ps1` 查看完整报错 |
| 提示"未检测到 NVIDIA 显卡" | 确认是 N 卡且驱动已装（`nvidia-smi` 有输出）；确实有卡但读不到可加 `-Force` 跳过检查 |
| 提示"显存低于 8GB" | 脚本会暂停等你决定：继续（可能加载失败）或换机器 |
| 提示磁盘空间不足 | 清理磁盘或换盘：`一键部署.bat -InstallDir E:\WeMM-Embedding` |
| 依赖安装中断 | 脚本自带 pip 重试与镜像回退，**直接重跑即可续装**（日志：部署目录 `pip_install.log`） |
| 模型下载中断 | 重跑会断点续传，不会从头下载（日志：`model_download.log`） |
| 程序提示显存不足 | 关闭其它占显存的程序（浏览器视频 / 游戏 / 其它 AI 工具）后重试；程序有单实例锁，重复双击不会叠加占用 |
| 首次搜索很慢 | 模型预热需 1～2 分钟，之后正常 |
| 搜索不到刚导入的素材 | 确认导入进度已完成，再点一次搜索 |
| 想换安装位置 | `一键部署.bat -InstallDir E:\WeMM-Embedding -AppDir E:\WeMM-App -LibraryDir E:\MyMedia`（脚本会自动重建启动器与快捷方式） |
| 能否离线部署 | 可以：在有网机器上完整部署一次，之后把部署目录 + 程序目录整体拷贝到离线机器，用生成的启动器启动 |

### 安装路径可自定义

脚本默认把环境与模型放在 **`D:\WeMM-Embedding`**、素材库放在 **`D:\Downloads`**（没有 D 盘时自动退回 C 盘 / 当前用户目录），这些都是**可自定义的默认值**，不是硬编码约束：

```
一键部署.bat [-InstallDir 部署目录] [-AppDir 程序目录] [-LibraryDir 素材库目录]
             [-SourceDir 已有素材目录] [-Force] [-NoShortcut] [-SkipAppInstall]
             [-Launch] [-DryRun]
```

- `-DryRun`：只做预检并打印计划，不安装、不下载、不复制任何东西（推荐先跑一次确认环境）；
- 自定义路径时，脚本会在程序目录生成 `启动WeMM素材检索.cmd`，把本机实际的 Python / 模型 / 索引 / 素材库路径写进去，程序通过环境变量读取，无需改动源码。

### 卸载

绿色版不写注册表、不装服务，卸载即"删目录"：

1. 删除桌面快捷方式；
2. 删除程序目录（默认 `D:\WeMM-Embedding\app`）→ 程序本体卸载完成；
3. 不再使用时删除部署目录（含 Python 环境、模型、索引，约 15 GB）；
4. 素材库目录（默认 `D:\Downloads`）含导入时复制的素材，请自行确认后再清理。

### 网络说明

- 程序只在本机内部通信（界面 ↔ 本地后端），**不需要放行端口、不需要改防火墙**；
- 部署阶段需访问：`pypi.tuna.tsinghua.edu.cn`、`mirror.sjtu.edu.cn`、`hf-mirror.com`、`mirrors.huaweicloud.com`（自动安装 Python 时使用），公司网络如有白名单请提前放行。

---

## 五、许可

本项目以 [MIT License](LICENSE) 开源。模型权重版权与许可遵循其原始发布方说明（`tencent/WeMM-Embedding-4B`）。
*（内容由AI生成，仅供参考）*
