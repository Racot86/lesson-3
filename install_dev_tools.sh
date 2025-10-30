#!/usr/bin/env bash
# install_dev_tools.sh
# Automated installation of Docker, Docker Compose, Python (>=3.9) and Django (pip) for Ubuntu/Debian.
# Idempotent: checks tool presence before installing.

set -euo pipefail

OS=$(uname -s)

# --- Helpers ---------------------------------------------------------------
SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Root or sudo privileges are required. Either run as root or install sudo." >&2
    exit 1
  fi
fi

log() { printf "\n\033[1;36m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*"; }

need_apt_update=0
apt_update_once() {
  if [[ $need_apt_update -eq 1 ]]; then return; fi
  log "Refreshing package index (apt update)…"
  $SUDO apt-get update -y
  need_apt_update=1
}

install_pkgs() {
  apt_update_once
  log "Installing packages: $*"
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@"
}

# --- Docker ----------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
  else
    if [[ "$OS" == "Darwin" ]]; then
      warn "On macOS, install Docker Desktop from https://www.docker.com/products/docker-desktop/ (recommended)."
      if ! command -v brew >/dev/null 2>&1; then
        warn "Homebrew not found. Install from https://brew.sh if you prefer CLI-managed tools."
      fi
    else
      log "Installing Docker Engine (via distro repository)…"
      install_pkgs ca-certificates curl gnupg lsb-release
      if apt-cache policy docker.io | grep -q Installed; then
        install_pkgs docker.io
      else
        install_pkgs docker.io || true
      fi
      if ! command -v docker >/dev/null 2>&1; then
        err "Failed to install docker.io from repository. Consider the official Docker repo: https://docs.docker.com/engine/install/"
        exit 1
      fi
      log "Docker installed: $(docker --version)"
    fi
  fi

  # Enable/start service (Linux only)
  if [[ "$OS" != "Darwin" ]] && command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker || true
  fi

  # Add current user to docker group (Linux only)
  if [[ "$OS" != "Darwin" ]]; then
    if getent group docker >/dev/null 2>&1; then :; else $SUDO groupadd docker || true; fi
    if id -nG "${SUDO_USER:-$USER}" | tr ' ' '\n' | grep -q '^docker$'; then
      log "User is already in the docker group"
    else
      log "Adding ${SUDO_USER:-$USER} to the docker group"
      $SUDO usermod -aG docker "${SUDO_USER:-$USER}" || true
      warn "Log out/in or run 'newgrp docker' for group changes to take effect."
    fi
  else
    log "Skipping docker group configuration on macOS (not needed with Docker Desktop)."
  fi
}

# --- Docker Compose --------------------------------------------------------
install_docker_compose() {
  # Prefer Docker Compose v2 as a plugin: 'docker compose'
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose v2 present: $(docker compose version)"
  else
    log "Installing docker-compose-plugin (Compose v2)…"
    install_pkgs docker-compose-plugin || true
    if docker compose version >/dev/null 2>&1; then
      log "Docker Compose v2 installed: $(docker compose version)"
    else
      warn "Could not install docker-compose-plugin. Trying classic docker-compose (v1)."
      install_pkgs docker-compose || true
      if command -v docker-compose >/dev/null 2>&1; then
        log "Docker Compose (v1) installed: $(docker-compose --version)"
      else
        err "Failed to install Docker Compose. Check your repositories or install manually."
        exit 1
      fi
    fi
  fi
}

