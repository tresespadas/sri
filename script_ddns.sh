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

# Instalar paquete apt si no está presente (solo Debian/Ubuntu)
instalar_paquete() {
  local paquete="$1"
  if dpkg -s "$paquete" >/dev/null 2>&1; then
    info "'$paquete' ya está instalado."
    return 0
  fi
  if [[ "$OS" != "Ubuntu" && "$OS" != "Debian" ]]; then
    error "Instalación automática no soportada en $OS. Instala '$paquete' manualmente."
    return 1
  fi
  info "Instalando '$paquete'..."
  apt-get update -y
  apt-get install -y "$paquete"
}

# Preguntar rol (master/slave) y, si es slave, la IP del master.
# Uso: pedir_rol_zona "descripcion" rol_var ip_var
pedir_rol_zona() {
  local descripcion="$1"
  local rol_var="$2"
  local ip_var="$3"
  local rol_value=""
  local ip_value=""

  while true; do
    input "Rol para ${descripcion} (master/slave)" "master" rol_value
    if [[ "$rol_value" == "master" || "$rol_value" == "slave" ]]; then
      break
    fi
    error "Debe ser 'master' o 'slave'."
  done

  if [[ "$rol_value" == "slave" ]]; then
    while true; do
      input "IP del master para ${descripcion}" "" ip_value
      if [[ "$ip_value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
      fi
      error "IP inválida."
    done
  fi

  eval "$rol_var='$rol_value'"
  eval "$ip_var='$ip_value'"
}

# Generar fichero de zona directa a partir de plantilla.
# Uso: emit_file_directa <out_file> <dominio> <admin> <hostname> <ip> [<alias>]
emit_file_directa() {
  local out_file="$1"
  local dominio="$2"
  local admin="$3"
  local hostname="$4"
  local ip="$5"
  local alias="${6:-}"
  local serial
  serial="$(date +%Y%m%d)01"

  {
    cat <<EOF
;
; BIND data file for ${dominio}
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; FICHERO BUSQUEDA DIRECTA ${dominio}

\$TTL    604800
@        IN    SOA    ${dominio}. ${admin}. (
                  ${serial}        ; Serial
             604800        ; Refresh
              86400        ; Retry
            2419200        ; Expire
             604800 )    ; Negative Cache TTL
;
; REGISTROS NS. Servidor DNS.
@        IN    NS    ${hostname}.${dominio}.

;REGISTROS TIPO A: Lista de Equipos de la red.
${hostname}    IN    A    ${ip}
EOF
    if [[ -n "$alias" ]]; then
      cat <<EOF

;REGISTROS CNAME: ALIAS.
${alias}    IN    CNAME    ${hostname}
EOF
    fi
  } >"$out_file"
}

# Generar fichero de zona inversa a partir de plantilla.
# Uso: emit_file_inversa <out_file> <zona_inversa> <admin> <hostname> <dominio> <last_octet>
emit_file_inversa() {
  local out_file="$1"
  local zona_inversa="$2"
  local admin="$3"
  local hostname="$4"
  local dominio="$5"
  local last_octet="$6"
  local serial
  serial="$(date +%Y%m%d)01"

  cat >"$out_file" <<EOF
;
; BIND reverse data file
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; FICHERO DE BUSQUEDA INVERSA: ${zona_inversa}
;;;;;;;;;;ABAJO LA IP AL REVES!;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

\$TTL    604800
@    IN    SOA    ${zona_inversa}. ${admin}. (
                  ${serial}        ; Serial
             604800        ; Refresh
              86400        ; Retry
            2419200        ; Expire
             604800 )    ; Negative Cache TTL

;REGISTROS TIPO NS. Declaracion del SERVER-DNS
@    IN    NS    ${hostname}.${dominio}.

;REGISTROS TIPO PTR. Declaracion de HOSTS - DECLARAR SERVIDOR TAMBIEN.
${last_octet}    IN    PTR    ${hostname}.${dominio}.
EOF
}

# Generar fichero de zona para un subdominio delegado (apex = subdominio).
# Uso: emit_file_subdominio <out_file> <sub_fqdn> <admin> <hostname_padre> <dominio_padre> <ip>
emit_file_subdominio() {
  local out_file="$1"
  local sub_fqdn="$2"
  local admin="$3"
  local hostname="$4"
  local dominio="$5"
  local ip="$6"
  local serial
  serial="$(date +%Y%m%d)01"

  cat >"$out_file" <<EOF
;
; BIND data file for ${sub_fqdn}
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; FICHERO BUSQUEDA DIRECTA ${sub_fqdn}

\$TTL    604800
@        IN    SOA    ${sub_fqdn}. ${admin}. (
                  ${serial}        ; Serial
             604800        ; Refresh
              86400        ; Retry
            2419200        ; Expire
             604800 )    ; Negative Cache TTL
;
; REGISTROS NS. Delegado al servidor DNS del dominio padre.
@        IN    NS    ${hostname}.${dominio}.

;REGISTROS TIPO A: apex del subdominio.
@        IN    A    ${ip}
EOF
}

# Validar sintaxis de un fichero de zona con named-checkzone.
# Uso: verificar_zona <zona> <fichero>
verificar_zona() {
  local zona="$1"
  local fichero="$2"
  info "Verificando sintaxis de zona '${zona}'..."
  if named-checkzone "$zona" "$fichero"; then
    info "  Zona '${zona}' OK."
  else
    error "  Sintaxis incorrecta en zona '${zona}'. Revisa ${fichero}."
  fi
}

# Emitir un bloque de zona BIND por stdout (master o slave).
# Uso: emit_zona <nombre> <file_path> <rol> <master_ip> <red_cidr>
emit_zona() {
  local nombre="$1"
  local file_path="$2"
  local rol="$3"
  local master_ip="$4"
  local red_cidr="$5"

  if [[ "$rol" == "master" ]]; then
    cat <<EOF

zone "${nombre}" {
    type master;
    file "${file_path}";
    notify yes;
    allow-update { key "rndc-key"; };
    allow-query { 127.0.0.1; ${red_cidr}; };
};
EOF
  else
    cat <<EOF

zone "${nombre}" {
    type slave;
    file "${file_path}";
    masters { ${master_ip}; };
    allow-query { 127.0.0.1; ${red_cidr}; };
};
EOF
  fi
}

configurar_ddns() {
  local dhcpd_conf="/etc/dhcp/dhcpd.conf"
  local named_local="/etc/bind/named.conf.local"
  local ddns_dir="/etc/bind/ddns"

  info "Configuración de DDNS (isc-dhcp-server + bind9)..."

  # --- DHCP ---
  instalar_paquete "isc-dhcp-server" || return 1
  if [[ -f "$dhcpd_conf" ]]; then
    cp "$dhcpd_conf" "${dhcpd_conf}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${dhcpd_conf}.bak_$(date +%F_%T)"
  else
    info "$dhcpd_conf no existe todavía; se omite la copia de seguridad."
  fi

  # --- bind9 ---
  instalar_paquete "bind9" || return 1
  instalar_paquete "bind9utils" || true
  instalar_paquete "dnsutils" || true
  if [[ -f "$named_local" ]]; then
    cp "$named_local" "${named_local}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${named_local}.bak_$(date +%F_%T)"
  else
    info "$named_local no existe todavía; se omite la copia de seguridad."
  fi

  info "Creando directorio de zonas DDNS: $ddns_dir"
  mkdir -p "$ddns_dir"
  chown -R root:bind "$ddns_dir"
  chmod -R 775 "$ddns_dir"
  info "Directorio $ddns_dir listo (root:bind, 775)."

  # --- rndc.key: backup, regeneración y traslado a $ddns_dir ---
  local rndc_key="/etc/bind/rndc.key"
  local rndc_key_ddns="${ddns_dir}/rndc.key"
  if [[ -f "$rndc_key" ]]; then
    cp "$rndc_key" "${rndc_key}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${rndc_key}.bak_$(date +%F_%T)"
  else
    info "$rndc_key no existe todavía; se omite la copia de seguridad."
  fi
  info "Generando nueva clave rndc en $rndc_key..."
  rndc-confgen -a
  info "Moviendo $rndc_key -> $rndc_key_ddns"
  mv -f "$rndc_key" "$rndc_key_ddns"
  info "rndc.key trasladado a $rndc_key_ddns (permisos se uniformizan al final)."

  # --- named.conf: include de la nueva ruta + bloque controls ---
  local named_conf="/etc/bind/named.conf"
  local include_line="include \"${rndc_key_ddns}\";"
  if [[ -f "$named_conf" ]]; then
    cp "$named_conf" "${named_conf}.bak_$(date +%F_%T)"
    info "Copia de seguridad creada: ${named_conf}.bak_$(date +%F_%T)"

    # Quitar cualquier include previo de rndc.key y añadir el nuevo
    sed -i -E '/include[[:space:]]+"[^"]*rndc\.key"[[:space:]]*;/d' "$named_conf"
    echo "$include_line" >>"$named_conf"
    info "Include de rndc.key actualizado en $named_conf"

    # Añadir bloque controls si no existe ya
    if grep -qE '^[[:space:]]*controls[[:space:]]*\{' "$named_conf"; then
      info "Bloque 'controls' ya presente en $named_conf; se omite."
    else
      cat >>"$named_conf" <<'EOF'

controls {
    inet 127.0.0.1 port 953 allow { 127.0.0.1; } keys { "rndc-key"; };
};
EOF
      info "Bloque 'controls' añadido a $named_conf"
    fi
  else
    error "$named_conf no existe; no se puede añadir el include ni controls."
  fi

  # --- named.conf.local: definir zonas (directa + inversa por red) ---
  local num_redes
  while true; do
    input "¿Cuántas redes vas a configurar?" "" num_redes
    if [[ "$num_redes" =~ ^[0-9]+$ ]] && ((num_redes > 0)); then
      break
    fi
    error "Debes introducir un número válido mayor que 0."
  done
  info "Se generarán $((num_redes * 2)) zonas (directa + inversa por red)."

  for ((r = 1; r <= num_redes; r++)); do
    local dominio
    local red
    local oct1 oct2 oct3

    while true; do
      input "Red #$r - Nombre del dominio (zona directa, ej: example.com)" "" dominio
      [[ -n "$dominio" ]] && break
      error "El dominio no puede estar vacío."
    done

    while true; do
      input "Red #$r - Red en formato X.X.X.0/24 (ej: 192.168.1.0/24)" "" red
      if [[ "$red" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}/24$ ]]; then
        oct1="${BASH_REMATCH[1]}"
        oct2="${BASH_REMATCH[2]}"
        oct3="${BASH_REMATCH[3]}"
        break
      fi
      error "Formato inválido. Usa X.X.X.X/24"
    done

    local zona_inversa="${oct3}.${oct2}.${oct1}.in-addr.arpa"
    local file_directa="${ddns_dir}/db.${dominio}"
    local file_inversa="${ddns_dir}/db.${oct1}.${oct2}.${oct3}"
    local red_cidr="${oct1}.${oct2}.${oct3}.0/24"

    local rol_d="" master_ip_d=""
    local rol_i="" master_ip_i=""
    pedir_rol_zona "zona directa '${dominio}'" rol_d master_ip_d
    pedir_rol_zona "zona inversa '${zona_inversa}'" rol_i master_ip_i

    emit_zona "$dominio" "$file_directa" "$rol_d" "$master_ip_d" "$red_cidr" >>"$named_local"
    emit_zona "$zona_inversa" "$file_inversa" "$rol_i" "$master_ip_i" "$red_cidr" >>"$named_local"

    # Si alguna zona es master, generar los ficheros de zona desde plantilla
    if [[ "$rol_d" == "master" || "$rol_i" == "master" ]]; then
      local hostname_srv="" ip_srv="" admin_email="" cname_alias="" last_octet=""

      input "Red #$r - Hostname del servidor DNS (sin dominio)" "serverddns" hostname_srv
      while true; do
        input "Red #$r - IP del servidor DNS (dentro de ${red_cidr})" "" ip_srv
        if [[ "$ip_srv" =~ ^${oct1}\.${oct2}\.${oct3}\.([0-9]{1,3})$ ]]; then
          last_octet="${BASH_REMATCH[1]}"
          break
        fi
        error "La IP debe pertenecer a ${red_cidr}"
      done
      input "Red #$r - Email admin (formato DNS, ej: admin.${dominio})" "admin.${dominio}" admin_email
      if yesno "¿Añadir alias CNAME para ${hostname_srv}?"; then
        input "  Nombre del alias" "" cname_alias
      fi

      if [[ "$rol_d" == "master" ]]; then
        emit_file_directa "$file_directa" "$dominio" "$admin_email" "$hostname_srv" "$ip_srv" "$cname_alias"
        info "Fichero de zona directa creado: $file_directa"
        verificar_zona "$dominio" "$file_directa"
      fi
      if [[ "$rol_i" == "master" ]]; then
        emit_file_inversa "$file_inversa" "$zona_inversa" "$admin_email" "$hostname_srv" "$dominio" "$last_octet"
        info "Fichero de zona inversa creado: $file_inversa"
        verificar_zona "$zona_inversa" "$file_inversa"
      fi

      # Subdominios delegados (solo si la directa es master)
      if [[ "$rol_d" == "master" ]]; then
        local subs_raw=""
        input "Subdominios delegados de ${dominio} (separados por espacios, vacío para omitir)" "" subs_raw
        if [[ -n "$subs_raw" ]]; then
          local -a subs_arr=()
          read -ra subs_arr <<<"$subs_raw"
          for sub in "${subs_arr[@]}"; do
            local sub_fqdn="${sub}.${dominio}"
            local sub_file="${ddns_dir}/db.${sub_fqdn}"

            emit_file_subdominio "$sub_file" "$sub_fqdn" "$admin_email" "$hostname_srv" "$dominio" "$ip_srv"
            info "Subdominio creado: ${sub_fqdn} -> ${sub_file}"

            # Delegación NS en el fichero del padre
            echo "${sub}    IN    NS    ${hostname_srv}.${dominio}." >>"$file_directa"

            # Bloque de zona en named.conf.local
            emit_zona "$sub_fqdn" "$sub_file" "master" "" "$red_cidr" >>"$named_local"

            verificar_zona "$sub_fqdn" "$sub_file"
          done

          # Re-validar el padre tras añadir las delegaciones NS
          if [[ "$rol_d" == "master" ]]; then
            verificar_zona "$dominio" "$file_directa"
          fi
        fi
      fi
    fi

    info "Zonas añadidas red #$r: ${dominio} (${rol_d}) y ${zona_inversa} (${rol_i})"
  done

  info "Configuración de zonas escrita en $named_local"

  # Uniformar permisos recursivamente sobre $ddns_dir
  info "Aplicando chown -R root:bind y chmod -R 775 a $ddns_dir..."
  chown -R root:bind "$ddns_dir"
  chmod -R 775 "$ddns_dir"

  # Validación global de named.conf
  info "Verificando named.conf con named-checkconf..."
  if named-checkconf; then
    info "named.conf OK."
  else
    error "named-checkconf encontró errores. Revisa $named_conf y $named_local."
  fi

  # Backup de seguridad de $ddns_dir antes de que DHCP/DDNS
  # pueda serializar los ficheros de zona a formato binario.
  local backup_dir="${ddns_dir}.bak_$(date +%F_%T)"
  info "Creando copia de respaldo de $ddns_dir en $backup_dir..."
  cp -a "$ddns_dir" "$backup_dir"
  info "Respaldo creado: $backup_dir"

  # TODO DHCP: pedir subred, rango, router, dns y escribir $dhcpd_conf + /etc/default/isc-dhcp-server
  # TODO TSIG: integrar allow-update en bind con update en dhcpd
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
  echo "2) Configurar DDNS (isc-dhcp-server + bind9)"
  echo "3) Salir"
  echo "-------------------------"

  input "Selecciona una opción" "3" OPCION

  case $OPCION in
  1)
    establecer_vlan
    ;;
  2)
    configurar_ddns
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
