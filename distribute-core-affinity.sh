queue=0
for iface in lan3 lan4 lan5 lan6; do
    for irq in $(grep "$iface-TxRx" /proc/interrupts | awk '{print $1}' | cut -d: -f1); do
        affinity=$((1 << queue % 4))
        echo "Setting IRQ $irq ($iface queue $queue) to CPU mask $affinity"
        echo $affinity > /proc/irq/$irq/smp_affinity
        ((queue++))
    done
done
