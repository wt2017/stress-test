#!/bin/bash
echo "=== PCIe地址 ↔ 网络接口映射表 ==="
echo ""

# 遍历所有网络接口
for iface in $(ls /sys/class/net/ | grep -v lo); do
    # 获取PCI地址
    pci_path=$(readlink -f /sys/class/net/$iface/device 2>/dev/null)
    if [ -n "$pci_path" ]; then
        pci_addr=$(basename $pci_path)
        
        # 获取MAC地址
        mac=$(cat /sys/class/net/$iface/address 2>/dev/null)
        
        # 获取链路状态
        state=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
        
        echo "接口: $iface"
        echo "  PCI地址: $pci_addr"
        echo "  MAC地址: $mac"
        echo "  链路状态: $state"
        
        # 显示PCIe链路信息
        link_info=$(lspci -vvv -s $pci_addr 2>/dev/null | grep -i "lnksta:" | head -1)
        if [ -n "$link_info" ]; then
            echo "  PCIe链路: $link_info"
        fi
        
        echo ""
    fi
done