# --- Python (>=3.9) and pip -----------------------------------------------
ensure_python() {
  local want_minor=9
  if command -v python3 >/dev/null 2>&1; then
    local ver
    ver=$(python3 -c 'import sys; print("%d.%d"%sys.version_info[:2])')
    log "python3 found: ${ver}"
    local major=${ver%%.*}
    local minor=${ver#*.}
    if (( major > 3 || (major == 3 && minor >= want_minor) )); then
      log "Python version meets requirement (>=3.9)."
    else
      warn "Python ${ver} < 3.9. Attempting to install a newer version…"
      install_pkgs python3.10 python3.10-venv python3.10-distutils || install_pkgs python3.11 python3.11-venv python3.11-distutils || true
      if command -v python3 >/dev/null 2>&1; then
        ver=$(python3 -c 'import sys; print("%d.%d"%sys.version_info[:2])')
        log "Current Python version: ${ver}"
        major=${ver%%.*}; minor=${ver#*.}
        if ! (( major > 3 || (major == 3 && minor >= want_minor) )); then
          err "Python is still <3.9. Update your distro or add a repo with a newer Python."
          exit 1
        fi
      fi
    fi
  else
    log "Installing python3 and related packages…"
    install_pkgs python3 python3-venv python3-pip python3-distutils
    if ! command -v python3 >/dev/null 2>&1; then
      err "Failed to install python3."
      exit 1
    fi
    local ver
    ver=$(python3 -c 'import sys; print("%d.%d"%sys.version_info[:2])')
    log "python3 installed: ${ver}"
    local major=${ver%%.*}; local minor=${ver#*.}
    if ! (( major > 3 || (major == 3 && minor >= want_minor) )); then
      warn "Python <3.9. Attempting to install a newer version…"
      install_pkgs python3.10 python3.10-venv python3.10-distutils || install_pkgs python3.11 python3.11-venv python3.11-distutils || true
    fi
  fi

  # Ensure pip is available
  if command -v pip3 >/dev/null 2>&1; then
    log "pip3 found: $(pip3 --version)"
  else
    log "Installing pip3…"
    install_pkgs python3-pip
  fi

  # Upgrade pip for the current user
  python3 -m pip install --user --upgrade pip >/dev/null 2>&1 || true
}

# --- Django (pip) ----------------------------------------------------------
install_django() {
  # First, detect if a conflicting third-party 'importlib' hides stdlib.
  if python3 -c "import sys; import importlib; import types; print(hasattr(importlib, 'util'))" 2>/dev/null | grep -q '^True$'; then
    : # stdlib importlib looks OK
  else
    warn "Detected an 'importlib' without 'util' — you may have a third-party package named 'importlib' shadowing stdlib. Consider: 'pip3 uninstall -y importlib' or remove ./importlib.py from your project. Proceeding with an alternative check."
  fi

  # Portable presence check: try running django module; exit code 0 if present
  if python3 -m django --version >/dev/null 2>&1; then
    local djv
    djv=$(python3 -m django --version)
    log "Django already installed (user/site): v${djv}"
  else
    log "Installing Django via pip into ~/.local…"
    # If custom pip index is set and causing failures, force PyPI as a fallback
    if ! python3 -m pip install --user --no-input django 2>/dev/null; then
      warn "Standard installation failed — trying with explicit PyPI index and no cache."
      python3 -m pip install --user --no-cache-dir -i https://pypi.org/simple --trusted-host pypi.org --trusted-host files.pythonhosted.org django
    fi
    log "Django installed: $(python3 -m django --version)"
  fi

  # Add ~/.local/bin to PATH if needed
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    warn "Adding ~/.local/bin to PATH in ~/.bashrc"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    warn "Restart your terminal or run: source ~/.bashrc"
  fi
}

# --- Run all ---------------------------------------------------------------
main() {
  log "Starting DevOps tools installation (Docker, Compose, Python, Django)…"
  install_docker
  install_docker_compose
  ensure_python
  install_django
  log "Done!"
  echo
  echo "Version check:"
  echo "  Docker:           $(command -v docker >/dev/null 2>&1 && docker --version || echo 'not found')"
  echo "  Docker Compose:   $( (docker compose version 2>/dev/null || docker-compose --version 2>/dev/null) || echo 'not found')"
  echo "  Python3:          $(python3 --version 2>/dev/null || echo 'not found')"
  echo "  pip3:             $(pip3 --version 2>/dev/null || echo 'not found')"
  echo "  Django:           $(python3 -m django --version 2>/dev/null || echo 'not found')"
  echo
  warn "If you were just added to the docker group — log out/in or run 'newgrp docker'."
}

main "$@"
