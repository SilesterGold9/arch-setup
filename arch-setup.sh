#!/bin/bash
# =====================================================
# Arch Setup Script - v2.5 PRO
# Author: Silvestre Dourado
# GitHub: github.com/SilesterGold9
# License: MIT
# =====================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------- CONFIG ----------------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; BLUE="\e[34m"; CYAN="\e[36m"; MAGENTA="\e[35m"; BOLD="\e[1m"; RESET="\e[0m"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/arch_setup_$(date +%Y%m%d-%H%M%S).log"
PROFILE_FILE="$HOME/.arch-setup-profile"
AUTOMODE=""         # set by --auto
MODULE_ONLY=""      # set by --module

# ---------------- LOG & ERROR ----------------
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
handle_error() {
    echo -e "\n${RED}❌ Erro na linha $1: $2${RESET}"
    echo -e "${YELLOW}Verifique o log: $LOG_FILE${RESET}"
    log "ERRO: Linha $1 - $2"
    exit 1
}
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# ---------------- HELPERS ----------------
is_installed_pacman() {
    for pkg in "$@"; do
        if pacman -Qi "$pkg" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}
is_installed_cmd() {
    command -v "$1" >/dev/null 2>&1
}
confirm() {
    while true; do
        read -rp "$1 [s/N]: " resp
        case "$resp" in
            [sS]) return 0;;
            [yY]) return 0;; # accept 'y' as well
            [nN]|"") return 1;;
        esac
    done
}

# ---------------- PRECHECKS ----------------
check_root() {
    if [[ $EUID -eq 0 ]]; then
        echo -e "${RED}Não execute este script como root. Rode como usuário normal (com sudo).${RESET}"
        exit 1
    fi
}
check_internet() {
    echo -e "${CYAN}Verificando internet...${RESET}"
    if ! ping -c1 8.8.8.8 >/dev/null 2>&1; then
        echo -e "${RED}Sem conexão. Conecte-se e tente novamente.${RESET}"
        exit 1
    fi
}

# ---------------- GPU DETECTION ----------------
GPU_TYPE="unknown"
GPU_PKGS=()
detect_gpu() {
    log "Detectando GPU..."
    if lspci | grep -i 'NVIDIA' >/dev/null 2>&1; then
        GPU_TYPE="nvidia"
        GPU_PKGS=(nvidia nvidia-utils lib32-nvidia-utils)
    elif lspci | grep -i 'AMD' >/dev/null 2>&1 || lspci | grep -i 'Advanced Micro Devices' >/dev/null 2>&1; then
        GPU_TYPE="amd"
        GPU_PKGS=(mesa vulkan-radeon xf86-video-amdgpu lib32-mesa)
    elif lspci | grep -i 'Intel' >/dev/null 2>&1; then
        GPU_TYPE="intel"
        # Intel Iris / iGPU recommended packages
        GPU_PKGS=(mesa vulkan-intel intel-media-driver libva-intel-driver libva)
    else
        GPU_TYPE="unknown"
        GPU_PKGS=(mesa lib32-mesa)
    fi
    log "GPU detectada: $GPU_TYPE"
}

# ---------------- ASCII LOGO ----------------
logo_ascii() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat <<'EOF'
      _             _     
     / \   _ __ ___| |__  
    / _ \ | '__/ __| '_ \ 
   / ___ \| | | (__| | | |
  /_/   \_\_|  \___|_| |_|   Arch Setup v2.5 PRO

EOF
    echo -e "${RESET}${BOLD}Script interativo pós-install (modular)${RESET}"
    echo -e "Autor: ${YELLOW}Silvestre Dourado${RESET} | GitHub: ${YELLOW}github.com/SilesterGold9${RESET}"
    echo "------------------------------------------------------------"
}

# ---------------- PROGRESS BAR (step based) ----------------
progress_bar() {
    local pct=$1; local total=40
    local filled=$((pct * total / 100))
    local empty=$((total - filled))
    printf "\r${BLUE}[%-${total}s]${RESET} %3d%%" "$(printf '#%.0s' $(seq 1 $filled))" "$pct"
}

# ---------------- YAY INSTALL ----------------
install_yay() {
    if ! command -v yay >/dev/null 2>&1; then
        log "Instalando yay..."
        sudo pacman -S --noconfirm --needed git base-devel >/dev/null
        tmpdir=$(mktemp -d)
        git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
        pushd "$tmpdir/yay" >/dev/null
        makepkg -si --noconfirm
        popd >/dev/null
        rm -rf "$tmpdir"
        log "yay instalado"
    else
        log "yay já presente"
    fi
}

