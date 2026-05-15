#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Configurador de red y DDNS en modo texto
# ------------------------------------------------------------------

NETPLAN_FILE="/etc/netplan/99-interfaces.yaml"
DEBIAN_FILE="/etc/network/interfaces"
RESOLV_FILE="/etc/resolv.conf"
OS="Desconocido"

# Util: mostrar mensaje informativo
info() {
  echo "[INFO] $1"
}

# Util: mostrar mensaje de error
error() {
  echo "[ERROR] $1" >&2
}

# Verificar que se ejecuta como root
verificar_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "Este script debe ejecutarse como root."
    error "Vuelve a lanzarlo con: sudo $0"
    exit 1
  fi
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

# Pedir lista de nameservers (separados por espacios o comas)
pedir_nameservers() {
  local var_name="$1"
  local raw
  local -a ns_arr=()
  while true; do
    input "Nameservers (separados por espacios, ej: 127.0.0.1 8.8.8.8)" "127.0.0.1" raw
    raw="${raw//,/ }"
    read -ra ns_arr <<<"$raw"
    local ok=1
    for ns in "${ns_arr[@]}"; do
      if ! [[ "$ns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "IP de nameserver inválida: $ns"
        ok=0
        break
      fi
    done
    ((ok)) && break
  done
  eval "$var_name=\"\${ns_arr[*]}\""
}

# Utilidad: convertir lista separada por espacios en formato inline YAML "[a, b, c]"
_yaml_inline_list() {
  local items="$1"
  local list=""
  for it in $items; do
    if [[ -z "$list" ]]; then
      list="$it"
    else
      list="$list, $it"
    fi
  done
  echo "$list"
}

# Generar netplan (nameservers y search por interfaz)
generar_netplan() {
  local file="$1"
  declare -n cfg="$2"
  declare -n ns_map="$3"
  declare -n search_map="$4"

  if [[ -f "$file" ]]; then
    cp "$file" "${file}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${file}.bak_$(date +%F_%T)"
  fi

  {
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    for iface in "${!cfg[@]}"; do
      local nameservers="${ns_map[$iface]:-}"
      local search_domains="${search_map[$iface]:-}"
      echo "    ${iface}:"
      echo "      optional: true"
      echo "      dhcp4: false"
      echo "      dhcp6: false"
      echo "      addresses: [${cfg[$iface]}]"
      if [[ -n "$nameservers" || -n "$search_domains" ]]; then
        echo "      nameservers:"
        if [[ -n "$nameservers" ]]; then
          echo "        addresses: [$(_yaml_inline_list "$nameservers")]"
        fi
        if [[ -n "$search_domains" ]]; then
          echo "        search: [$(_yaml_inline_list "$search_domains")]"
        fi
      fi
    done
  } >"$file"

  info "Archivo Netplan generado en: $file"
  info "Ejecutando: netplan apply"
  netplan apply
}

# Generar /etc/network/interfaces con detección Proxmox (y nameservers en resolv.conf)
generar_interfaces_debian() {
  local file="$1"
  declare -n cfg="$2"
  declare -n ns_map="$3"
  declare -n search_map="$4"

  local is_proxmox=0
  if [[ -d /etc/pve ]] || command -v pveversion >/dev/null 2>&1; then
    is_proxmox=1
  fi

  if [[ -f "$file" ]]; then
    cp "$file" "${file}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${file}.bak_$(date +%F_%T)"
  fi

  {
    echo "# Archivo generado automáticamente por $(basename "$0") - $(date)"
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
      local ip_addr="${cfg[$iface]}"
      local nameservers="${ns_map[$iface]:-}"
      local search_domains="${search_map[$iface]:-}"
      echo "allow-hotplug $iface"
      echo "iface $iface inet static"
      echo "    address $ip_addr"
      if [[ -n "$nameservers" ]]; then
        echo "    dns-nameservers $nameservers"
      fi
      if [[ -n "$search_domains" ]]; then
        echo "    dns-search $search_domains"
      fi
      echo
    done

  } >"$file"

  info "Archivo de configuración generado en: $file"

  # Para /etc/resolv.conf usamos la unión deduplicada de todas las interfaces
  local all_ns=""
  local all_search=""
  for iface in "${!cfg[@]}"; do
    for ns in ${ns_map[$iface]:-}; do
      [[ " $all_ns " == *" $ns "* ]] || all_ns="${all_ns:+$all_ns }$ns"
    done
    for s in ${search_map[$iface]:-}; do
      [[ " $all_search " == *" $s "* ]] || all_search="${all_search:+$all_search }$s"
    done
  done

  if [[ -n "$all_ns" || -n "$all_search" ]]; then
    if [[ -f "$RESOLV_FILE" ]]; then
      cp "$RESOLV_FILE" "${RESOLV_FILE}.bak_$(date +%F_%T)"
      info "Copia de seguridad creada: ${RESOLV_FILE}.bak_$(date +%F_%T)"
    fi
    {
      echo "# Generado por $(basename "$0") - $(date)"
      if [[ -n "$all_search" ]]; then
        echo "search $all_search"
      fi
      for ns in $all_ns; do
        echo "nameserver $ns"
      done
    } >"$RESOLV_FILE"
    info "Nameservers/search escritos en $RESOLV_FILE"
  fi

  if ((is_proxmox)); then
    info "En Proxmox es más seguro aplicar con: ifreload -a o reiniciar."
    if command -v ifreload >/dev/null 2>&1; then
      info "Ejecutando: ifreload -a"
      ifreload -a
    else
      info "ifreload no está disponible. Considera reiniciar o instalar ifupdown2."
    fi
  else
    info "Reiniciando el servicio networking..."
    systemctl restart networking.service
  fi
}

configurar_hosts() {
  local hosts_file="/etc/hosts"
  local num_hosts
  local ip
  local fqdn
  local nuevo_hostname

  info "Configurando /etc/hosts..."
  cp "$hosts_file" "${hosts_file}.bak_$(date +%F_%T)"
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
    echo "$ip $fqdn $hostname_short" >>"$hosts_file"
  done

  input "Introduce el hostname COMPLETO (FQDN) que quieres para la máquina" "" nuevo_hostname
  if [[ -n "$nuevo_hostname" ]]; then
    if hostnamectl set-hostname "$nuevo_hostname"; then
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
  declare -A iface_ns
  declare -A iface_search
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

    local ns_for_iface=""
    local search_for_iface=""
    if yesno "¿Configurar nameservers para $base_iface?"; then
      pedir_nameservers ns_for_iface
      input "Dominios de búsqueda para $base_iface (separados por espacios, vacío para omitir)" "" search_for_iface
    fi
    iface_ns["$base_iface"]="$ns_for_iface"
    iface_search["$base_iface"]="$search_for_iface"
  done

  echo "Resumen de la configuración:"
  for iface in "${!iface_config[@]}"; do
    echo "  $iface -> ${iface_config[$iface]}"
    [[ -n "${iface_ns[$iface]:-}" ]] && echo "      nameservers: ${iface_ns[$iface]}"
    [[ -n "${iface_search[$iface]:-}" ]] && echo "      search: ${iface_search[$iface]}"
  done

  if yesno "¿Aplicar esta configuración?"; then
    if [[ "$OS" == "Ubuntu" ]]; then
      generar_netplan "$NETPLAN_FILE" iface_config iface_ns iface_search
    elif [[ "$OS" == "Debian" ]]; then
      generar_interfaces_debian "$DEBIAN_FILE" iface_config iface_ns iface_search
    else
      error "Sistema operativo no soportado para aplicar la configuración."
      return 1
    fi
  else
    info "Configuración cancelada."
  fi
}

# --- Bloque Principal ---
verificar_root
detectar_os

while true; do
  clear
  echo
  echo "--- Configurador DDNS ---"
  echo "1) Configurar VLANs / Interfaces (con nameservers)"
  echo "2) Configurar /etc/hosts y hostname"
  echo "3) Salir"
  echo "-------------------------"

  input "Selecciona una opción" "3" OPCION

  case $OPCION in
  1)
    establecer_vlan
    ;;
  2)
    configurar_hosts
    ;;
  3)
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
