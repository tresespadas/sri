#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Configurador con dialog (todo con dialog)
# ------------------------------------------------------------------
NETPLAN_FILE="/etc/netplan/99-interfaces.yaml"
DEBIAN_FILE="/etc/network/interfaces"
OS="Desconocido"
TMP=/tmp/configurar_red.$$ # archivo temporal para capturar salidas de dialog

trap 'rm -f "$TMP"; clear' EXIT

# Util: mostrar mensaje informativo
info_box() {
  dialog --title "$1" --msgbox "$2" 0 0
}

# Util: pedir input, con valor por defecto
input_box() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  local height="${4:-8}"
  local width="${5:-60}"
  local result
  result=$(dialog --title "$title" --inputbox "$prompt" "$height" "$width" "$default" 3>&1 1>&2 2>&3) || return 1
  printf '%s' "$result"
}

# Util: pregunta sí/no -> devuelve 0 si YES, 1 si NO o cancel
yesno_box() {
  local title="$1"
  local prompt="$2"
  dialog --title "$title" --yesno "$prompt" 0 0
  return $?
}

# Detectar sistema operativo (llama a dialog para informar/errores)
detectar_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    dialog --title "Detección SO" --infobox "Detectando el sistema operativo..." 5 50
    if [[ "$NAME" == *"Ubuntu"* ]]; then
      OS="Ubuntu"
    elif [[ "$NAME" == *"Debian"* ]]; then
      OS="Debian"
    else
      OS="$NAME"
    fi
    dialog --title "Detección SO" --msgbox "Sistema operativo detectado: $OS" 6 60
  else
    dialog --title "Error" --msgbox "No se puede determinar el sistema operativo." 6 50
    exit 1
  fi
}

# Generar netplan (igual que tu anterior, con dialog para informar)
generar_netplan() {
  local file="$1"
  declare -n cfg="$2"

  if [[ -f "$file" ]]; then
    sudo cp "$file" "${file}.bak_$(date +%F_%T)"
    dialog --title "Backup" --msgbox "Copia de seguridad creada: ${file}.bak_$(date +%F_%T)" 6 70
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

  dialog --title "Netplan" --msgbox "Archivo Netplan generado correctamente en: $file\n\nEjecutando: sudo netplan apply" 8 70
  sudo netplan apply
}

# Generar /etc/network/interfaces con detección Proxmox
generar_interfaces_debian() {
  local file="$1"
  declare -n cfg="$2"

  # Detectar si es Proxmox VE
  local is_proxmox=0
  if [[ -d /etc/pve ]] || command -v pveversion >/dev/null 2>&1 || ([[ -f /etc/hosts ]] && grep -q "^pve" /etc/hosts 2>/dev/null); then
    is_proxmox=1
  fi

  if [[ -f "$file" ]]; then
    sudo cp "$file" "${file}.bak_$(date +%F_%T)"
    dialog --title "Backup" --msgbox "Copia de seguridad creada: ${file}.bak_$(date +%F_%T)" 6 70
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

    # Interfaces adicionales estáticas (LANs, VLANs, etc.)
    for iface in "${!cfg[@]}"; do
      ip_addr="${cfg[$iface]}"
      echo "auto $iface"
      echo "iface $iface inet static"
      echo "    address $ip_addr"
      echo
    done

  } | sudo tee "$file" >/dev/null

  dialog --title "Interfaces" --msgbox "Archivo de configuración generado en: $file" 6 70

  if ((is_proxmox)); then
    dialog --title "Proxmox" --msgbox "En Proxmox es más seguro aplicar con: ifreload -a  o reiniciar el nodo.\n\nSe intentará ejecutar: ifreload -a" 8 70
    # ifreload forma parte de ifupdown2; si no existe, avisamos
    if command -v ifreload >/dev/null 2>&1; then
      sudo ifreload -a
    else
      dialog --title "Atención" --msgbox "ifreload no está disponible en este sistema. Considera reiniciar el nodo o instalar ifupdown2." 8 70
    fi
  else
    dialog --title "Networking" --msgbox "Reiniciando el servicio networking..." 6 70
    sudo systemctl restart networking.service
  fi
}

