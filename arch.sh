#!/bin/bash

# Script para corrigir/reinstalar o GRUB no Arch Linux
# Compatível com BIOS e UEFI
# GRUB ID: ARCH
# Modo removível: ativado

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Variáveis globais
SELECTED_DISK=""
ROOT_PART=""
EFI_PART=""
BOOT_PART=""
MOUNT_DIR="/mnt/arch-chroot"
BOOT_MODE=""
SELECTED_DISK_NUMBER=0

# Funções de ajuda
print_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCESSO]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

# Verificar se está rodando como root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Este script precisa ser executado como root!"
        echo "Execute: sudo $0"
        exit 1
    fi
}

# Detectar sistema de arquivos e modo de boot
detect_boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="UEFI"
        print_info "Sistema em modo UEFI detectado"
    else
        BOOT_MODE="BIOS"
        print_info "Sistema em modo BIOS detectado"
    fi
}

# Listar discos com detalhes completos
list_disks_detailed() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}DISPOSITIVOS DE ARMAZENAMENTO DISPONÍVEIS${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    local count=0
    local disk_list=()
    
    # Coletar informações de todos os discos
    while IFS= read -r disk; do
        count=$((count + 1))
        disk_list+=("$disk")
        
        # Informações básicas do disco
        local disk_name="/dev/$disk"
        local disk_size=$(lsblk -d -n -o SIZE "$disk_name" 2>/dev/null || echo "N/A")
        local disk_model=$(lsblk -d -n -o MODEL "$disk_name" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//' || echo "N/A")
        local disk_serial=$(lsblk -d -n -o SERIAL "$disk_name" 2>/dev/null || echo "N/A")
        local disk_rota=$(lsblk -d -n -o ROTA "$disk_name" 2>/dev/null || echo "N/A")
        local disk_type="HDD"
        [[ "$disk_rota" == "0" ]] && disk_type="SSD"
        
        # Informações de partições
        local partitions=$(lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,MODEL "$disk_name" 2>/dev/null | grep -E "^[─└├]" | sed 's/^[─└├]//' | sed 's/^[ \t]*//')
        local part_count=$(echo "$partitions" | grep -c . || echo "0")
        
        # Detectar sistema operacional
        local os_detected=""
        if echo "$partitions" | grep -q -E "(ext[234]|btrfs|xfs|f2fs|reiserfs)"; then
            os_detected="🐧 Linux"
        fi
        if echo "$partitions" | grep -q "vfat.*EFI"; then
            os_detected="$os_detected 🔵 EFI"
        fi
        if echo "$partitions" | grep -q "ntfs"; then
            os_detected="$os_detected 🪟 Windows"
        fi
        [[ -z "$os_detected" ]] && os_detected="❓ Desconhecido"
        
        # Exibir informações do disco
        echo ""
        echo -e "${MAGENTA}┌────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${GREEN}│ ${CYAN}[${count}]${NC} DISCO: ${YELLOW}$disk_name${NC}                                                         │"
        echo -e "${GREEN}│${NC}  ├─ Tamanho: ${BLUE}$disk_size${NC}  |  Tipo: ${BLUE}$disk_type${NC}  |  Modelo: ${BLUE}$disk_model${NC}"
        [[ -n "$disk_serial" && "$disk_serial" != "N/A" ]] && echo -e "${GREEN}│${NC}  ├─ Serial: ${BLUE}$disk_serial${NC}"
        echo -e "${GREEN}│${NC}  ├─ Partições: ${BLUE}$part_count${NC}  |  SO detectado: ${YELLOW}$os_detected${NC}"
        
        # Mostrar partições detalhadas
        if [[ $part_count -gt 0 ]]; then
            echo -e "${GREEN}│${NC}  └─ Partições:"
            local part_num=0
            while IFS= read -r part; do
                part_num=$((part_num + 1))
                # Extrair informações da partição
                local part_name=$(echo "$part" | awk '{print $1}')
                local part_size=$(echo "$part" | awk '{print $2}')
                local part_fstype=$(echo "$part" | awk '{print $3}')
                local part_mount=$(echo "$part" | awk '{print $4}')
                local part_label=$(echo "$part" | awk '{print $5}')
                local part_model=$(echo "$part" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
                
                # Ícones para tipos de sistema de arquivos
                local fs_icon="📁"
                case "$part_fstype" in
                    *ext*) fs_icon="🐧" ;;
                    *vfat*) fs_icon="💾" ;;
                    *ntfs*) fs_icon="🪟" ;;
                    *btrfs*) fs_icon="🌳" ;;
                    *xfs*) fs_icon="⚡" ;;
                    *swap*) fs_icon="🔄" ;;
                    *) fs_icon="📁" ;;
                esac
                
                # Identificar partições importantes
                local part_role=""
                if [[ "$part_fstype" == "vfat" ]] || [[ "$part_fstype" == "fat"* ]]; then
                    if [[ "$part_mount" == "/boot/efi" ]] || [[ "$part_mount" == "/boot" ]] || [[ "$part_mount" == "/efi" ]]; then
                        part_role="${GREEN}[EFI]${NC}"
                    else
                        part_role="${BLUE}[FAT]${NC}"
                    fi
                elif [[ "$part_fstype" =~ (ext[234]|btrfs|xfs|f2fs|reiserfs) ]]; then
                    if [[ "$part_mount" == "/" ]] || [[ "$part_mount" == "/root" ]]; then
                        part_role="${GREEN}[ROOT]${NC}"
                    elif [[ "$part_mount" == "/boot" ]]; then
                        part_role="${YELLOW}[BOOT]${NC}"
                    elif [[ "$part_mount" == "/home" ]]; then
                        part_role="${BLUE}[HOME]${NC}"
                    else
                        part_role="${CYAN}[LINUX]${NC}"
                    fi
                elif [[ "$part_fstype" == "ntfs" ]]; then
                    part_role="${BLUE}[WINDOWS]${NC}"
                fi
                
                # Formatar saída da partição
                local mount_info=""
                [[ -n "$part_mount" && "$part_mount" != "-" ]] && mount_info=" → ${YELLOW}${part_mount}${NC}"
                [[ -n "$part_label" && "$part_label" != "-" && "$part_label" != "" ]] && label_info=" (${CYAN}$part_label${NC})" || label_info=""
                
                echo -e "${GREEN}│${NC}     ${fs_icon} ${part_name}  ${BLUE}$part_size${NC}  ${part_fstype:-"desconhecido"}  ${part_role}$label_info$mount_info"
                
            done < <(echo "$partitions")
        fi
        echo -e "${MAGENTA}└────────────────────────────────────────────────────────────────────────┘${NC}"
        
    done < <(lsblk -d -n -o NAME | grep -v "loop")
    
    echo ""
    echo -e "${CYAN}Total de ${count} discos encontrados${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════════════════════${NC}\n"
    
    return $count
}

