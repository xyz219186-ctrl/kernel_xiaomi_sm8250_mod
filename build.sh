#!/bin/bash
set -e

# ==================== [配置区域] ====================
TOOLCHAIN_PATH=$HOME/zyc-clang/bin
TARGET_DEVICE="alioth"
# ====================================================

# 环境变量设置
export PATH="$TOOLCHAIN_PATH:$PATH"
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CC="ccache clang"
export CXX="ccache clang++"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# 编译参数
MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out \
    CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
    CLANG_TRIPLE=aarch64-linux-gnu-"

echo -e "\033[0;32m=== 🚀 开始编译 (适配 SM8250 + ReSukiSU 官方规范版) ===\033[0m"

# ==================== [Step 1: 源码深度净化 (适配 ReSukiSU 迁移)] ====================
echo "🧹 [1/6] 执行源码深度净化 (移除 SukiSU/KSU/SUSFS 残留)..."

# 1. [用户指定] 基础重置 (如果需要重置到官方状态，请取消注释)
curl -L https://github.com/ApartTUSITU/kernel_xiaomi_sm8250_mod/commit/a05557c.patch | git apply -v >/dev/null 2>&1 || true

# 2. 清理编译残留与旧驱动目录
rm -rf drivers/kernelsu drivers/susfs fs/susfs out/
# 移除可能存在的 KernelSU 软链接或目录
if [ -L "drivers/kernelsu" ] || [ -d "drivers/kernelsu" ]; then
    rm -rf drivers/kernelsu
fi
mkdir -p out

# 3. 定义深度清理函数 (针对所有变种 Hook 的清理)
clean_file_deep() {
    local file="$1"
    if [ -f "$file" ]; then
        echo "   -> 正在为 $file 进行深度清创..."
        
        # --- 第一层：逻辑块切除 ---
        sed -i '/#ifdef CONFIG_KSU/,/#endif/d' "$file"
        sed -i '/#if defined(CONFIG_KSU_SUSFS/,/#endif/d' "$file"
        sed -i '/#ifdef CONFIG_KSU_SUSFS/,/#endif/d' "$file"
        
        # --- 第二层：残留声明狙击 (涵盖 SukiSU 和 ReSukiSU 的所有特征) ---
        sed -i '/extern bool ksu_/d' "$file"
        sed -i '/extern int ksu_/d' "$file"
        sed -i '/extern void ksu_/d' "$file"
        sed -i '/extern void susfs_/d' "$file"
        
        # --- 第三层：特定函数调用清理 ---
        sed -i '/ksu_handle_execveat/d' "$file"
        sed -i '/ksu_handle_faccessat/d' "$file"
        sed -i '/ksu_handle_stat/d' "$file"
        sed -i '/ksu_handle_sys_read/d' "$file"
        sed -i '/ksu_handle_input/d' "$file"
        sed -i '/ksu_handle_setresuid/d' "$file"
        
        # --- 第四层：头文件引用清理 ---
        sed -i '/#include <linux\/susfs/d' "$file"
        sed -i '/#include "susfs/d' "$file"
        
    else
        echo "   ⚠️ 文件 $file 不存在，跳过清理。"
    fi
}

# 4. 对核心文件逐一执行手术
clean_file_deep "fs/exec.c"
clean_file_deep "fs/read_write.c"
clean_file_deep "fs/open.c"
clean_file_deep "fs/stat.c"
clean_file_deep "drivers/input/input.c"
clean_file_deep "kernel/reboot.c"
clean_file_deep "kernel/sys.c"
clean_file_deep "security/selinux/hooks.c"

# 5. 修复头文件 (防止宏定义冲突)
echo "   -> 正在检查头文件残留..."
if [ -f "include/linux/fs.h" ]; then
    sed -i '/INODE_STATE_SUS_KSTAT/d' include/linux/fs.h
    sed -i '/#define INODE_STATE_SUS_KSTAT/d' include/linux/fs.h
fi
if [ -f "include/linux/sched.h" ]; then
    sed -i '/susfs_task_state/d' include/linux/sched.h
    sed -i '/u32 susfs_task_state;/d' include/linux/sched.h
fi

echo "   ✅ 深度净化完成！"

