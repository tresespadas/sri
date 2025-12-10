#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Configurador de red en modo texto
# ------------------------------------------------------------------

NETPLAN_FILE="/etc/netplan/99-interfaces.yaml"
DEBIAN_FILE="/etc/network/interfaces"
OS="Desconocido"

# Util: mostrar mensaje informativo
info() {
  echo "[INFO] $1"
}

# Util: mostrar mensaje de error
error() {
  echo "[ERROR] $1" >&2
}

# Util: pedir input, con valor por defecto
input() {
  local prompt="$1"
  local default="${2:-}"
  local var_name="$3"
  local input_value

  if [[ -n "$default" ]]; then
    read -p "$prompt [$default]: " input_value
    eval "$var_name='${input_value:-$default}'"
  else
    read -p "$prompt: " input_value
    eval "$var_name='$input_value'"
  fi
}

# Util: pregunta sí/no -> devuelve 0 si YES, 1 si NO
yesno() {
  local prompt="$1"
  local answer
  while true; do
    read -p "$prompt (s/n): " answer
    case "$answer" in
    [Ss]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) echo "Por favor, responde 's' o 'n'." ;;
    esac
  done
}

# Detectar sistema operativo
detectar_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "Detectando el sistema operativo..."
    if [[ "$NAME" == *"Ubuntu"* ]]; then
      OS="Ubuntu"
    elif [[ "$NAME" == *"Debian"* ]]; then
      OS="Debian"
    else
      OS="$NAME"
    fi
    info "Sistema operativo detectado: $OS"
  else
    error "No se puede determinar el sistema operativo."
    exit 1
  fi
}

# Verificar si sudo está instalado y, si no, intentar instalarlo
verificar_e_instalar_sudo() {
  if command -v sudo &>/dev/null; then
    info "'sudo' ya está instalado."
    return
  fi

  info "'sudo' no está instalado. Intentando instalar..."
  if [[ "$(id -u)" -eq 0 ]]; then
    if [[ "$OS" == "Ubuntu" || "$OS" == "Debian" ]]; then
      info "Ejecutando como root, se instalará 'sudo' a través de apt."
      apt-get update -y
      apt-get install -y sudo
      info "'sudo' ha sido instalado. Se recomienda salir y volver a ejecutar el script con un usuario con privilegios de sudo."
    else
      error "La instalación automática de 'sudo' no es compatible con $OS."
      error "Por favor, instale 'sudo' manualmente y vuelva a ejecutar el script."
      exit 1
    fi
  else
    error "No se puede instalar 'sudo' porque el script no se está ejecutando como root."
    error "Por favor, ejecute este script como 'root' para la configuración inicial o instale 'sudo' manualmente."
    exit 1
  fi
}

# Generar netplan
generar_netplan() {
  local file="$1"
  declare -n cfg="$2"

  if [[ -f "$file" ]]; then
    sudo cp "$file" "${file}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${file}.bak_$(date +%F_%T)"
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
  } | sudo tee "$file" >/dev/null

  info "Archivo Netplan generado en: $file"
  info "Ejecutando: sudo netplan apply"
  sudo netplan apply
}

# Generar /etc/network/interfaces con detección Proxmox
generar_interfaces_debian() {
  local file="$1"
  declare -n cfg="$2"

  local is_proxmox=0
  if [[ -d /etc/pve ]] || command -v pveversion >/dev/null 2>&1; then
    is_proxmox=1
  fi

  if [[ -f "$file" ]]; then
    sudo cp "$file" "${file}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${file}.bak_$(date +%F_%T)"
  fi

  {
    echo "# Archivo generado automáticamente por configurar_red.sh - $(date)"
    echo "source /etc/network/interfaces.d/*"
    echo
    echo "auto lo"
    echo "iface lo inet loopback"
    echo

    if ((is_proxmox)); then
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

    for iface in "${!cfg[@]}"; do
      ip_addr="${cfg[$iface]}"
      echo "auto $iface"
      echo "iface $iface inet static"
      echo "    address $ip_addr"
      echo
    done

  } | sudo tee "$file" >/dev/null

  info "Archivo de configuración generado en: $file"

  if ((is_proxmox)); then
    info "En Proxmox es más seguro aplicar con: ifreload -a o reiniciar."
    if command -v ifreload >/dev/null 2>&1; then
      info "Ejecutando: sudo ifreload -a"
      sudo ifreload -a
    else
      info "ifreload no está disponible. Considera reiniciar o instalar ifupdown2."
    fi
  else
    info "Reiniciando el servicio networking..."
    sudo systemctl restart networking.service
  fi
}

