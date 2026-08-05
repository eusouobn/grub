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

# Listar discos disponíveis
list_disks() {
    echo -e "\n${YELLOW}Discos disponíveis:${NC}"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL | grep -E "disk|part" | head -n 20
    echo ""
}

# Selecionar disco para chroot
select_chroot_disk() {
    print_header "SELEÇÃO DE DISCO PARA CHROOT"
    
    list_disks
    
    echo "Digite o dispositivo onde o sistema Arch está instalado (ex: /dev/sda, /dev/nvme0n1):"
    read -p "> " CHROOT_DISK
    
    if [[ ! -b "$CHROOT_DISK" ]]; then
        print_error "Dispositivo inválido!"
        exit 1
    fi
    
    # Detectar partições
    print_info "Detectando partições em $CHROOT_DISK..."
    
    # Tentar encontrar partição root
    ROOT_PART=$(lsblk -lno NAME,TYPE,MOUNTPOINT "$CHROOT_DISK" | grep -E "part.*/" | grep -v "/boot" | grep -v "/efi" | head -n1 | awk '{print $1}')
    
    if [[ -z "$ROOT_PART" ]]; then
        print_error "Não foi possível detectar automaticamente a partição root."
        echo "Por favor, informe manualmente a partição root (ex: sda2, nvme0n1p2):"
        read -p "> " ROOT_PART
        ROOT_PART="${CHROOT_DISK%/*}/$ROOT_PART"
    else
        ROOT_PART="/dev/$ROOT_PART"
        print_info "Partição root detectada: $ROOT_PART"
    fi
    
    # Tentar encontrar partição boot/efi
    BOOT_PART=""
    EFI_PART=""
    
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        EFI_PART=$(lsblk -lno NAME,TYPE,FSTYPE,MOUNTPOINT "$CHROOT_DISK" | grep -E "part.*vfat" | grep -E "/boot|/efi" | head -n1 | awk '{print $1}')
        if [[ -z "$EFI_PART" ]]; then
            EFI_PART=$(lsblk -lno NAME,TYPE,FSTYPE "$CHROOT_DISK" | grep -E "part.*vfat" | head -n1 | awk '{print $1}')
        fi
        if [[ -n "$EFI_PART" ]]; then
            EFI_PART="/dev/$EFI_PART"
            print_info "Partição EFI detectada: $EFI_PART"
        else
            print_warning "Partição EFI não detectada automaticamente!"
            echo "Informe manualmente a partição EFI (ex: sda1, nvme0n1p1):"
            read -p "> " EFI_PART_INPUT
            EFI_PART="${CHROOT_DISK%/*}/$EFI_PART_INPUT"
        fi
    else
        # Modo BIOS
        BOOT_PART=$(lsblk -lno NAME,TYPE,MOUNTPOINT "$CHROOT_DISK" | grep -E "part.*/boot" | head -n1 | awk '{print $1}')
        if [[ -z "$BOOT_PART" ]]; then
            print_warning "Partição /boot não detectada. Assumindo que /boot não é separada."
        else
            BOOT_PART="/dev/$BOOT_PART"
            print_info "Partição /boot detectada: $BOOT_PART"
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}Resumo da configuração:${NC}"
    echo "  Disco: $CHROOT_DISK"
    echo "  Root: $ROOT_PART"
    [[ -n "$EFI_PART" ]] && echo "  EFI: $EFI_PART"
    [[ -n "$BOOT_PART" ]] && echo "  Boot: $BOOT_PART"
    echo ""
    
    read -p "Confirmar? (s/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
        print_error "Operação cancelada pelo usuário"
        exit 0
    fi
}

# Montar sistema para chroot
mount_system() {
    print_header "MONTANDO SISTEMA PARA CHROOT"
    
    # Criar diretório de montagem
    MOUNT_DIR="/mnt/arch-chroot"
    mkdir -p "$MOUNT_DIR"
    
    # Montar root
    print_info "Montando root em $MOUNT_DIR..."
    mount "$ROOT_PART" "$MOUNT_DIR"
    
    # Montar boot se existir
    if [[ -n "$BOOT_PART" ]]; then
        print_info "Montando /boot..."
        mkdir -p "$MOUNT_DIR/boot"
        mount "$BOOT_PART" "$MOUNT_DIR/boot"
    fi
    
    # Montar EFI se existir
    if [[ -n "$EFI_PART" ]]; then
        print_info "Montando /boot/efi..."
        mkdir -p "$MOUNT_DIR/boot/efi"
        mount "$EFI_PART" "$MOUNT_DIR/boot/efi"
    fi
    
    # Montar sistemas virtuais
    print_info "Montando sistemas virtuais..."
    mount --bind /dev "$MOUNT_DIR/dev"
    mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
    mount --bind /proc "$MOUNT_DIR/proc"
    mount --bind /sys "$MOUNT_DIR/sys"
    mount --bind /run "$MOUNT_DIR/run"
    
    # Copiar resolv.conf para rede no chroot
    cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
    
    print_success "Sistema montado com sucesso!"
}