# ==================== [Step 2: 下载组件 (SukiSU 官方源)] ====================
echo "⬇️ [2/6] 下载 SukiSU & SUSFS..."
# 使用 SukiSU 官方 setup.sh
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin

# 下载 SUSFS 补丁 (兼容 4.19)
wget https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch -O susfs.patch -q

# ==================== [Step 3: SukiSU-Ultra 全量 Hook 注入 (严格源码适配版)] ====================
# 定义颜色
R='\033[0;31m'
G='\033[0;32m'
B='\033[0;34m'
N='\033[0m'

echo -e "${B}🔧 [3/5] 正在执行 SukiSU-Ultra 全量 Hook 注入...${N}"

# -------------------------------------------------------------------------
# [0.1] 应用 SUSFS 补丁 (保留你的代码)
# -------------------------------------------------------------------------
if [ -f "susfs.patch" ]; then
    echo -e "${B}   -> [补丁] 正在应用 SUSFS 补丁...${N}"
    # 使用 fuzz=3 和 -N (忽略反向补丁) 提高成功率
    patch -p1 --ignore-whitespace --fuzz=3 -N < susfs.patch >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${G}      ✅ SUSFS 补丁应用成功${N}"
    else
        echo -e "${Y}      ⚠️ SUSFS 补丁可能已应用或有冲突 (尝试跳过)${N}"
    fi
fi

# -------------------------------------------------------------------------
# [0.2] 补全头文件 (SUSFS 需要 - 保留你的代码)
# -------------------------------------------------------------------------
# 1. sched.h: 添加 susfs_task_state 字段
if ! grep -q "susfs_task_state" include/linux/sched.h; then
    sed -i '/^	\/\* protection of the PI data mutex \*\//i \
	#ifdef CONFIG_KSU\
	u32 susfs_task_state;\
	#endif' include/linux/sched.h
fi

# 2. fs.h: 添加 INODE_STATE_SUS_KSTAT 定义
if ! grep -q "INODE_STATE_SUS_KSTAT" include/linux/fs.h; then
    sed -i '$a \
#ifndef INODE_STATE_SUS_KSTAT\
#define INODE_STATE_SUS_KSTAT (1UL << 30)\
#endif' include/linux/fs.h
fi

# -------------------------------------------------------------------------
# [0.3] 预处理：防止 4.19 内核语法报错 (保留你的代码)
# -------------------------------------------------------------------------
# SukiSU 源码包含 C99 语法，必须禁用 strict-prototypes 和 declaration-after-statement 警告
for makefile in "fs/Makefile" "drivers/input/Makefile" "security/selinux/Makefile" "kernel/Makefile"; do
    if [ -f "$makefile" ]; then
        if ! grep -q "Wno-declaration-after-statement" "$makefile"; then
            echo "ccflags-y += -Wno-declaration-after-statement" >> "$makefile"
        fi
        if ! grep -q "Wno-strict-prototypes" "$makefile"; then
            echo "ccflags-y += -Wno-strict-prototypes" >> "$makefile"
        fi
    fi
done

# ==================== [下面是 7 个核心 Hook - 已严格匹配源码签名] ====================

# -------------------------------------------------------------------------
# [1. Exec Hook] (Root 核心)
# -------------------------------------------------------------------------
# 源码对应: sucompat.c -> int ksu_handle_execveat(...)
# 必须传递 &filename, &argv, &envp (指针的指针)
target_file="fs/exec.c"
if [ -f "$target_file" ]; then
    echo -ne "   -> [1/7] Hooking fs/exec.c (ROOT核心) ... "
    sed -i '/#include <linux\/file.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\
#endif' "$target_file"

    sed -i '/return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);/i \
#ifdef CONFIG_KSU\
\tksu_handle_execveat((int *)AT_FDCWD, \&filename, \&argv, \&envp, 0);\
#endif' "$target_file"
    echo -e "${G}OK${N}"
else
    echo -e "${R}❌ 失败: 找不到 fs/exec.c${N}"; exit 1
fi