# ---------------- PACKAGE INSTALLER (skips installed) ----------------
install_pkgs() {
    local mgr="$1"; shift
    local -a pkgs=("$@")
    local to_install=()
    for p in "${pkgs[@]}"; do
        if [[ "$mgr" == "pacman" ]]; then
            if pacman -Qi "$p" >/dev/null 2>&1; then
                log "pular (já instalado): $p"
            else
                to_install+=("$p")
            fi
        else # yay
            if pacman -Qi "$p" >/dev/null 2>&1 || yay -Qi "$p" >/dev/null 2>&1; then
                log "pular (já instalado): $p"
            else
                to_install+=("$p")
            fi
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Nenhum pacote novo para instalar.${RESET}"
        return 0
    fi

    echo -e "${CYAN}Instalando: ${to_install[*]}${RESET}"
    # run with progress simulation but real install in background
    if [[ "$mgr" == "pacman" ]]; then
        sudo pacman -S --noconfirm --needed "${to_install[@]}" &
    else
        yay -S --noconfirm --needed "${to_install[@]}" &
    fi
    pid=$!
    # show a nicer progress while install runs
    pct=0
    while kill -0 "$pid" 2>/dev/null; do
        progress_bar "$pct"
        pct=$(( (pct + 7) % 95 + 5 )) # pseudo-random smooth progress
        sleep 0.6
    done
    wait "$pid" || { echo -e "\n${RED}Erro na instalação de pacotes.${RESET}"; return 1; }
    progress_bar 100; echo
    log "Instalados: ${to_install[*]}"
    return 0
}

# ---------------- ESTIMATES ----------------
estimate_module_size_mb() {
    case "$1" in
        base) echo 150 ;;        # base utils + fonts
        dev) echo 400 ;;         # node, python, docker, build tools
        gaming) echo 1200 ;;     # wine, steam, heroic, libs
        cyber) echo 500 ;;       # nmap, wireshark, hashcat, metasploit
        multimedia) echo 800 ;;  # vlc, mpv, ffmpeg, obs, blender etc
        productivity) echo 200 ;;# firefox, libreoffice, mail
        qol) echo 60 ;;
        lock) echo 8 ;;
        gpu_intel) echo 120 ;;
        *) echo 50 ;;
    esac
}

human_size() {
    local mb=$1
    if (( mb < 1024 )); then
        echo "${mb} MB"
    else
        awk -v m="$mb" 'BEGIN{printf "%.1f GB", m/1024}'
    fi
}

# ---------------- MODULES ----------------
mod_base() {
    log "Módulo: base"
    local pkgs=(git wget curl unzip zip tar htop neofetch tree vim nano bash-completion man-db which rsync ttf-dejavu noto-fonts noto-fonts-emoji)
    install_pkgs pacman "${pkgs[@]}"
}

mod_dev() {
    log "Módulo: dev"
    local pkgs=(git base-devel nodejs npm python python-pip docker docker-compose cmake make gcc gdb valgrind strace jq ripgrep fd)
    install_pkgs pacman "${pkgs[@]}"
    # docker config
    sudo systemctl enable --now docker || true
    sudo usermod -aG docker "$USER" || true
    log "Docker configurado (usuário adicionado ao grupo docker)"
}

mod_gaming() {
    log "Módulo: gaming"
    local pkgs=(wine winetricks gamemode lib32-gamemode steam lutris discord)
    local aur_pkgs=(heroic-games-launcher-bin protonup-qt)
    install_pkgs pacman "${pkgs[@]}"
    install_pkgs yay "${aur_pkgs[@]}"
    # xbox controller
    install_pkgs yay xpadneo-dkms || true
}

mod_cyber() {
    log "Módulo: cyber"
    local pkgs=(nmap wireshark-qt aircrack-ng john hashcat tcpdump netcat socat hydra sqlmap)
    install_pkgs pacman "${pkgs[@]}"
    sudo usermod -aG wireshark "$USER" || true
    log "Usuário adicionado ao grupo wireshark"
}

mod_multimedia() {
    log "Módulo: multimedia"
    local pkgs=(vlc mpv ffmpeg gimp inkscape audacity obs-studio blender kdenlive imagemagick)
    install_pkgs pacman "${pkgs[@]}"
}

mod_productivity() {
    log "Módulo: productivity"
    local pkgs=(firefox thunderbird libreoffice-fresh keepassxc calibre zathura zathura-pdf-mupdf)
    install_pkgs pacman "${pkgs[@]}"
}