# Configurar SSH (inputbox para puerto y yesno para opciones)
configurar_ssh() {
  dialog --title "SSH" --infobox "Configuración de SSH..." 5 50
  local sshd_config="/etc/ssh/sshd_config"

  # Comprobamos si SSH está instalado
  if ! command -v sshd >/dev/null 2>&1; then
    dialog --title "SSH" --msgbox "SSH no está instalado. Se instalará openssh-server (si es Debian/Ubuntu)." 7 70
    if [[ "$OS" == "Ubuntu" || "$OS" == "Debian" ]]; then
      sudo apt update -y && sudo apt install -y openssh-server
    else
      dialog --title "SSH" --msgbox "Sistema no soportado para instalación automática." 6 60
      return
    fi
  fi

  # Backup
  sudo cp "$sshd_config" "${sshd_config}.bak_$(date +%F_%T)" || true
  dialog --title "Backup" --msgbox "Copia de seguridad creada: ${sshd_config}.bak_$(date +%F_%T)" 6 70

  # Puerto SSH (inputbox)
  if ! ssh_port=$(input_box "SSH - Puerto" "Puerto SSH (por defecto 22):" "22"); then
    dialog --title "SSH" --msgbox "Operación cancelada." 6 40
    return
  fi
  ssh_port=${ssh_port:-22}
  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]]; then
    dialog --title "SSH" --msgbox "Puerto inválido, se usará 22." 6 40
    ssh_port=22
  fi

  # Root login (yesno)
  if yesno_box "SSH - Root" "¿Permitir login como root?"; then
    allow_root="s"
  else
    allow_root="n"
  fi

  # Password auth
  if yesno_box "SSH - Password" "¿Permitir autenticación por contraseña?"; then
    allow_pass="s"
  else
    allow_pass="n"
  fi

  # ¿Será servidor?
  if yesno_box "SSH - Server" "¿Esta máquina será usada como servidor SSH (habilitar GatewayPorts)?"; then
    is_server="s"
  else
    is_server="n"
  fi

  dialog --title "SSH" --infobox "Aplicando cambios al archivo $sshd_config ..." 5 60

  # Aplicar cambios con sed (aseguramos que existan/ajustamos)
  sudo sed -i "s/^#\?Port .*/Port $ssh_port/" "$sshd_config" 2>/dev/null || true
  sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $([[ $allow_root =~ ^[sS]$ ]] && echo yes || echo no)/" "$sshd_config" 2>/dev/null || true
  sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $([[ $allow_pass =~ ^[sS]$ ]] && echo yes || echo no)/" "$sshd_config" 2>/dev/null || true

  if [[ "$is_server" =~ ^[sS]$ ]]; then
    if grep -q "^#\?GatewayPorts" "$sshd_config"; then
      sudo sed -i "s/^#\?GatewayPorts.*/GatewayPorts clientspecified/" "$sshd_config"
    else
      echo "GatewayPorts clientspecified" | sudo tee -a "$sshd_config" >/dev/null
    fi
  fi

  # Aseguramos que las líneas existan
  grep -q "^Port" "$sshd_config" || echo "Port $ssh_port" | sudo tee -a "$sshd_config" >/dev/null
  grep -q "^PermitRootLogin" "$sshd_config" || echo "PermitRootLogin no" | sudo tee -a "$sshd_config" >/dev/null
  grep -q "^PasswordAuthentication" "$sshd_config" || echo "PasswordAuthentication yes" | sudo tee -a "$sshd_config" >/dev/null

  sudo systemctl restart ssh || true
  sudo systemctl enable ssh || true

  dialog --title "SSH - Resultados" --msgbox "SSH configurado.\n\nPuerto: $ssh_port\nRoot login: $([[ $allow_root =~ ^[sS]$ ]] && echo 'Permitido' || echo 'Denegado')\nContraseñas: $([[ $allow_pass =~ ^[sS]$ ]] && echo 'Permitidas' || echo 'Solo clave pública')\nServidor SSH (GatewayPorts): $([[ $is_server =~ ^[sS]$ ]] && echo 'Sí' || echo 'No')" 12 70
}

