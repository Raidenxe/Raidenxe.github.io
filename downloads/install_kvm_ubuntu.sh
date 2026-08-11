#!/bin/bash
# Ubuntu KVM/QEMU 自动安装脚本（幂等版 + 架构检查）
# 适用版本：Ubuntu 20.04 / 22.04 / 24.04 / 26.04
# 特性：检测已安装组件，跳过重复安装，自动修复常见问题
# Author: Raiden
# Created: 2026-06-23
# Updated: 2026-06-24 (改进版本)
# Version: v1.1.0
# Description: 自动完成KVM/QEMU安装并自动解决相关报错问题

set -e

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m' 
NC='\033[0m'

# ---------- 辅助函数 ----------
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "\n${BLUE}==== $1 ====${NC}"; }
print_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; }

# ---------- 权限检查 ----------
if [ "$EUID" -ne 0 ]
    then
    SUDO="sudo"
else
    SUDO=""
fi

# 获取当前实际用户（兼容 sudo 和非 sudo 执行）
CURRENT_USER=${SUDO_USER:-$USER}

# ---------- 1. 检查 CPU 虚拟化支持 ----------
print_step "检查 CPU 虚拟化支持"
if grep -Eq '(vmx|svm)' /proc/cpuinfo
    then
    print_ok "CPU 支持硬件虚拟化"
else
    print_error "CPU 不支持硬件虚拟化，请检查 BIOS 设置 (Intel VT-x / AMD SVM)"
    exit 1
fi

# ---------- 2. 检测已安装组件 ----------
print_step "检测 KVM/QEMU 组件安装状态"

PKG_QEMU="qemu-system-x86"
PKG_LIBVIRT="libvirt-daemon-system"
PKG_VIRT_MANAGER="virt-manager"

# 检查软件包安装状态（输出 1 表示已安装，0 表示未安装）
QEMU_INSTALLED=$(dpkg-query -W -f='${Status}' "$PKG_QEMU" 2>/dev/null | grep -c "install ok installed")
LIBVIRT_INSTALLED=$(dpkg-query -W -f='${Status}' "$PKG_LIBVIRT" 2>/dev/null | grep -c "install ok installed")
VIRT_MANAGER_INSTALLED=$(dpkg-query -W -f='${Status}' "$PKG_VIRT_MANAGER" 2>/dev/null | grep -c "install ok installed")

# 检查 libvirtd 服务状态
LIBVIRTD_ACTIVE=$(systemctl is-active libvirtd 2>/dev/null || echo "inactive")
LIBVIRTD_ENABLED=$(systemctl is-enabled libvirtd 2>/dev/null || echo "disabled")

# 检查用户、组、内核模块
LIBVIRT_QEMU_EXISTS=$(id "libvirt-qemu" &>/dev/null && echo "yes" || echo "no")
USER_IN_LIBVIRT_GROUP=$(groups "$CURRENT_USER" 2>/dev/null | grep -q "libvirt" && echo "yes" || echo "no")
USER_IN_KVM_GROUP=$(groups "$CURRENT_USER" 2>/dev/null | grep -q "kvm" && echo "yes" || echo "no")
KVM_LOADED=$(lsmod | grep -q kvm && echo "yes" || echo "no")

