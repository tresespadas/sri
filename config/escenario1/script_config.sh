#!/usr/bin/env bash
set -euo pipefail

NETPLAN_FILE="/etc/netplan/99-interfaces.yaml"
DEBIAN_FILE="/etc/network/interfaces"
OS="Desconocido"

detectar_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "[+] Detectando el sistema operativo..."
        if [[ "$NAME" == *"Ubuntu"* ]]; then
            OS="Ubuntu"
        elif [[ "$NAME" == *"Debian"* ]]; then
            OS="Debian"
        fi
        echo "[+] Sistema Operativo detectado: $OS"
    else
        echo "[!] No se puede determinar el sistema operativo."
        exit 1
    fi
}

establecer_interfaces() {
    mapfile -t interfaces < <(ip -br a | awk 'NR>2 {print $1}')

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo "[!] No se encontraron interfaces válidas."
        exit 1
    fi

    echo "[+] Interfaces detectadas:"
    for i in "${!interfaces[@]}"; do
        printf "   %d) %s\n" "$((i+1))" "${interfaces[$i]}"
    done

    while true; do
        echo
        read -rp "[+] ¿Cuántas interfaces quieres configurar?: " num_ifaces
        if ! [[ "$num_ifaces" =~ ^[0-9]+$ ]]; then
            echo "[!] Número inválido"
            continue
        fi

        declare -A iface_config

        for ((n=1; n<=num_ifaces; n++)); do
            echo
            echo "[+] Configurando interfaz #$n"

            read -rp "    → Número de interfaz (índice del listado): " idx
            if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
                echo "[!] Índice inválido"
                exit 1
            fi

            iface_index=$((idx - 1))
            if (( iface_index < 0 || iface_index >= ${#interfaces[@]} )); then
                echo "[!] No existe una interfaz con ese número ($idx)"
                exit 1
            fi

            base_iface="${interfaces[$iface_index]}"
            echo "    → Se configurará la interfaz: $base_iface"

            read -rp "    → Dirección IP/CIDR para $base_iface: " ip_iface
            if ! [[ "$ip_iface" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                echo "[!] IP inválida"
                exit 1
            fi

            iface_config["$base_iface"]="$ip_iface"
        done

        echo
        echo "==============================="
        echo " Resumen de las interfaces a configurar:"
        echo "==============================="
        for iface in "${!iface_config[@]}"; do
            echo "    $iface → ${iface_config[$iface]}"
        done
        echo "==============================="
        echo

        read -rp "[?] ¿Estás de acuerdo con esta configuración? (s/n): " confirm
        if [[ "$confirm" =~ ^[sS]$ ]]; then
            if [[ "$OS" == "Ubuntu" ]]; then
                generar_netplan "$NETPLAN_FILE" iface_config
            elif [[ "$OS" == "Debian" ]]; then
                generar_interfaces_debian "$DEBIAN_FILE" iface_config
            else
                echo "[!] Sistema operativo no soportado."
                exit 1
            fi
            break
        else
            echo "[*] Reiniciando configuración..."
        fi
    done
}

generar_netplan() {
    local file="$1"
    declare -n cfg="$2"

    if [[ -f "$file" ]]; then
        sudo cp "$file" "${file}.bak_$(date +%F_%T)"
        echo "[*] Copia de seguridad creada: ${file}.bak_$(date +%F_%T)"
    fi

    {
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        for iface in "${!cfg[@]}"; do
            echo "    ${iface}:"
            echo "      addresses:"
            echo "        - ${cfg[$iface]}"
        done
    } | sudo tee "$file" > /dev/null

    echo "[✓] Archivo Netplan generado correctamente en: $file"
    echo "[ℹ️] Ejecuta: sudo netplan apply"
}

generar_interfaces_debian() {
    local file="$1"
    declare -n cfg="$2"

    if [[ -f "$file" ]]; then
        sudo cp "$file" "${file}.bak_$(date +%F_%T)"
        echo "[*] Copia de seguridad creada: ${file}.bak_$(date +%F_%T)"
    fi

    {
        echo "# Archivo generado automáticamente por configurar_red.sh"
        echo "source /etc/network/interfaces.d/*"
        echo
        echo "auto lo"
        echo "iface lo inet loopback"
        echo
        for iface in "${!cfg[@]}"; do
            ip_addr="${cfg[$iface]}"
            echo "auto $iface"
            echo "iface $iface inet static"
            echo "address $ip_addr"
            echo
        done
    } | sudo tee "$file" > /dev/null

    echo "[✓] Archivo de configuración generado en: $file"
    echo "[ℹ️] Ejecuta: sudo systemctl restart networking"
}

configurar_ssh() {
    echo
    echo "==============================="
    echo "    Configuración de SSH"
    echo "==============================="

    local sshd_config="/etc/ssh/sshd_config"

    # Comprobamos si SSH está instalado
    if ! command -v sshd >/dev/null 2>&1; then
        echo "[!] SSH no está instalado. Instalando..."
        if [[ "$OS" == "Ubuntu" || "$OS" == "Debian" ]]; then
            sudo apt update -y && sudo apt install -y openssh-server
        else
            echo "[!] Sistema no soportado para instalación automática."
            return
        fi
    fi

    # Backup del archivo actual
    sudo cp "$sshd_config" "${sshd_config}.bak_$(date +%F_%T)"
    echo "[*] Copia de seguridad creada: ${sshd_config}.bak_$(date +%F_%T)"

    # Puerto SSH
    read -rp "[+] Puerto SSH (por defecto 22): " ssh_port
    ssh_port=${ssh_port:-22}
    if ! [[ "$ssh_port" =~ ^[0-9]+$ ]]; then
        echo "[!] Puerto inválido, se usará 22."
        ssh_port=22
    fi

    # Root login
    read -rp "[+] ¿Permitir login como root? (s/n) [n]: " allow_root
    allow_root=${allow_root:-n}

    # Autenticación por contraseña
    read -rp "[+] ¿Permitir autenticación por contraseña? (s/n) [s]: " allow_pass
    allow_pass=${allow_pass:-s}

    echo "[*] Aplicando cambios en $sshd_config ..."

    sudo sed -i "s/^#\?Port .*/Port $ssh_port/" "$sshd_config"
    sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $( [[ $allow_root =~ ^[sS]$ ]] && echo yes || echo no )/" "$sshd_config"
    sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $( [[ $allow_pass =~ ^[sS]$ ]] && echo yes || echo no )/" "$sshd_config"

    # Aseguramos las líneas si no existen
    grep -q "^Port" "$sshd_config" || echo "Port $ssh_port" | sudo tee -a "$sshd_config"
    grep -q "^PermitRootLogin" "$sshd_config" || echo "PermitRootLogin no" | sudo tee -a "$sshd_config"
    grep -q "^PasswordAuthentication" "$sshd_config" || echo "PasswordAuthentication yes" | sudo tee -a "$sshd_config"

    echo "[✓] Configuración SSH actualizada."

    # Reiniciar servicio
    sudo systemctl restart ssh
    sudo systemctl enable ssh

    echo
    echo "==============================="
    echo " SSH configurado correctamente "
    echo "==============================="
    echo "Puerto: $ssh_port"
    echo "Root login: $( [[ $allow_root =~ ^[sS]$ ]] && echo 'Permitido' || echo 'Denegado' )"
    echo "Contraseñas: $( [[ $allow_pass =~ ^[sS]$ ]] && echo 'Permitidas' || echo 'Solo clave pública' )"
    echo "==============================="
}



# --- Flujo principal ---
detectar_os
establecer_interfaces
read -rp "[?] ¿Deseas configurar SSH también? (s/n): " cfg_ssh
if [[ "$cfg_ssh" =~ ^[sS]$ ]]; then
    configurar_ssh
fi


