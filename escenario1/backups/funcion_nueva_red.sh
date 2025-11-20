generar_interfaces_debian() {
    local file="$1"
    declare -n cfg="$2"

    # Detectar si es Proxmox VE
    local is_proxmox=0
    if [[ -f /etc/pve ]] || command -v pveversion >/dev/null 2>&1 || grep -q "^pve" /etc/hosts 2>/dev/null; then
        is_proxmox=1
    fi

    if [[ -f "$file" ]]; then
        sudo cp "$file" "${file}.bak_$(date +%F_%T)"
        echo "[*] Copia de seguridad creada: ${file}.bak_$(date +%F_%T)"
    fi

    {
        echo "# Archivo generado automáticamente por configurar_red.sh - $(date)"
        echo "source /etc/network/interfaces.d/*"
        echo
        echo "auto lo"
        echo "iface lo inet loopback"
        echo

        if (( is_proxmox )); then
            echo "# Configuración para Proxmox VE"
            echo "auto ens18"
            echo "iface ens18 inet manual"
            echo
            echo "auto vmbr0"
            echo "iface vmbr0 inet dhcp"
            echo "    bridge-ports ens18"
            echo "    bridge-stp off"
            echo "    bridge-fd 0"
            echo
        else
            echo "# Configuración estándar Debian"
            echo "auto ens18"
            echo "iface ens18 inet dhcp"
            echo
        fi

        # Interfaces adicionales estáticas (LANs, VLANs, etc.)
        for iface in "${!cfg[@]}"; do
            ip_addr="${cfg[$iface]}"
            echo "auto $iface"
            echo "iface $iface inet static"
            echo "    address $ip_addr"
            # Aquí puedes añadir gateway, dns, etc. si lo necesitas
            echo
        done

    } | sudo tee "$file" > /dev/null

    echo "[✓] Archivo de configuración generado en: $file"
    
    if (( is_proxmox )); then
        echo "[i] En Proxmox es más seguro aplicar con: ifreload -a  o reiniciar el nodo"
        echo "[!] Ejecutando: ifreload -a"
        sudo ifreload -a
    else
        echo "[!] Ejecutando: sudo systemctl restart networking"
        sudo systemctl restart networking.service
    fi
    echo
}