# Selecionar disco por número
select_disk() {
    print_header "SELEÇÃO DE DISCO PARA INSTALAÇÃO DO GRUB"
    
    list_disks_detailed
    
    local total_disks=$(lsblk -d -n -o NAME | grep -v "loop" | wc -l)
    
    if [[ $total_disks -eq 0 ]]; then
        print_error "Nenhum disco encontrado!"
        exit 1
    fi
    
    echo "Selecione o disco para instalar o GRUB (1-$total_disks):"
    read -p "> " DISK_NUMBER
    
    # Validar entrada
    if ! [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]] || [[ $DISK_NUMBER -lt 1 ]] || [[ $DISK_NUMBER -gt $total_disks ]]; then
        print_error "Número inválido! Digite um número entre 1 e $total_disks"
        exit 1
    fi
    
    SELECTED_DISK_NUMBER=$DISK_NUMBER
    SELECTED_DISK="/dev/$(lsblk -d -n -o NAME | grep -v "loop" | sed -n "${DISK_NUMBER}p")"
    print_success "Disco selecionado: $SELECTED_DISK"
    
    # Detectar partições automaticamente
    detect_partitions
}

# Detectar partições automaticamente
detect_partitions() {
    print_info "Analisando partições em $SELECTED_DISK..."
    
    # Mostrar partições do disco selecionado com mais detalhes
    echo -e "\n${YELLOW}Partições do disco $SELECTED_DISK:${NC}"
    echo "┌─────────────────────────────────────────────────────────────────────────────┐"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL,UUID "$SELECTED_DISK" | \
        awk 'NR==1 {printf "│ %-30s %-8s %-10s %-12s %-15s %-20s │\n", $1, $2, $3, $4, $5, $6}
             NR>1  {printf "│ %-30s %-8s %-10s %-12s %-15s %-20s │\n", $1, $2, $3, $4, $5, $6}'
    echo "└─────────────────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Buscar todas as partições Linux (root)
    local linux_parts=()
    while IFS= read -r part; do
        [[ -n "$part" ]] && linux_parts+=("$part")
    done < <(lsblk -lno NAME,TYPE,FSTYPE "$SELECTED_DISK" | grep -E "part.*(ext[234]|btrfs|xfs|f2fs|reiserfs)" | awk '{print $1}')
    
    if [[ ${#linux_parts[@]} -gt 1 ]]; then
        print_warning "Múltiplas partições Linux encontradas!"
        echo "Selecione a partição root:"
        local part_num=0
        for part in "${linux_parts[@]}"; do
            part_num=$((part_num + 1))
            local part_size=$(lsblk -n -o SIZE "/dev/$part" 2>/dev/null)
            local part_fs=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
            local part_label=$(lsblk -n -o LABEL "/dev/$part" 2>/dev/null)
            [[ -z "$part_label" ]] && part_label="sem label"
            echo "  $part_num) /dev/$part - $part_size - $part_fs - $part_label"
        done
        read -p "> " PART_CHOICE
        if [[ "$PART_CHOICE" =~ ^[0-9]+$ ]] && [[ $PART_CHOICE -ge 1 ]] && [[ $PART_CHOICE -le ${#linux_parts[@]} ]]; then
            ROOT_PART="/dev/${linux_parts[$((PART_CHOICE-1))]}"
        else
            print_error "Seleção inválida!"
            exit 1
        fi
    elif [[ ${#linux_parts[@]} -eq 1 ]]; then
        ROOT_PART="/dev/${linux_parts[0]}"
        print_info "Partição root detectada: $ROOT_PART"
    else
        print_warning "Nenhuma partição Linux detectada!"
        echo "Informe manualmente a partição root (ex: sda2, nvme0n1p2):"
        read -p "> " ROOT_INPUT
        ROOT_PART="${SELECTED_DISK%/*}/$ROOT_INPUT"
    fi
    
    # Detectar partição EFI (UEFI)
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        local efi_parts=()
        while IFS= read -r part; do
            [[ -n "$part" ]] && efi_parts+=("$part")
        done < <(lsblk -lno NAME,TYPE,FSTYPE "$SELECTED_DISK" | grep -E "part.*vfat" | awk '{print $1}')
        
        if [[ ${#efi_parts[@]} -gt 1 ]]; then
            print_warning "Múltiplas partições FAT/EFI encontradas!"
            echo "Selecione a partição EFI:"
            local part_num=0
            for part in "${efi_parts[@]}"; do
                part_num=$((part_num + 1))
                local part_size=$(lsblk -n -o SIZE "/dev/$part" 2>/dev/null)
                local part_label=$(lsblk -n -o LABEL "/dev/$part" 2>/dev/null)
                [[ -z "$part_label" ]] && part_label="sem label"
                local part_mount=$(lsblk -n -o MOUNTPOINT "/dev/$part" 2>/dev/null)
                [[ -z "$part_mount" ]] && part_mount="não montado"
                echo "  $part_num) /dev/$part - $part_size - $part_label - $part_mount"
            done
            read -p "> " PART_CHOICE
            if [[ "$PART_CHOICE" =~ ^[0-9]+$ ]] && [[ $PART_CHOICE -ge 1 ]] && [[ $PART_CHOICE -le ${#efi_parts[@]} ]]; then
                EFI_PART="/dev/${efi_parts[$((PART_CHOICE-1))]}"
            else
                print_error "Seleção inválida!"
                exit 1
            fi
        elif [[ ${#efi_parts[@]} -eq 1 ]]; then
            EFI_PART="/dev/${efi_parts[0]}"
            print_info "Partição EFI detectada: $EFI_PART"
        else
            print_warning "Partição EFI não detectada automaticamente!"
            echo "Informe manualmente a partição EFI (ex: sda1, nvme0n1p1):"
            read -p "> " EFI_INPUT
            EFI_PART="${SELECTED_DISK%/*}/$EFI_INPUT"
        fi
    fi
    
    # Detectar partição /boot separada
    local boot_parts=()
    while IFS= read -r part; do
        [[ -n "$part" ]] && boot_parts+=("$part")
    done < <(lsblk -lno NAME,TYPE,MOUNTPOINT "$SELECTED_DISK" | grep -E "part.*/boot" | awk '{print $1}')
    
    if [[ ${#boot_parts[@]} -gt 0 ]]; then
        if [[ ${#boot_parts[@]} -gt 1 ]]; then
            print_warning "Múltiplas partições /boot encontradas!"
        fi
        BOOT_PART="/dev/${boot_parts[0]}"
        print_info "Partição /boot separada detectada: $BOOT_PART"
    fi
    
    # Confirmar partições
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}RESUMO DA CONFIGURAÇÃO:${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo "  ${GREEN}Disco alvo:${NC} $SELECTED_DISK"
    echo "  ${GREEN}Modo:${NC} $BOOT_MODE"
    echo "  ${GREEN}Partição Root:${NC} $ROOT_PART"
    [[ -n "$EFI_PART" ]] && echo "  ${GREEN}Partição EFI:${NC} $EFI_PART"
    [[ -n "$BOOT_PART" ]] && echo "  ${GREEN}Partição /boot:${NC} $BOOT_PART"
    echo "  ${GREEN}ID do GRUB:${NC} ARCH"
    echo "  ${GREEN}Modo removível:${NC} ATIVADO"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "Confirmar configuração? (s/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
        print_error "Operação cancelada pelo usuário"
        exit 0
    fi
}

# Montar sistema para chroot
mount_system() {
    print_header "MONTANDO SISTEMA PARA CHROOT"
    
    # Verificar se a partição root existe
    if [[ ! -b "$ROOT_PART" ]]; then
        print_error "Partição root $ROOT_PART não existe!"
        exit 1
    fi
    
    # Criar diretório de montagem
    mkdir -p "$MOUNT_DIR"
    
    # Montar root
    print_info "Montando root em $MOUNT_DIR..."
    mount "$ROOT_PART" "$MOUNT_DIR" || {
        print_error "Falha ao montar root"
        exit 1
    }
    
    # Montar boot se existir
    if [[ -n "$BOOT_PART" ]] && [[ -b "$BOOT_PART" ]]; then
        print_info "Montando /boot..."
        mkdir -p "$MOUNT_DIR/boot"
        mount "$BOOT_PART" "$MOUNT_DIR/boot" || {
            print_warning "Falha ao montar /boot, continuando..."
        }
    fi
    
    # Montar EFI se existir (UEFI)
    if [[ "$BOOT_MODE" == "UEFI" ]] && [[ -n "$EFI_PART" ]] && [[ -b "$EFI_PART" ]]; then
        print_info "Montando /boot/efi..."
        mkdir -p "$MOUNT_DIR/boot/efi"
        mount "$EFI_PART" "$MOUNT_DIR/boot/efi" || {
            print_warning "Falha ao montar /boot/efi, continuando..."
        }
    fi
    
    # Montar sistemas virtuais
    print_info "Montando sistemas virtuais..."
    mount --bind /dev "$MOUNT_DIR/dev" 2>/dev/null || true
    mount --bind /dev/pts "$MOUNT_DIR/dev/pts" 2>/dev/null || true
    mount --bind /proc "$MOUNT_DIR/proc" 2>/dev/null || true
    mount --bind /sys "$MOUNT_DIR/sys" 2>/dev/null || true
    mount --bind /run "$MOUNT_DIR/run" 2>/dev/null || true
    
    # Copiar resolv.conf para rede no chroot
    cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true
    
    print_success "Sistema montado com sucesso!"
}

# Reinstalar GRUB
reinstall_grub() {
    print_header "REINSTALANDO GRUB"
    
    print_info "Instalando GRUB no disco $SELECTED_DISK..."
    
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        # Verificar diretório EFI
        EFI_DIR=""
        if [[ -d "$MOUNT_DIR/boot/efi" ]]; then
            EFI_DIR="/boot/efi"
        elif [[ -d "$MOUNT_DIR/boot" ]] && [[ -d "$MOUNT_DIR/boot/EFI" ]]; then
            EFI_DIR="/boot"
        elif [[ -d "$MOUNT_DIR/efi" ]]; then
            EFI_DIR="/efi"
        else
            # Criar diretório EFI se não existir
            mkdir -p "$MOUNT_DIR/boot/efi"
            EFI_DIR="/boot/efi"
        fi
        
        print_info "Diretório EFI: $EFI_DIR"
        print_info "Instalando GRUB UEFI com --removable..."
        
        # Comando para UEFI
        cat > "$MOUNT_DIR/tmp/install-grub.sh" << 'EOF'
#!/bin/bash
grub-install --target=x86_64-efi \
             --efi-directory="$1" \
             --boot-directory=/boot \
             --bootloader-id=ARCH \
             --removable \
             "$2"
EOF
        chmod +x "$MOUNT_DIR/tmp/install-grub.sh"
        
        # Executar comando no chroot
        chroot "$MOUNT_DIR" /tmp/install-grub.sh "$EFI_DIR" "$SELECTED_DISK"
        local result=$?
        rm -f "$MOUNT_DIR/tmp/install-grub.sh"
        
        if [[ $result -eq 0 ]]; then
            print_success "GRUB UEFI instalado com sucesso!"
        else
            print_error "Falha ao instalar GRUB UEFI"
            return 1
        fi
    else
        # Modo BIOS
        print_info "Instalando GRUB BIOS..."
        
        cat > "$MOUNT_DIR/tmp/install-grub.sh" << 'EOF'
#!/bin/bash
grub-install --target=i386-pc \
             --boot-directory=/boot \
             "$1"
EOF
        chmod +x "$MOUNT_DIR/tmp/install-grub.sh"
        
        chroot "$MOUNT_DIR" /tmp/install-grub.sh "$SELECTED_DISK"
        local result=$?
        rm -f "$MOUNT_DIR/tmp/install-grub.sh"
        
        if [[ $result -eq 0 ]]; then
            print_success "GRUB BIOS instalado com sucesso!"
        else
            print_error "Falha ao instalar GRUB BIOS"
            return 1
        fi
    fi
    
    # Gerar configuração do GRUB
    print_info "Gerando configuração do GRUB..."
    
    chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg
    
    if [[ $? -eq 0 ]]; then
        print_success "Configuração do GRUB gerada com sucesso!"
    else
        print_warning "Falha ao gerar configuração do GRUB (pode ser necessário verificar manualmente)"
    fi
}

# Desmontar sistema
umount_system() {
    print_header "DESMONTANDO SISTEMA"
    
    # Sair do diretório montado se estiver nele
    cd /
    
    print_info "Desmontando sistemas virtuais..."
    umount "$MOUNT_DIR/dev/pts" 2>/dev/null || true
    umount "$MOUNT_DIR/dev" 2>/dev/null || true
    umount "$MOUNT_DIR/proc" 2>/dev/null || true
    umount "$MOUNT_DIR/sys" 2>/dev/null || true
    umount "$MOUNT_DIR/run" 2>/dev/null || true
    
    print_info "Desmontando partições..."
    umount "$MOUNT_DIR/boot/efi" 2>/dev/null || true
    umount "$MOUNT_DIR/boot" 2>/dev/null || true
    umount "$MOUNT_DIR" 2>/dev/null || true
    
    # Remover diretório de montagem se estiver vazio
    rmdir "$MOUNT_DIR" 2>/dev/null || true
    
    print_success "Sistema desmontado!"
}

# Modo completo - montar e reinstalar
full_repair() {
    print_header "RECUPERAÇÃO COMPLETA DO GRUB"
    
    select_disk
    mount_system
    reinstall_grub
    umount_system
    
    print_success "Recuperação do GRUB concluída!"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}RECOMENDAÇÕES:${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo "  ${BLUE}1.${NC} Reinicie o sistema: ${YELLOW}reboot${NC}"
    echo "  ${BLUE}2.${NC} Verifique se o boot está funcionando corretamente"
    echo "  ${BLUE}3.${NC} Se necessário, entre no UEFI/BIOS e configure o boot"
    echo "  ${BLUE}4.${NC} Verifique a ordem de boot no firmware"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
}

# Menu principal
main_menu() {
    print_header "RECUPERAÇÃO DO GRUB - ARCH LINUX"
    
    echo -e "${CYAN}Este script vai reinstalar o GRUB automaticamente${NC}"
    echo ""
    echo -e "${YELLOW}Configurações padrão:${NC}"
    echo "  • Bootloader ID: ${GREEN}ARCH${NC}"
    echo "  • Modo removível: ${GREEN}ATIVADO${NC}"
    echo "  • Suporte: ${GREEN}UEFI e BIOS${NC}"
    echo ""
    echo -e "${CYAN}Escolha uma opção:${NC}"
    echo -e "  ${GREEN}1)${NC} Recuperação automática (recomendado)"
    echo -e "  ${BLUE}2)${NC} Montar sistema para chroot manual"
    echo -e "  ${RED}3)${NC} Sair"
    echo ""
    read -p "Opção [1-3]: " OPTION
    
    case $OPTION in
        1)
            full_repair
            ;;
        2)
            select_disk
            mount_system
            print_info "Sistema montado em $MOUNT_DIR"
            echo -e "${YELLOW}Para entrar no chroot:${NC}"
            echo "  chroot $MOUNT_DIR /bin/bash"
            echo ""
            echo -e "${YELLOW}Para desmontar:${NC}"
            echo "  umount -R $MOUNT_DIR"
            echo ""
            read -p "Pressione ENTER para desmontar o sistema..."
            umount_system
            ;;
        3)
            print_info "Saindo..."
            exit 0
            ;;
        *)
            print_error "Opção inválida!"
            exit 1
            ;;
    esac
}

# Inicialização
check_root
detect_boot_mode
main_menu

print_success "Script finalizado com sucesso!"