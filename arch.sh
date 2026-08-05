#!/bin/bash

# Script de recuperação do GRUB - Arch Linux
# Uso: sudo ./grub-repair.sh

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Execute como root: sudo $0${NC}"
    exit 1
fi

# Detectar modo de boot
if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="UEFI"
    echo -e "${BLUE}Modo UEFI detectado${NC}"
else
    BOOT_MODE="BIOS"
    echo -e "${BLUE}Modo BIOS detectado${NC}"
fi

# Listar discos
echo -e "\n${YELLOW}Discos disponíveis:${NC}"
echo "----------------------------------------"
DISKS=()
INDEX=1
while read -r disk; do
    [[ -z "$disk" || "$disk" =~ ^loop ]] && continue
    DISKS+=("$disk")
    SIZE=$(lsblk -d -n -o SIZE "/dev/$disk" 2>/dev/null || echo "?")
    MODEL=$(lsblk -d -n -o MODEL "/dev/$disk" 2>/dev/null | head -c 30 || echo "?")
    echo "[$INDEX] /dev/$disk - $SIZE - $MODEL"
    ((INDEX++))
done < <(lsblk -d -n -o NAME)

if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo -e "${RED}Nenhum disco encontrado!${NC}"
    exit 1
fi

# Selecionar disco
echo ""
read -p "Escolha o número do disco para instalar o GRUB: " DISK_NUM
if ! [[ "$DISK_NUM" =~ ^[0-9]+$ ]] || [[ $DISK_NUM -lt 1 ]] || [[ $DISK_NUM -gt ${#DISKS[@]} ]]; then
    echo -e "${RED}Número inválido!${NC}"
    exit 1
fi

SELECTED_DISK="/dev/${DISKS[$((DISK_NUM-1))]}"
echo -e "${GREEN}Disco selecionado: $SELECTED_DISK${NC}"

# Mostrar partições
echo -e "\n${YELLOW}Partições em $SELECTED_DISK:${NC}"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$SELECTED_DISK"

# Detectar partição root
ROOT_PART=""
for part in $(lsblk -lno NAME "$SELECTED_DISK" | grep -v "^$" | grep -v "loop"); do
    FSTYPE=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
    if [[ "$FSTYPE" =~ (ext[234]|btrfs|xfs|f2fs|reiserfs) ]]; then
        ROOT_PART="/dev/$part"
        break
    fi
done

if [[ -z "$ROOT_PART" ]]; then
    echo -e "${YELLOW}Não foi possível detectar automaticamente a partição root.${NC}"
    read -p "Digite o nome da partição root (ex: sda2, nvme0n1p2): " ROOT_INPUT
    ROOT_PART="${SELECTED_DISK%/*}/$ROOT_INPUT"
fi
echo -e "${GREEN}Partição root: $ROOT_PART${NC}"

# Detectar partição EFI (se UEFI)
EFI_PART=""
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    for part in $(lsblk -lno NAME "$SELECTED_DISK" | grep -v "^$" | grep -v "loop"); do
        FSTYPE=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
        if [[ "$FSTYPE" == "vfat" ]]; then
            EFI_PART="/dev/$part"
            break
        fi
    done
    if [[ -z "$EFI_PART" ]]; then
        echo -e "${YELLOW}Partição EFI não detectada.${NC}"
        read -p "Digite o nome da partição EFI (ex: sda1, nvme0n1p1): " EFI_INPUT
        EFI_PART="${SELECTED_DISK%/*}/$EFI_INPUT"
    fi
    echo -e "${GREEN}Partição EFI: $EFI_PART${NC}"
fi

# Resumo
echo ""
echo -e "${YELLOW}Resumo da configuração:${NC}"
echo "  Disco alvo: $SELECTED_DISK"
echo "  Modo: $BOOT_MODE"
echo "  Root: $ROOT_PART"
[[ -n "$EFI_PART" ]] && echo "  EFI: $EFI_PART"
echo "  ID do GRUB: ARCH"
echo "  Modo removível: ATIVADO"
echo ""
read -p "Prosseguir com a reinstalação? (s/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "Cancelado."
    exit 0
fi

# Montar sistema
MOUNT_DIR="/mnt/arch-chroot"
mkdir -p "$MOUNT_DIR"
echo -e "${BLUE}Montando $ROOT_PART em $MOUNT_DIR...${NC}"
mount "$ROOT_PART" "$MOUNT_DIR" || { echo -e "${RED}Falha ao montar root${NC}"; exit 1; }

if [[ -n "$EFI_PART" ]]; then
    mkdir -p "$MOUNT_DIR/boot/efi"
    echo -e "${BLUE}Montando $EFI_PART em $MOUNT_DIR/boot/efi...${NC}"
    mount "$EFI_PART" "$MOUNT_DIR/boot/efi" || echo -e "${YELLOW}Aviso: falha ao montar EFI${NC}"
fi

# Montar sistemas virtuais
mount --bind /dev "$MOUNT_DIR/dev" 2>/dev/null || true
mount --bind /proc "$MOUNT_DIR/proc" 2>/dev/null || true
mount --bind /sys "$MOUNT_DIR/sys" 2>/dev/null || true

# Instalar GRUB
echo -e "${BLUE}Instalando GRUB...${NC}"
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    if [[ -d "$MOUNT_DIR/boot/efi" ]]; then
        EFI_DIR="/boot/efi"
    else
        EFI_DIR="/boot"
    fi
    chroot "$MOUNT_DIR" grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --boot-directory=/boot --bootloader-id=ARCH --removable "$SELECTED_DISK"
else
    chroot "$MOUNT_DIR" grub-install --target=i386-pc --boot-directory=/boot "$SELECTED_DISK"
fi

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}GRUB instalado com sucesso!${NC}"
else
    echo -e "${RED}Falha na instalação do GRUB${NC}"
    exit 1
fi

# Gerar configuração
echo -e "${BLUE}Gerando grub.cfg...${NC}"
chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg

# Desmontar
echo -e "${BLUE}Desmontando...${NC}"
umount "$MOUNT_DIR/boot/efi" 2>/dev/null || true
umount "$MOUNT_DIR/dev" 2>/dev/null || true
umount "$MOUNT_DIR/proc" 2>/dev/null || true
umount "$MOUNT_DIR/sys" 2>/dev/null || true
umount "$MOUNT_DIR" 2>/dev/null || true

echo -e "${GREEN}Concluído! O GRUB foi reinstalado no disco $SELECTED_DISK com ID 'ARCH' e modo removível.${NC}"
echo "Reinicie o sistema para testar."