# Executar chroot
do_chroot() {
    print_header "ENTRANDO NO CHROOT"
    
    print_info "Para sair do chroot, digite 'exit'"
    echo -e "${YELLOW}Comandos úteis dentro do chroot:${NC}"
    echo "  - Verificar partições: lsblk"
    echo "  - Reinstalar GRUB: grub-install ..."
    echo "  - Gerar configuração: grub-mkconfig -o /boot/grub/grub.cfg"
    echo ""
    read -p "Pressione ENTER para continuar..."
    
    chroot "$MOUNT_DIR" /bin/bash
    
    print_success "Saiu do chroot"
}

# Desmontar sistema
umount_system() {
    print_header "DESMONTANDO SISTEMA"
    
    print_info "Desmontando sistemas virtuais..."
    umount -R "$MOUNT_DIR"/dev 2>/dev/null || true
    umount -R "$MOUNT_DIR"/proc 2>/dev/null || true
    umount -R "$MOUNT_DIR"/sys 2>/dev/null || true
    umount -R "$MOUNT_DIR"/run 2>/dev/null || true
    
    print_info "Desmontando partições..."
    umount "$MOUNT_DIR"/boot/efi 2>/dev/null || true
    umount "$MOUNT_DIR"/boot 2>/dev/null || true
    umount "$MOUNT_DIR" 2>/dev/null || true
    
    print_success "Sistema desmontado!"
}

# Modo direto - reinstalar GRUB sem chroot
reinstall_grub_direct() {
    print_header "REINSTALANDO GRUB DIRETAMENTE"
    
    # Verificar se o sistema está montado
    if [[ ! -d "/boot/grub" ]] && [[ ! -d "/boot/efi/EFI" ]]; then
        print_error "Sistema parece não estar montado corretamente"
        print_info "Execute a opção de chroot primeiro ou monte manualmente"
        return 1
    fi
    
    echo -e "${YELLOW}Seleção de disco para instalação do GRUB:${NC}"
    list_disks
    
    echo "Informe o disco para instalar o GRUB (ex: /dev/sda):"
    read -p "> " GRUB_DISK
    
    if [[ ! -b "$GRUB_DISK" ]]; then
        print_error "Dispositivo inválido!"
        return 1
    fi
    
    echo ""
    echo -e "${YELLOW}Informações de instalação:${NC}"
    echo "  Disco alvo: $GRUB_DISK"
    echo "  Modo: $BOOT_MODE"
    echo "  ID do GRUB: ARCH"
    echo "  Modo removível: ATIVADO"
    echo ""
    read -p "Confirmar instalação? (s/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
        print_error "Operação cancelada"
        return 1
    fi
    
    # Instalar GRUB
    print_info "Instalando GRUB..."
    
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        # UEFI com modo removível
        grub-install --target=x86_64-efi \
                     --efi-directory=/boot/efi \
                     --boot-directory=/boot \
                     --bootloader-id=ARCH \
                     --removable \
                     "$GRUB_DISK"
    else
        # BIOS
        grub-install --target=i386-pc \
                     --boot-directory=/boot \
                     "$GRUB_DISK"
    fi
    
    if [[ $? -eq 0 ]]; then
        print_success "GRUB instalado com sucesso!"
        
        # Gerar configuração
        print_info "Gerando configuração do GRUB..."
        grub-mkconfig -o /boot/grub/grub.cfg
        
        if [[ $? -eq 0 ]]; then
            print_success "Configuração do GRUB gerada com sucesso!"
        else
            print_error "Falha ao gerar configuração do GRUB"
        fi
    else
        print_error "Falha ao instalar GRUB"
        return 1
    fi
}

# Menu principal
main_menu() {
    print_header "RECUPERAÇÃO DO GRUB - ARCH LINUX"
    
    echo "Escolha uma opção:"
    echo "1) Chroot no sistema (modo interativo)"
    echo "2) Reinstalar GRUB diretamente (se já estiver montado)"
    echo "3) Reinstalar GRUB via chroot (automático)"
    echo "4) Sair"
    echo ""
    read -p "Opção [1-4]: " OPTION
    
    case $OPTION in
        1)
            select_chroot_disk
            mount_system
            do_chroot
            umount_system
            ;;
        2)
            detect_boot_mode
            reinstall_grub_direct
            ;;
        3)
            select_chroot_disk
            mount_system
            detect_boot_mode
            reinstall_grub_direct
            umount_system
            ;;
        4)
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