# Configurar Apache (inputs con dialog)
configurar_apache() {
  dialog --title "Apache" --infobox "Configuración de Apache..." 5 50

  if ! command -v apache2 >/dev/null 2>&1; then
    dialog --title "Apache" --msgbox "Apache no está instalado. Instalándolo (si es Debian/Ubuntu)." 7 70
    if [[ "$OS" == "Ubuntu" || "$OS" == "Debian" ]]; then
      sudo apt update -y && sudo apt install -y apache2
    else
      dialog --title "Apache" --msgbox "Sistema no compatible con instalación automática." 6 60
      return
    fi
  fi

  # Puerto
  if ! apache_port=$(input_box "Apache - Puerto" "Puerto para Apache (por defecto 80):" "80"); then
    dialog --title "Apache" --msgbox "Operación cancelada." 6 40
    return
  fi
  apache_port=${apache_port:-80}

  # Nombre servidor
  if ! server_name=$(input_box "Apache - Nombre servidor" "Nombre del servidor (por ejemplo SYSTEM-XY):" "SYSTEM-XY"); then
    dialog --title "Apache" --msgbox "Operación cancelada." 6 40
    return
  fi
  server_name=${server_name:-SYSTEM-XY}

  # Detectar redes (IPv4, sin loopback ni ens18)
  redes_detectadas=$(
    ip -4 -br addr show up |
      awk '!/lo/ && !/ens18/ {print $3}' |
      grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' |
      sed 's|/[0-9]\+$|/24;|' |
      tr '\n' ' '
  )
  redes_detectadas=${redes_detectadas:-"192.168.1.0/24;"}

  if ! redes=$(input_box "Apache - Redes" "Redes (por defecto las detectadas):" "$redes_detectadas"); then
    dialog --title "Apache" --msgbox "Operación cancelada." 6 40
    return
  fi
  redes=${redes:-$redes_detectadas}

  site_name="server_${server_name,,}"
  site_dir="/var/www/${site_name}"

  sudo mkdir -p "$site_dir"

  sudo bash -c "cat > ${site_dir}/index.html" <<EOF
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>SERVER ${server_name}</title>
    <style>
      body{font-family:Verdana, sans-serif;background:#D8DBE2;padding:20px;text-align:center;}
      .main{width:800px;margin:0 auto;border:2px solid #212738;background:#FFFF00;padding:10px;}
      .section{padding:6px;background:#90EE90;font-weight:bold;}
    </style>
  </head>
  <body>
    <div class="main">
      <h1>WEBSITE SERVIDOR ${server_name}</h1>
      <div class="section">RED: ${redes}</div>
      <div class="section">PUERTO: ${apache_port}</div>
    </div>
  </body>
</html>
EOF

  sudo chown -R www-data:www-data "$site_dir"

  conf_file="/etc/apache2/sites-available/${site_name}.conf"

  sudo bash -c "cat > $conf_file" <<EOF
<VirtualHost *:${apache_port}>
    ServerAdmin webmaster@localhost
    DocumentRoot ${site_dir}
    ErrorLog \${APACHE_LOG_DIR}/${site_name}_error.log
    CustomLog \${APACHE_LOG_DIR}/${site_name}_access.log combined
</VirtualHost>
EOF

  if ! grep -q "Listen ${apache_port}" /etc/apache2/ports.conf; then
    echo "Listen ${apache_port}" | sudo tee -a /etc/apache2/ports.conf >/dev/null
  fi

  sudo a2ensite "${site_name}.conf" >/dev/null || true
  sudo systemctl reload apache2 || true
  sudo systemctl enable apache2 || true

  dialog --title "Apache - Resultado" --msgbox "Apache configurado.\nServidor: ${server_name}\nSitio: ${site_name}\nRuta: ${site_dir}\nPuerto: ${apache_port}\nRedes: ${redes}\nURL: http://<tu_ip>:${apache_port}/" 12 80
}

# --- Comprobación automática de dialog (instalación si falta) ---
if ! command -v dialog >/dev/null 2>&1; then
  echo "[!] dialog no está instalado. Instalándolo..."
  if [[ -f /etc/debian_version ]]; then
    sudo apt update -y && sudo apt install -y dialog
    echo "[✓] dialog instalado correctamente."
  else
    echo "[✗] No se pudo detectar un sistema compatible para instalación automática."
    echo "    Instálalo manualmente e inténtalo de nuevo."
    exit 1
  fi
fi

# --- Función para configurar VLANs / interfaces ---
# Esta versión usa dialog para seleccionar interfaces y pedir IPs
establecer_vlan() {
  TMP=$(mktemp)

  # Detectar interfaces (excluimos loopback)
  mapfile -t interfaces < <(ip -br a | awk 'NR>1 {print $1}' | grep -v lo || true)

  if [[ ${#interfaces[@]} -eq 0 ]]; then
    dialog --title "Error" --msgbox "No se encontraron interfaces válidas." 7 50
    return 1
  fi

  #
  # 1) MOSTRAR INTERFACES DETECTADAS
  #
  {
    echo "Interfaces detectadas:"
    echo "======================="
    for i in "${!interfaces[@]}"; do
      printf "%2d) %s\n" "$((i + 1))" "${interfaces[$i]}"
    done
    echo
    #echo "Usa estos números para elegir las interfaces."
  } >"$TMP"

  dialog --title "Interfaces detectadas" --textbox "$TMP" 18 60

  #
  # 2) Preguntar cuántas interfaces quiere configurar
  #
  while true; do
    num_ifaces=$(dialog --title "Número de interfaces" \
      --inputbox "¿Cuántas interfaces deseas configurar?" 10 60 \
      3>&1 1>&2 2>&3)

    ret=$?
    [[ $ret -ne 0 ]] && return 1

    if ! [[ "$num_ifaces" =~ ^[0-9]+$ ]]; then
      dialog --title "Error" --msgbox "Debes introducir un número válido." 7 50
      continue
    fi

    break
  done

  #
  # 3) Configurar cada interfaz elegida
  #
  declare -A iface_config
  declare -A usadas

  for ((n = 1; n <= num_ifaces; n++)); do

    #
    # Menú para seleccionar interfaz
    #
    menu_items=()
    for i in "${!interfaces[@]}"; do
      menu_items+=("$((i + 1))" "${interfaces[$i]}")
    done

    idx=$(dialog --title "Interfaz #$n" \
      --menu "Selecciona la interfaz para configurar:" 15 60 8 \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3)

    ret=$?
    [[ $ret -ne 0 ]] && return 1

    iface_index=$((idx - 1))
    base_iface="${interfaces[$iface_index]}"

    # Evitar seleccionar la misma dos veces
    if [[ -n "${usadas[$base_iface]+x}" ]]; then
      dialog --title "Error" --msgbox "La interfaz '$base_iface' ya fue seleccionada." 7 50
      ((n--))
      continue
    fi

    usadas["$base_iface"]=1

    #
    # Pedir IP/CIDR
    #
    while true; do
      ip_iface=$(dialog --title "IP para $base_iface" \
        --inputbox "Introduce IP/CIDR (ej: 192.168.1.10/24):" 10 60 \
        3>&1 1>&2 2>&3)

      ret=$?
      [[ $ret -ne 0 ]] && return 1

      # Validación básica (puedo darte una estricta si quieres)
      if [[ "$ip_iface" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        break
      else
        dialog --title "Error" --msgbox "IP no válida." 7 40
      fi
    done

    iface_config["$base_iface"]="$ip_iface"
  done

  #
  # 4) Resumen final
  #
  {
    echo "Resumen de configuración:"
    echo "========================="
    for iface in "${!iface_config[@]}"; do
      echo " $iface → ${iface_config[$iface]}"
    done
  } >"$TMP"

  dialog --title "Resumen" --textbox "$TMP" 18 60

  #
  # 5) Confirmación
  #
  dialog --title "Confirmar" \
    --yesno "¿Aplicar esta configuración?" 8 60

  ret=$?
  [[ $ret -ne 0 ]] && return 1

  #
  # 6) Llamar a los generadores según SO detectado
  #
  if [[ "$OS" == "Ubuntu" ]]; then
    generar_netplan "$NETPLAN_FILE" iface_config
  elif [[ "$OS" == "Debian" ]]; then
    generar_interfaces_debian "$DEBIAN_FILE" iface_config
  else
    dialog --title "Error" --msgbox "Sistema operativo no soportado." 7 50
    return 1
  fi

  rm -f "$TMP"
}

# --- Menú principal con dialog ---
while true; do
  OPCION=$(dialog --title "Configurador del Servidor" \
    --menu "Selecciona una opción:" 15 70 6 \
    1 "Configurar VLANs / Interfaces" \
    2 "Configurar SSH" \
    3 "Configurar Apache (web estática)" \
    4 "Salir" \
    3>&1 1>&2 2>&3) || {
    # Si user cancela el menú principal, preguntamos confirmación para salir
    if yesno_box "Salir" "¿Deseas salir del configurador?"; then
      clear
      echo "Saliendo del configurador. ¡Hasta luego!"
      exit 0
    else
      continue
    fi
  }

  case $OPCION in
  1)
    detectar_os
    establecer_vlan
    ;;
  2)
    detectar_os
    configurar_ssh
    ;;
  3)
    detectar_os
    configurar_apache
    ;;
  4)
    clear
    echo "Saliendo del configurador. ¡Hasta luego!"
    exit 0
    ;;
  *)
    dialog --title "Error" --msgbox "Opción inválida." 6 40
    ;;
  esac

  # Preguntar si desea realizar otra configuración
  if ! yesno_box "Otra configuración" "¿Deseas realizar otra configuración?"; then
    clear
    echo "Saliendo del configurador. ¡Hasta luego!"
    exit 0
  fi
done
