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
NC='\033[0m' # No Color

# Variáveis globais
SELECTED_DISK=""
ROOT_PART=""
EFI_PART=""
BOOT_PART=""
MOUNT_DIR="/mnt/arch-chroot"
BOOT_MODE=""

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

# Listar discos com números
list_disks_numbered() {
    echo -e "\n${YELLOW}Discos disponíveis:${NC}"
    echo "┌───┬─────────────────────────────┬──────────┬─────────────┐"
    echo "│ # │ Disco                       │ Tamanho  │ Modelo      │"
    echo "├───┼─────────────────────────────┼──────────┼─────────────┤"
    
    local count=0
    while IFS= read -r line; do
        count=$((count + 1))
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
        # Truncar nomes longos
        name_display=$(printf "%-27.27s" "/dev/$name")
        size_display=$(printf "%-8.8s" "$size")
        model_display=$(printf "%-11.11s" "$model")
        echo "│ $count │ $name_display │ $size_display │ $model_display │"
    done < <(lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME")
    
    echo "└───┴─────────────────────────────┴──────────┴─────────────┘"
    echo ""
    return $count
}

# Selecionar disco por número
select_disk() {
    print_header "SELEÇÃO DE DISCO PARA INSTALAÇÃO DO GRUB"
    
    local total_disks=$(list_disks_numbered)
    
    if [[ $total_disks -eq 0 ]]; then
        print_error "Nenhum disco encontrado!"
        exit 1
    fi
    
    echo "Selecione o disco para instalar o GRUB (1-$total_disks):"
    read -p "> " DISK_NUMBER
    
    # Validar entrada
    if ! [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]] || [[ $DISK_NUMBER -lt 1 ]] || [[ $DISK_NUMBER -gt $total_disks ]]; then
        print_error "Número inválido!"
        exit 1
    fi
    
    # Obter nome do disco selecionado
    SELECTED_DISK="/dev/$(lsblk -d -o NAME | grep -v "NAME" | sed -n "${DISK_NUMBER}p")"
    print_info "Disco selecionado: $SELECTED_DISK"
    
    # Detectar partições automaticamente
    detect_partitions
}

# Detectar partições automaticamente
detect_partitions() {
    print_info "Detectando partições em $SELECTED_DISK..."
    
    # Mostrar partições do disco
    echo -e "\n${YELLOW}Partições do disco $SELECTED_DISK:${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$SELECTED_DISK" | grep -E "NAME|part"
    echo ""
    
    # Detectar partição root (sistema de arquivos Linux)
    ROOT_PART=$(lsblk -lno NAME,TYPE,FSTYPE "$SELECTED_DISK" | grep -E "part.*(ext[234]|btrfs|xfs|f2fs|reiserfs)" | head -n1 | awk '{print $1}')
    
    if [[ -n "$ROOT_PART" ]]; then
        ROOT_PART="/dev/$ROOT_PART"
        print_info "Partição root detectada: $ROOT_PART"
    else
        print_warning "Não foi possível detectar automaticamente a partição root"
        echo "Informe manualmente a partição root (ex: sda2, nvme0n1p2):"
        read -p "> " ROOT_INPUT
        ROOT_PART="${SELECTED_DISK%/*}/$ROOT_INPUT"
    fi
    
    # Detectar partição EFI (UEFI)
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        EFI_PART=$(lsblk -lno NAME,TYPE,FSTYPE "$SELECTED_DISK" | grep -E "part.*vfat" | head -n1 | awk '{print $1}')
        
        if [[ -n "$EFI_PART" ]]; then
            EFI_PART="/dev/$EFI_PART"
            print_info "Partição EFI detectada: $EFI_PART"
        else
            print_warning "Partição EFI não detectada automaticamente!"
            echo "Informe manualmente a partição EFI (ex: sda1, nvme0n1p1):"
            read -p "> " EFI_INPUT
            EFI_PART="${SELECTED_DISK%/*}/$EFI_INPUT"
        fi
    fi
    
    # Detectar partição /boot separada
    BOOT_PART=$(lsblk -lno NAME,TYPE,MOUNTPOINT "$SELECTED_DISK" | grep -E "part.*/boot" | head -n1 | awk '{print $1}')
    if [[ -n "$BOOT_PART" ]]; then
        BOOT_PART="/dev/$BOOT_PART"
        print_info "Partição /boot separada detectada: $BOOT_PART"
    fi
    
    # Confirmar partições
    echo ""
    echo -e "${YELLOW}Resumo da configuração:${NC}"
    echo "  Disco alvo: $SELECTED_DISK"
    echo "  Modo: $BOOT_MODE"
    echo "  Root: $ROOT_PART"
    [[ -n "$EFI_PART" ]] && echo "  EFI: $EFI_PART"
    [[ -n "$BOOT_PART" ]] && echo "  Boot: $BOOT_PART"
    echo "  ID do GRUB: ARCH"
    echo "  Modo removível: ATIVADO"
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
    echo -e "${GREEN}Recomendações:${NC}"
    echo "1. Reinicie o sistema: reboot"
    echo "2. Verifique se o boot está funcionando corretamente"
    echo "3. Se necessário, entre no UEFI/BIOS e configure o boot"
}

# Menu principal
main_menu() {
    print_header "RECUPERAÇÃO DO GRUB - ARCH LINUX"
    
    echo "Este script vai reinstalar o GRUB automaticamente"
    echo "Configurações:"
    echo "  • Bootloader ID: ARCH"
    echo "  • Modo removível: ATIVADO"
    echo "  • Suporte UEFI e BIOS"
    echo ""
    echo "Escolha uma opção:"
    echo "1) Recuperação automática (recomendado)"
    echo "2) Montar sistema para chroot manual"
    echo "3) Sair"
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