# 输出当前状态
print_info "软件包状态："
echo -e "  qemu-system-x86       : $([ "$QEMU_INSTALLED" -eq 1 ] && echo "${GREEN}已安装${NC}" || echo "${RED}未安装${NC}")"
echo -e "  libvirt-daemon-system : $([ "$LIBVIRT_INSTALLED" -eq 1 ] && echo "${GREEN}已安装${NC}" || echo "${RED}未安装${NC}")"
echo -e "  virt-manager          : $([ "$VIRT_MANAGER_INSTALLED" -eq 1 ] && echo "${GREEN}已安装${NC}" || echo "${RED}未安装${NC}")"
print_info "服务状态："
echo -e "  libvirtd 运行中      : $([ "$LIBVIRTD_ACTIVE" = "active" ] && echo "${GREEN}是${NC}" || echo "${RED}否${NC}")"
echo -e "  libvirtd 开机自启    : $([ "$LIBVIRTD_ENABLED" = "enabled" ] && echo "${GREEN}是${NC}" || echo "${RED}否${NC}")"
print_info "系统配置："
echo -e "  libvirt-qemu 用户    : $([ "$LIBVIRT_QEMU_EXISTS" = "yes" ] && echo "${GREEN}存在${NC}" || echo "${RED}缺失${NC}")"
echo -e "  当前用户在 libvirt 组: $([ "$USER_IN_LIBVIRT_GROUP" = "yes" ] && echo "${GREEN}是${NC}" || echo "${RED}否${NC}")"
echo -e "  当前用户在 kvm 组    : $([ "$USER_IN_KVM_GROUP" = "yes" ] && echo "${GREEN}是${NC}" || echo "${RED}否${NC}")"
echo -e "  KVM 内核模块已加载  : $([ "$KVM_LOADED" = "yes" ] && echo "${GREEN}是${NC}" || echo "${RED}否${NC}")"

# ---------- 3. 判断是否需要安装软件包 ----------
NEED_INSTALL=false
if [[ "$QEMU_INSTALLED" -eq 0 ]] || [[ "$LIBVIRT_INSTALLED" -eq 0 ]] || [[ "$VIRT_MANAGER_INSTALLED" -eq 0 ]]
    then
    NEED_INSTALL=true
fi

if [ "$NEED_INSTALL" = true ]; then
    print_step "开始安装缺失的软件包"
    print_info "更新软件包列表..."
    if ! $SUDO apt update -y
        then
        print_error "apt update 失败，请检查网络或软件源配置"
        exit 1
    fi
    
    print_info "安装 KVM/QEMU 相关软件包..."
    if ! $SUDO apt install -y qemu-system-x86 libvirt-daemon-system libvirt-clients bridge-utils virt-manager virt-viewer virt-install
        then
        print_error "软件包安装失败，请检查错误信息"
        exit 1
    fi
    print_ok "软件包安装完成"
else
    print_skip "所有软件包已安装，跳过安装步骤"
fi

# ---------- 4. 检查并修复 libvirt-qemu 用户 ----------
print_step "检查 libvirt-qemu 用户"
if [[ "$LIBVIRT_QEMU_EXISTS" = "no" ]]; then
    print_warn "用户 libvirt-qemu 不存在，正在创建..."
    # 使用 -r 创建系统用户，自动创建同名系统组，禁止登录，设置家目录
    if ! $SUDO useradd -r -s /usr/sbin/nologin -d /var/lib/libvirt libvirt-qemu; then
        print_error "创建 libvirt-qemu 用户失败"
        exit 1
    fi
    print_ok "用户 libvirt-qemu 创建成功"
    # 更新变量，供后续使用（虽然本脚本后续未再使用，但保持一致性）
    LIBVIRT_QEMU_EXISTS="yes"
else
    print_skip "用户 libvirt-qemu 已存在"
fi

# ---------- 5. 配置用户组权限 ----------
print_step "配置用户组权限"
NEED_RELOGIN=false

# 添加当前用户到 libvirt 组
if [[ "$USER_IN_LIBVIRT_GROUP" = "no" ]]
    then
    print_warn "用户 $CURRENT_USER 不在 libvirt 组，正在添加..."
    if ! $SUDO usermod -aG libvirt "$CURRENT_USER"; then
        print_error "添加用户 $CURRENT_USER 到 libvirt 组失败"
        exit 1
    fi
    print_ok "用户 $CURRENT_USER 已添加到 libvirt 组"
    NEED_RELOGIN=true
    USER_IN_LIBVIRT_GROUP="yes"   # 更新变量
else
    print_skip "用户 $CURRENT_USER 已在 libvirt 组"
fi

# 添加当前用户到 kvm 组
if [[ "$USER_IN_KVM_GROUP" = "no" ]]
    then
    print_warn "用户 $CURRENT_USER 不在 kvm 组，正在添加..."
    if ! $SUDO usermod -aG kvm "$CURRENT_USER"; then
        print_error "添加用户 $CURRENT_USER 到 kvm 组失败"
        exit 1
    fi
    print_ok "用户 $CURRENT_USER 已添加到 kvm 组"
    NEED_RELOGIN=true
    USER_IN_KVM_GROUP="yes"