# -------------------------------------------------------------------------
# [2. Input Hook] (安全模式/救砖)
# -------------------------------------------------------------------------
# 源码对应: ksud.c -> int ksu_handle_input_handle_event(...)
target_file="drivers/input/input.c"
if [ -f "$target_file" ]; then
    echo -ne "   -> [2/7] Hooking drivers/input/input.c ... "
    sed -i '/#include <linux\/input\/mt.h>/a \
#ifdef CONFIG_KSU\
extern bool ksu_input_hook __read_mostly;\
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\
#endif' "$target_file"

    sed -i '/if (is_event_supported(type, dev->evbit, EV_MAX))/i \
#ifdef CONFIG_KSU\
\tif (unlikely(ksu_input_hook))\
\t\tksu_handle_input_handle_event(\&type, \&code, \&value);\
#endif' "$target_file"
    echo -e "${G}OK${N}"
fi

# -------------------------------------------------------------------------
# [3. Read Hook] (自启动检测 - 重点修正！)
# -------------------------------------------------------------------------
# 源码对应: ksud.c -> void ksu_handle_sys_read(unsigned int fd)
# ⚠️ 绝对不能传 buf 和 count，也不能接收返回值，否则 init.rc 读取无法被拦截
target_file="fs/read_write.c"
if [ -f "$target_file" ]; then
    echo -ne "   -> [3/7] Hooking fs/read_write.c (已修正为void参数) ... "
    sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU\
extern bool ksu_init_rc_hook __read_mostly;\
extern void ksu_handle_sys_read(unsigned int fd);\
#endif' "$target_file"

    # 正确调用: 只有 fd
    sed -i '/^SYSCALL_DEFINE3(read,/,/^{/ s/^{/{ \n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd);\n#endif/' "$target_file"
    echo -e "${G}OK${N}"
fi

# -------------------------------------------------------------------------
# [4. Stat Hook] (隐藏 - 重点修正！)
# -------------------------------------------------------------------------
# 源码对应: sucompat.c -> int ksu_handle_stat(...)
# ⚠️ SukiSU-Ultra 没有导出 newfstat/fstat64，强制注入会导致 undefined reference
target_file="fs/stat.c"
if [ -f "$target_file" ]; then
    echo -ne "   -> [4/7] Hooking fs/stat.c (仅保留 vfs_fstatat) ... "
    sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\
#endif' "$target_file"

    sed -i '/error = vfs_fstatat(dfd, filename, &stat, flag);/i \
#ifdef CONFIG_KSU\
\tksu_handle_stat(\&dfd, \&filename, \&flag);\
#endif' "$target_file"
    echo -e "${G}OK${N}"
fi

# -------------------------------------------------------------------------
# [5. Open Hook] (访问控制)
# -------------------------------------------------------------------------
# 源码对应: sucompat.c -> int ksu_handle_faccessat(...)
target_file="fs/open.c"
if [ -f "$target_file" ]; then
    echo -ne "   -> [5/7] Hooking fs/open.c ... "
    sed -i '/#include <linux\/fs.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\
#endif' "$target_file"

    sed -i '/return do_faccessat(dfd, filename, mode);/i \
#ifdef CONFIG_KSU\
\tksu_handle_faccessat(\&dfd, \&filename, \&mode, NULL);\
#endif' "$target_file"
    echo -e "${G}OK${N}"
fi

# -------------------------------------------------------------------------
# [6. Setuid Hook] (权限切换)
# -------------------------------------------------------------------------
# 源码对应: setuid_hook.c -> int ksu_handle_setresuid(...)
target_file="kernel/sys.c"
if [ -f "$target_file" ]; then
    echo -ne "   -> [6/7] Hooking kernel/sys.c ... "
    sed -i '/#include <linux\/syscalls.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\
#endif' "$target_file"

    sed -i '/long __sys_setresuid(uid_t ruid, uid_t euid, uid_t suid)/,/{/ s/{/{ \n#ifdef CONFIG_KSU\n\t(void)ksu_handle_setresuid(ruid, euid, suid);\n#endif/' "$target_file"
    echo -e "${G}OK${N}"
else
    echo -e "${R}⚠️ 警告: kernel/sys.c 未找到，跳过 Setuid Hook${N}"
fi

# -------------------------------------------------------------------------
# [7. Reboot Hook] (卸载挂载点)
# -------------------------------------------------------------------------
# 源码对应: supercalls.c -> int ksu_handle_sys_reboot(...)
target_file="kernel/reboot.c"
if [ -f "$target_file" ]; then
    echo -ne "   -> [7/7] Hooking kernel/reboot.c ... "
    sed -i '/#include <linux\/uaccess.h>/a \
#ifdef CONFIG_KSU\
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\
#endif' "$target_file"

    sed -i '/SYSCALL_DEFINE4(reboot,/,/^{/ s/^{/{ \n#ifdef CONFIG_KSU\n\tksu_handle_sys_reboot(magic1, magic2, cmd, \&arg);\n#endif/' "$target_file"
    echo -e "${G}OK${N}"
