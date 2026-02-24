cd ~/Desktop/Work/hands-on-projects/talos-hands-on

for CLUSTER in dev staging prod; do
  case $CLUSTER in
    dev)     SUBNET="192.168.101" ;;
    staging) SUBNET="192.168.102" ;;
    prod)    SUBNET="192.168.103" ;;
  esac

  cat > configs/net-${CLUSTER}.xml <<EOF
<network>
  <name>talos-${CLUSTER}</name>
  <forward mode='nat'/>
  <bridge name='virbr-${CLUSTER}' stp='on' delay='0'/>
  <ip address='${SUBNET}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${SUBNET}.10' end='${SUBNET}.50'/>
    </dhcp>
  </ip>
</network>
EOF

  sudo virsh net-define configs/net-${CLUSTER}.xml
  sudo virsh net-start talos-${CLUSTER}
  sudo virsh net-autostart talos-${CLUSTER}
  echo "Network talos-${CLUSTER} created (${SUBNET}.0/24)"
done

# Verify networks
sudo virsh net-list --all