configurar_hosts() {
  local hosts_file="/etc/hosts"
  local num_hosts
  local ip
  local fqdn
  local nuevo_hostname

  info "Configurando /etc/hosts..."
  sudo cp "$hosts_file" "${hosts_file}.bak_$(date +%F_%T)"
  info "Copia de seguridad creada: ${hosts_file}.bak_$(date +%F_%T)"

  while true; do
    input "Cuántas líneas deseas agregar al archivo /etc/hosts?" "" num_hosts
    if [[ "$num_hosts" =~ ^[0-9]+$ ]] && ((num_hosts > 0)); then
      break
    fi
    error "Debes introducir un número válido mayor que 0."
  done

  for ((i = 1; i <= num_hosts; i++)); do
    while true; do
      input "Introduce la IP para la entrada #$i (ej: 192.168.1.50)" "" ip
      if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
      fi
      error "IP inválida."
    done

    while true; do
      input "Introduce el FQDN para la entrada #$i (ej: node01.example.com)" "" fqdn
      if [[ -n "$fqdn" ]]; then
        break
      fi
      error "El FQDN no puede estar vacío."
    done

    local hostname_short="${fqdn%%.*}"
    if grep -qE "^\s*$ip\s+.*\b$fqdn\b" "$hosts_file"; then
      info "La entrada '$ip $fqdn' ya existe. Omitiendo."
      continue
    fi
    echo "$ip $fqdn $hostname_short" | sudo tee -a "$hosts_file" >/dev/null
  done

  input "Introduce el hostname COMPLETO (FQDN) que quieres para la máquina" "" nuevo_hostname
  if [[ -n "$nuevo_hostname" ]]; then
    if sudo hostnamectl set-hostname "$nuevo_hostname"; then
      info "Hostname cambiado correctamente a: $nuevo_hostname"
    else
      error "No se pudo cambiar el hostname."
    fi
  else
    error "El hostname no puede estar vacío."
  fi

  info "Contenido actualizado de /etc/hosts:"
  cat "$hosts_file"
}

configurar_ssh() {
  info "Configuración de SSH..."
  local sshd_config="/etc/ssh/sshd_config"

  if ! command -v sshd >/dev/null 2>&1; then
    info "SSH no está instalado. Se intentará instalar openssh-server."
    if [[ "$OS" == "Ubuntu" || "$OS" == "Debian" ]]; then
      sudo apt update -y && sudo apt install -y openssh-server
    else
      error "Sistema no soportado para instalación automática de SSH."
      return
    fi
  fi

  sudo cp "$sshd_config" "${sshd_config}.bak_$(date +%F_%T)"
  info "Copia de seguridad creada: ${sshd_config}.bak_$(date +%F_%T)"

  local ssh_port
  input "Puerto SSH" "22" ssh_port
  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]]; then
    error "Puerto inválido, se usará 22."
    ssh_port=22
  fi

  local allow_root
  local allow_pass
  local is_server

  yesno "¿Permitir login como root?" && allow_root="yes" || allow_root="no"
  yesno "¿Permitir autenticación por contraseña?" && allow_pass="yes" || allow_pass="no"
  yesno "¿Esta máquina será usada como servidor SSH (habilitar GatewayPorts)?" && is_server="yes" || is_server="no"

  info "Aplicando cambios a $sshd_config..."
  sudo sed -i "s/^#\?Port .*/Port $ssh_port/" "$sshd_config"
  sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $allow_root/" "$sshd_config"
  sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $allow_pass/" "$sshd_config"

  if [[ "$is_server" == "yes" ]]; then
    if grep -q "^#\?GatewayPorts" "$sshd_config"; then
      sudo sed -i "s/^#\?GatewayPorts.*/GatewayPorts clientspecified/" "$sshd_config"
    else
      echo "GatewayPorts clientspecified" | sudo tee -a "$sshd_config" >/dev/null
    fi
  fi

  grep -q "^Port" "$sshd_config" || echo "Port $ssh_port" | sudo tee -a "$sshd_config" >/dev/null
  grep -q "^PermitRootLogin" "$sshd_config" || echo "PermitRootLogin no" | sudo tee -a "$sshd_config" >/dev/null
  grep -q "^PasswordAuthentication" "$sshd_config" || echo "PasswordAuthentication yes" | sudo tee -a "$sshd_config" >/dev/null

  sudo systemctl restart ssh || true
  sudo systemctl enable ssh || true

  info "SSH configurado:"
  echo "  Puerto: $ssh_port"
  echo "  Root login: $allow_root"
  echo "  Contraseñas: $allow_pass"
  echo "  Servidor SSH (GatewayPorts): $is_server"
}