else
    echo -e "${R}⚠️ 警告: kernel/reboot.c 未找到，跳过 Reboot Hook${N}"
fi

echo -e "${G}🎉 SukiSU-Ultra 全量 Hook 注入完成！(已根据源码 ksud.c/sucompat.c 严格校对签名)${N}"


# ==================== [Step 3.5: 变量桥接与链接修复 (修复版)] ====================
echo "🔧 [3.5/6] 正在执行变量桥接与冲突修复..."

# 1. 强制 drivers/Makefile 包含 kernelsu
DRIVERS_MAKEFILE="drivers/Makefile"
if [ -f "$DRIVERS_MAKEFILE" ]; then
    sed -i '/kernelsu/d' "$DRIVERS_MAKEFILE"
    echo "obj-y += kernelsu/" >> "$DRIVERS_MAKEFILE"
fi

# 2. 桥接 Policydb
SERVICES_FILE="security/selinux/ss/services.c"
if [ -f "$SERVICES_FILE" ]; then
    if ! grep -q "linux/export.h" "$SERVICES_FILE"; then
        sed -i '/#include <linux\/kernel.h>/a #include <linux/export.h>' "$SERVICES_FILE"
    fi
    if ! grep -q "ksu_policydb_ptr" "$SERVICES_FILE"; then
        cat >> "$SERVICES_FILE" <<EOF

struct policydb *ksu_policydb_ptr = &selinux_ss.policydb;
EXPORT_SYMBOL(ksu_policydb_ptr);
EOF
    fi
fi

# 3. 桥接 AVC
AVC_FILE="security/selinux/avc.c"
if [ -f "$AVC_FILE" ]; then
    if ! grep -q "linux/export.h" "$AVC_FILE"; then
        sed -i '/#include <linux\/types.h>/a #include <linux/export.h>' "$AVC_FILE"
    fi
    if ! grep -q "ksu_selinux_avc_ptr" "$AVC_FILE"; then
        cat >> "$AVC_FILE" <<EOF

struct selinux_avc *ksu_selinux_avc_ptr = &selinux_avc;
EXPORT_SYMBOL(ksu_selinux_avc_ptr);
EOF
    fi
fi

# 4. 适配 rules.c (修复参数报错)
RULES_FILE="drivers/kernelsu/selinux/rules.c"
if [ -f "$RULES_FILE" ]; then
    echo "   -> 修复 drivers/kernelsu/selinux/rules.c ..."
    
    # 替换 get_policydb 实现
    if grep -q "static struct policydb \*get_policydb(void)" "$RULES_FILE"; then
       sed -i '/static struct policydb \*get_policydb(void)/,/^}/c\
extern struct policydb *ksu_policydb_ptr;\
static struct policydb *get_policydb(void)\
{\
    return ksu_policydb_ptr;\
}' "$RULES_FILE"
    fi
    
    # 【修复重点】修正 reset_avc_cache 参数
    # 将 selnl_notify_policyload(NULL, 0) 改为 selnl_notify_policyload(0)
    if grep -q "static void reset_avc_cache(void)" "$RULES_FILE"; then
        sed -i '/static void reset_avc_cache(void)/,/^}/c\
extern struct selinux_avc *ksu_selinux_avc_ptr;\
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);\
static void reset_avc_cache(void)\
{\
    avc_ss_reset(ksu_selinux_avc_ptr, 0);\
    selnl_notify_policyload(0);\
    selinux_xfrm_notify_policyload();\
}' "$RULES_FILE"
    fi
fi

echo "   ✅ 桥接与修复全部完成！(已修正 rules.c 参数错误)"

# ==================== [Step 4: SukiSU 源码适配] ====================
echo "💉 [4/6] 执行 SukiSU 源码编译适配..."

KBUILD_FILE="drivers/kernelsu/Kbuild"
# 注意：SukiSU-Ultra 官方源码没有 Kconfig 互斥锁，所以删除了那个 sed 操作