mod_qol() {
    log "Módulo: qol"
    echo -e "${CYAN}Escolha um launcher (1-Rofi, 2-Ulauncher, 3-Albert, 4-Fuzzel, 5-Pular):${RESET}"
    read -rp "> " launcher_choice
    case "$launcher_choice" in
        1) install_pkgs pacman rofi ;;
        2) install_pkgs yay ulauncher ;;
        3) install_pkgs yay albert ;;
        4) install_pkgs pacman fuzzel ;;
        5) echo "Pular launcher.";;
        *) echo "Escolha inválida. Pulando.";;
    esac
    local qol_pkgs=(fzf bat exa zoxide starship fish wl-clipboard cliphist udiskie dunst)
    install_pkgs pacman "${qol_pkgs[@]}"
}

mod_lock() {
    log "Módulo: lock"
    install_pkgs pacman hyprlock
    mkdir -p "$HOME/.config/hypr"
    cat > "$HOME/.config/hypr/hyprlock.conf" <<'EOF'
background {
    blur_passes = 3
    blur_size = 7
    noise = 0.012
}
input-field {
    placeholder_text = "Senha..."
    font_color = rgb(202,211,245)
    inner_color = rgb(24,25,38)
    outer_color = rgb(91,96,120)
}
EOF
    log "hyprlock configurado"
}

mod_gpu() {
    log "Módulo: gpu"
    if [[ "$GPU_TYPE" == "intel" ]]; then
        install_pkgs pacman "${GPU_PKGS[@]}"
    elif [[ "$GPU_TYPE" == "amd" ]]; then
        install_pkgs pacman "${GPU_PKGS[@]}"
    elif [[ "$GPU_TYPE" == "nvidia" ]]; then
        install_pkgs pacman "${GPU_PKGS[@]}"
    else
        install_pkgs pacman mesa lib32-mesa
    fi
}

# ---------------- PROFILE SAVE ----------------
save_profile() {
    local -a chosen=("$@")
    printf "%s\n" "${chosen[@]}" > "$PROFILE_FILE"
    log "Perfil salvo em $PROFILE_FILE"
}

# ---------------- CLEANUP ----------------
cleanup() {
    echo -e "${CYAN}\nLimpando cache...${RESET}"
    sudo pacman -Sc --noconfirm || true
    updatedb 2>/dev/null || true
    log "Limpeza final executada"
}

# ---------------- ARG PARSING ----------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            AUTOMODE="$2"
            shift 2
            ;;
        --module)
            MODULE_ONLY="$2"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--auto full|basic] [--module <module>]
Modules: base dev gaming cyber multimedia productivity qol lock gpu
EOF
            exit 0
            ;;
        *)
            echo "Unknown arg: $1"
            exit 1
            ;;
    esac
done

# ---------------- MENU / FLOW ----------------
main_menu() {
    logo_ascii
    detect_gpu
    echo -e "${BOLD}Detecção: GPU = ${YELLOW}$GPU_TYPE${RESET}"
    echo -e "${CYAN}Escolha uma opção:${RESET}"
    echo "1) Instalar tudo (com GPU drivers)"
    echo "2) Instalação básica (base + dev + qol)"
    echo "3) Instalação gaming (separado)"
    echo "4) Instalação personalizada"
    echo "5) Apenas cybersecurity"
    echo "6) Sair"
    read -rp "> " choice
    case "$choice" in
        1) run_profile "full";;
        2) run_profile "basic";;
        3) run_profile "gaming";;
        4) custom_menu;;
        5) run_profile "cyber";;
        6) echo "Saindo."; exit 0;;
        *) echo "Opção inválida"; main_menu;;
    esac
}

# run_profile executes presets
run_profile() {
    local preset="$1"
    local chosen=()
    case "$preset" in
        full)
            chosen=(base dev gpu gaming multimedia productivity cyber qol lock)
            ;;
        basic)
            chosen=(base dev qol gpu)
            ;;
        gaming)
            chosen=(base gpu gaming multimedia)
            ;;
        cyber)
            chosen=(base cyber)
            ;;
        *)
            echo "Preset desconhecido"; return 1;;
    esac

    echo -e "${YELLOW}Estimativas (download aproximado):${RESET}"
    for m in "${chosen[@]}"; do
        s_mb=$(estimate_module_size_mb "$m")
        echo " - $m : $(human_size "$s_mb")"
    done
    total_mb=0
    for m in "${chosen[@]}"; do total_mb=$((total_mb + $(estimate_module_size_mb "$m"))); done
    echo -e "${CYAN}Total estimado: $(human_size "$total_mb")${RESET}"
    if ! confirm "Continuar com a instalação do preset '$preset'?"; then
        echo "Cancelado."
        return 0
    fi
    save_profile "${chosen[@]}"
    for m in "${chosen[@]}"; do
        case "$m" in
            base) mod_base;;
            dev) mod_dev;;
            gpu) mod_gpu;;
            gaming) mod_gaming;;
            multimedia) mod_multimedia;;
            productivity) mod_productivity;;
            cyber) mod_cyber;;
            qol) mod_qol;;
            lock) mod_lock;;
        esac
    done
}