configurar_apache() {
  info "Configuración de Apache..."

  if ! command -v apache2 >/dev/null 2>&1; then
    info "Apache no está instalado. Se intentará instalar."
    if [[ "$OS" == "Ubuntu" || "$OS" == "Debian" ]]; then
      sudo apt update -y && sudo apt install -y apache2
    else
      error "Sistema no compatible con instalación automática de Apache."
      return
    fi
  fi

  local apache_port
  local server_name
  local redes
  input "Puerto para Apache" "80" apache_port
  input "Nombre del servidor (ej. SYSTEM-XY)" "SYSTEM-XY" server_name

  local redes_detectadas=$(ip -4 -br a | awk '!/lo|ens18/ {print $3}' | sed 's|/[0-9]\\$|/24;|' | tr '\n' ' ')
  redes_detectadas=${redes_detectadas:-"192.168.1.0/24;"}
  input "Redes (separadas por espacio)" "$redes_detectadas" redes

  local site_name="server_${server_name,,}"
  local site_dir="/var/www/${site_name}"

  sudo mkdir -p "$site_dir"

  sudo bash -c "cat > ${site_dir}/index.html" <<EOF
<!DOCTYPE html> 
<html><head><title>SERVER ${server_name}</title></head>
<body><h1>WEBSITE SERVIDOR ${server_name}</h1>
<p>RED: ${redes}</p><p>PUERTO: ${apache_port}</p>
</body></html>
EOF

  sudo chown -R www-data:www-data "$site_dir"
  local conf_file="/etc/apache2/sites-available/${site_name}.conf"

  sudo bash -c "cat > $conf_file" <<EOF
<VirtualHost *:${apache_port}>
    ServerAdmin webmaster@localhost
    DocumentRoot ${site_dir}
    ErrorLog {APACHE_LOG_DIR}/${site_name}_error.log
    CustomLog {APACHE_LOG_DIR}/${site_name}_access.log combined
</VirtualHost>
EOF

  if ! grep -q "Listen ${apache_port}" /etc/apache2/ports.conf; then
    echo "Listen ${apache_port}" | sudo tee -a /etc/apache2/ports.conf >/dev/null
  fi

  sudo a2ensite "${site_name}.conf" >/dev/null || true
  sudo systemctl reload apache2 || true
  sudo systemctl enable apache2 || true

  info "Apache configurado:"
  echo "  Servidor: ${server_name}"
  echo "  Sitio: ${site_name}"
  echo "  Ruta: ${site_dir}"
  echo "  Puerto: ${apache_port}"
  echo "  URL: http://<tu_ip>:${apache_port}/"
}

establecer_vlan() {
  mapfile -t interfaces < <(ip -br a | awk 'NR>1 {print $1}' | grep -Ev '^(lo|ens18)$' || true)

  if [[ ${#interfaces[@]} -eq 0 ]]; then
    error "No se encontraron interfaces válidas para configurar."
    return 1
  fi

  echo "Interfaces detectadas:"
  for i in "${!interfaces[@]}"; do
    printf "  %2d) %s\n" "$((i + 1))" "${interfaces[$i]}"
  done

  local num_ifaces
  while true; do
    input "Cuántas interfaces deseas configurar?" "" num_ifaces
    if [[ "$num_ifaces" =~ ^[0-9]+$ ]] && ((num_ifaces > 0)); then
      break
    fi
    error "Debes introducir un número válido."
  done

  declare -A iface_config
  declare -A usadas
  for ((n = 1; n <= num_ifaces; n++)); do
    local iface_choice
    local base_iface
    while true; do
      input "Elige la interfaz #$n por su número (1-${#interfaces[@]})" "" iface_choice
      if [[ "$iface_choice" =~ ^[0-9]+$ ]] && ((iface_choice >= 1 && iface_choice <= ${#interfaces[@]})); then
        base_iface="${interfaces[$((iface_choice - 1))]}"
        if [[ -n "${usadas[$base_iface]+x}" ]]; then
          error "La interfaz '$base_iface' ya fue seleccionada."
        else
          usadas["$base_iface"]=1
          break
        fi
      else
        error "Selección inválida."
      fi
    done

    local ip_iface
    while true; do
      input "Introduce IP/CIDR para $base_iface (ej: 192.168.1.10/24)" "" ip_iface
      if [[ "$ip_iface" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        iface_config["$base_iface"]="$ip_iface"
        break
      else
        error "Formato de IP/CIDR no válido."
      fi
    done
  done

  echo "Resumen de la configuración:"
  for iface in "${!iface_config[@]}"; do
    echo "  $iface -> ${iface_config[$iface]}"
  done

  if yesno "¿Aplicar esta configuración?"; then
    if [[ "$OS" == "Ubuntu" ]]; then
      generar_netplan "$NETPLAN_FILE" iface_config
    elif [[ "$OS" == "Debian" ]]; then
      generar_interfaces_debian "$DEBIAN_FILE" iface_config
    else
      error "Sistema operativo no soportado para aplicar la configuración."
      return 1
    fi
  else
    info "Configuración cancelada."
  fi
}

# --- Bloque Principal ---
detectar_os
verificar_e_instalar_sudo

while true; do
  clear
  echo
  echo "--- Configurador del Servidor ---"
  echo "1) Configurar VLANs / Interfaces"
  echo "2) Configurar /etc/hosts y hostname"
  echo "3) Configurar SSH"
  echo "4) Configurar Apache (web estática)"
  echo "5) Salir"
  echo "---------------------------------"

  input "Selecciona una opción" "5" OPCION

  case $OPCION in
  1)
    establecer_vlan
    ;;
  2)
    configurar_hosts
    ;;
  3)
    configurar_ssh
    ;;
  4)
    configurar_apache
    ;;
  5)
    echo "Saliendo del configurador. ¡Hasta luego!"
    exit 0
    ;;
  *)
    error "Opción inválida."
    ;;
  esac

  if ! yesno "¿Deseas realizar otra configuración?"; then
    echo "Saliendo del configurador. ¡Hasta luego!"
    exit 0
  fi
done