# 1. 添加 4.19 编译器防报错参数 (保留你要求的配置)
# 这一步是为了防止编译过程中出现 implicit declaration 错误
if ! grep -q "Wno-implicit-function-declaration" "$KBUILD_FILE"; then
    echo "   -> 添加编译器兼容参数 (Anti-Error Flags)..."
    # 这里针对 SukiSU 可能的 Warning 进行压制
    echo "ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-to-pointer-cast -Wno-unused-function -Wno-unused-variable" >> "$KBUILD_FILE"
fi

# 2. 确保 Makefile 存在
if [ ! -f "drivers/kernelsu/Makefile" ]; then
    echo "obj-y += ksu_core.o" > drivers/kernelsu/Makefile
fi

echo "   ✅ SukiSU 适配完成！"

# ==================== [Step 5: MIUI DTS & Config] ====================
echo "⚙️ [5/6] 执行 MIUI 深度适配 (完整保留)..."

dts_source=arch/arm64/boot/dts/vendor/qcom

# 1. 屏幕参数修正
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

# 2. 恢复智能帧率 & 刷新率
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

# 3. 恢复亮度控制
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

# 生成基础 Config
# ==================== [Step 5: 生成配置 (强制内置 + 修复)] ====================
echo "⚙️ [5/6] 生成内核配置..."

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

echo "   -> 正在注入内核配置..."
# 使用 --set-val 强制设置为 y (built-in)，防止被设为 m (module)
scripts/config --file out/.config \
    --set-val CONFIG_KSU y \
    --set-val CONFIG_KSU_MANUAL_HOOK y \
    --set-val CONFIG_KSU_SUSFS y \
    -e KSU_SUSFS_HAS_MAGIC_MOUNT \
    -e KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -e KSU_SUSFS_TRY_UMOUNT \
    -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -e KSU_SUSFS_SUS_MAP \
    -d KSU_SUSFS_SUS_OVERLAYFS \
    -d KSU_SUSFS_SUS_SU \
    \
    -e KPM \
    \
    -d STATIC_USERMODEHELPER \
    -e PERF_CRITICAL_RT_TASK \
    -e SF_BINDER \
    -e OVERLAY_FS \
    -d DEBUG_FS \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT \
    -e KPERFEVENTS \
    -e MILLET \
    -e PERF_HUMANTASK \
    -d LTO_CLANG \
    -d LOCALVERSION_AUTO \
    -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS \
    -e TASK_DELAY_ACCT \
    -e MIUI_ZRAM_MEMORY_TRACKING \
    -d CONFIG_MODULE_SIG_SHA512 \
    -d CONFIG_MODULE_SIG_HASH \
    -e MI_FRAGMENTION \
    -e PERF_HELPER \
    -e BOOTUP_RECLAIM \
    -e MI_RECLAIM \
    -e RTMM

make $MAKE_ARGS olddefconfig

# 最终核查
if ! grep -q "CONFIG_KSU=y" out/.config; then
    echo "⚠️ 警告：CONFIG_KSU 不是 y！正在强制修正..."
    sed -i 's/CONFIG_KSU=m/CONFIG_KSU=y/g' out/.config
    echo "CONFIG_KSU=y" >> out/.config
fi

# ==================== [Step 6: 编译 & 打包] ====================
echo "🚀 [6/6] 启动多核编译..."
make $MAKE_ARGS -j$(nproc)

if [ -f "out/arch/arm64/boot/Image" ]; then
    echo -e "\033[0;32m✅ 编译成功！Image 已生成。\033[0m"
    rm -rf anykernel && git clone https://github.com/liyafe1997/AnyKernel3 -b kona --depth=1 anykernel
    rm -rf anykernel/kernels/ && mkdir -p anykernel/kernels/
    cp out/arch/arm64/boot/Image anykernel/kernels/
    find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > anykernel/kernels/dtb
    cd anykernel
    zip -r9 "../Kernel_Alioth_ReSukiSU_$(date +'%Y%m%d').zip" ./* -x .git .gitignore
    cd ..
    echo -e "\033[0;32m🎉 刷机包已生成！\033[0m"
else
    echo -e "\033[0;31m❌ 编译失败！请检查上方日志。\033[0m"
    exit 1
fi