custom_menu() {
    echo -e "${BOLD}Instalação personalizada${RESET}"
    local chosen=()
    if confirm "Instalar Base?"; then chosen+=("base"); fi
    if confirm "Instalar Desenvolvimento?"; then chosen+=("dev"); fi
    if confirm "Instalar GPU drivers?"; then chosen+=("gpu"); fi
    if confirm "Instalar Gaming?"; then chosen+=("gaming"); fi
    if confirm "Instalar Multimídia?"; then chosen+=("multimedia"); fi
    if confirm "Instalar Produtividade?"; then chosen+=("productivity"); fi
    if confirm "Instalar Cybersecurity?"; then chosen+=("cyber"); fi
    if confirm "Instalar QoL + Launcher?"; then chosen+=("qol"); fi
    if confirm "Instalar Lockscreen macOS?"; then chosen+=("lock"); fi

    if [[ ${#chosen[@]} -eq 0 ]]; then echo "Nada selecionado. Saindo."; return; fi
    echo -e "${YELLOW}Estimativa total:${RESET}"
    total_mb=0
    for m in "${chosen[@]}"; do
        s_mb=$(estimate_module_size_mb "$m"); total_mb=$((total_mb + s_mb))
        echo " - $m : $(human_size "$s_mb")"
    done
    echo -e "${CYAN}Total estimado: $(human_size "$total_mb")${RESET}"
    if ! confirm "Continuar?"; then echo "Cancelado."; return; fi
    save_profile "${chosen[@]}"
    for m in "${chosen[@]}"; do
        case "$m" in
            base) mod_base;;
            dev) mod_dev;;
            gpu) mod_gpu;;
            gaming) mod_gaming;;
            multimedia) mod_multimedia;;
            productivity) mod_productivity;;
            cyber) mod_cyber;;
            qol) mod_qol;;
            lock) mod_lock;;
        esac
    done
}

# ---------------- ENTRY ----------------
main() {
    log "=== INÍCIO arch-setup v2.5 ==="
    check_root
    check_internet
    install_yay

    # If user passed --module
    if [[ -n "$MODULE_ONLY" ]]; then
        detect_gpu
        case "$MODULE_ONLY" in
            base) mod_base;;
            dev) mod_dev;;
            gpu) detect_gpu; mod_gpu;;
            gaming) mod_gaming;;
            cyber) mod_cyber;;
            multimedia) mod_multimedia;;
            productivity) mod_productivity;;
            qol) mod_qol;;
            lock) mod_lock;;
            *) echo "Módulo desconhecido: $MODULE_ONLY"; exit 1;;
        esac
        cleanup; log "=== FIM ==="; final_message; exit 0
    fi

    # If --auto passed
    if [[ -n "$AUTOMODE" ]]; then
        case "$AUTOMODE" in
            full) run_profile full; cleanup; final_message; exit 0 ;;
            basic) run_profile basic; cleanup; final_message; exit 0 ;;
            *) echo "Preset auto inválido: $AUTOMODE"; exit 1 ;;
        esac
    fi

    # Interactive
    main_menu
    cleanup
    final_message
}

final_message() {
    echo -e "\n${GREEN}${BOLD}Instalação concluída.${RESET}"
    echo -e "${CYAN}Log salvo em:${RESET} $LOG_FILE"
    if [[ -f "$PROFILE_FILE" ]]; then
        echo -e "${CYAN}Perfil salvo em:${RESET} $PROFILE_FILE"
    fi
    echo -e "${YELLOW}Recomendações:${RESET}"
    echo "- Reinicie o sistema."
    echo "- Se instalou Docker, faça logout/login para aplicar grupo 'docker'."
    echo "- Teste GPU: 'glxinfo | grep OpenGL' (instale mesa-utils se necessário)."
    log "=== TERMINADO COM SUCESSO ==="
}

# Run
main "$@"