else
    print_skip "用户 $CURRENT_USER 已在 kvm 组"
fi

# ---------- 6. 启动并启用 libvirtd 服务 ----------
print_step "确保 libvirtd 服务运行"
if [ "$LIBVIRTD_ENABLED" != "enabled" ]
    then
    print_info "设置 libvirtd 开机自启..."
    if ! $SUDO systemctl enable libvirtd
        then
        print_error "设置 libvirtd 开机自启失败"
        exit 1
    fi
    print_ok "libvirtd 已设置为开机自启"
    LIBVIRTD_ENABLED="enabled"
else
    print_skip "libvirtd 已设置为开机自启"
fi

if [ "$LIBVIRTD_ACTIVE" != "active" ]
    then
    print_info "启动 libvirtd 服务..."
    if ! $SUDO systemctl restart libvirtd
        then
        print_error "启动 libvirtd 服务失败"
        exit 1
    fi
    print_ok "libvirtd 已启动"
    LIBVIRTD_ACTIVE="active"
else
    print_skip "libvirtd 已在运行"
fi

sleep 2

# ---------- 7. 验证 libvirtd 服务 ----------
print_step "验证 libvirtd 服务"
if systemctl is-active --quiet libvirtd
    then
    print_ok "libvirtd 服务正在运行"
else
    print_error "libvirtd 服务未正常运行，请查看日志：journalctl -u libvirtd -n 20"
    print_info "尝试手动启动：sudo systemctl start libvirtd"
    exit 1
fi

# ---------- 8. 测试 virsh 连接 ----------
print_step "测试 virsh 连接"
if $SUDO virsh list --all &>/dev/null
    then
    print_ok "virsh 连接成功"
else
    print_error "virsh 连接失败，请检查 libvirt 配置"
    exit 1
fi

# ---------- 9. 检查 KVM 内核模块 ----------
print_step "检查 KVM 内核模块"
if [ "$KVM_LOADED" = "yes" ]
    then
    print_skip "KVM 内核模块已加载"
else
    print_warn "KVM 内核模块未加载，尝试加载..."
    $SUDO modprobe kvm
    $SUDO modprobe kvm_intel 2>/dev/null || $SUDO modprobe kvm_amd 2>/dev/null
    if lsmod | grep -q kvm
        then
        print_ok "KVM 内核模块加载成功"
    else
        print_error "加载 KVM 内核模块失败"
        exit 1
    fi
fi

# ---------- 10. 检查 virt-manager ----------
print_step "检查 virt-manager"
if command -v virt-manager &>/dev/null
    then
    print_ok "virt-manager 已安装，你可以从应用菜单或终端运行 'virt-manager'"
else
    print_warn "virt-manager 命令未找到，但已安装软件包，请检查 PATH 或是否安装正确"
fi

# ---------- 11. 输出完成信息 ----------
print_step "安装/检查完成！"
echo -e "${GREEN}所有组件状态正常。${NC}"
echo ""
echo "后续操作建议："
if [ "$NEED_RELOGIN" = true ]
    then
    echo -e "${YELLOW}⚠ 用户组权限已更新，请执行以下任一操作使组权限生效：${NC}"
    echo "  1. 注销当前用户并重新登录（或重启系统）。"
    echo "  2. 在当前会话中执行以下命令（仅对当前终端有效）："
    echo "     newgrp libvirt"
    echo "     newgrp kvm"
    echo "   （注意：newgrp 会启动新的子 shell，执行完后需 exit 返回原 shell）"
else
    echo "✓ 用户组权限已正确配置，无需重新登录。"
fi
echo "  - 运行 virt-manager 打开图形化管理界面。"
echo "  - 如需桥接网络，请参考文档配置 /etc/netplan/*.yaml。"
echo ""
print_info "验证命令："
echo "  virsh list --all"
echo "  sudo systemctl status libvirtd"
echo ""
print_ok "脚本执行完毕！"
exit 0