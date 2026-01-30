#!/bin/bash
set -euo pipefail

# Handle piped execution (curl | bash) vs file execution
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
    PIPED_INSTALL=0
else
    # Running from pipe - will need to download the script for install
    SCRIPT_DIR=""
    SCRIPT_NAME="claude-kimi.sh"
    PIPED_INSTALL=1
fi
PROXY_PORT=4111
SCRIPT_URL="https://raw.githubusercontent.com/sjalq/claude-fireworks/main/claude-kimi.sh"

# ============================================
# DIRECTORY SETUP (XDG compliant)
# ============================================

# Config directory: where .env lives
if [[ "$OSTYPE" == "darwin"* ]]; then
    CONFIG_DIR="${HOME}/Library/Application Support/claude-fireworks"
else
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-fireworks"
fi

# Data directory: where pid, lock, log files live
if [[ "$OSTYPE" == "darwin"* ]]; then
    DATA_DIR="${HOME}/Library/Application Support/claude-fireworks"
else
    DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-fireworks"
fi

# Runtime files
LOCK_FILE="$DATA_DIR/.proxy.lock"
PROXY_PID_FILE="$DATA_DIR/.proxy.pid"
PROXY_LOG_FILE="$DATA_DIR/proxy.log"

# Initialize variables that cleanup might reference
WE_STARTED_PROXY=0
PROXY_PID=""

# ============================================
# CLEANUP
# ============================================

cleanup() {
    local exit_code=$?

    rm -f "$LOCK_FILE" 2>/dev/null || true

    if [[ "$WE_STARTED_PROXY" -eq 1 && -n "$PROXY_PID" ]]; then
        if kill -0 "$PROXY_PID" 2>/dev/null; then
            echo "Stopping LiteLLM proxy (PID: $PROXY_PID)..."
            kill "$PROXY_PID" 2>/dev/null || true
            rm -f "$PROXY_PID_FILE" 2>/dev/null || true
        fi
    fi

    exit $exit_code
}

# ============================================
# LOAD API KEY (check multiple locations)
# ============================================

# Priority: CLI arg > env var > XDG config > script dir .env
FIREWORKS_API_KEY="${FIREWORKS_API_KEY:-}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"

load_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 1

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Remove quotes from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        # Trim whitespace
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ "$key" == "FIREWORKS_API_KEY" && -z "$FIREWORKS_API_KEY" ]]; then
            FIREWORKS_API_KEY="$value"
        elif [[ "$key" == "LITELLM_MASTER_KEY" && -z "$LITELLM_MASTER_KEY" ]]; then
            LITELLM_MASTER_KEY="$value"
        fi
    done < "$env_file"
}

# Try XDG config location first, then script directory as fallback (if not piped)
load_env_file "$CONFIG_DIR/.env" || { [[ -n "$SCRIPT_DIR" ]] && load_env_file "$SCRIPT_DIR/.env"; } || true

# Default master key if still not set
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-fireworks-proxy}"

# ============================================
# INSTALL MODE
# ============================================

show_install_help() {
    cat << 'EOF'

╔══════════════════════════════════════════════════════════════════╗
║           Claude + Fireworks AI - Installation Guide             ║
╚══════════════════════════════════════════════════════════════════╝

This script lets you run Claude Code powered by Fireworks AI models
(kimi-k2.5, kimi-k2-instruct) instead of Anthropic's API.

INSTALLATION:
  ./claude-kimi.sh --install         Install to system PATH
  ./claude-kimi.sh --install --local Install to current directory only
  ./claude-kimi.sh --uninstall       Remove from system PATH

USAGE:
  claude-kimi --fireworks-key <key> [claude-args...]
  claude-kimi /path/to/project
  claude-kimi -p "explain this code" file.ts

API KEY SOURCES (in priority order):
  1. --fireworks-key <key>           Command line argument
  2. FIREWORKS_API_KEY env var       Environment variable
  3. Config file (see below)         Auto-created during install

CONFIG LOCATIONS:
  Linux:  ~/.config/claude-fireworks/.env
  macOS:  ~/Library/Application Support/claude-fireworks/.env

GETTING A FIREWORKS API KEY:
  1. Go to: https://fireworks.ai
  2. Click "Sign Up" (or "Log In" if you have an account)
  3. After signing in, go to: https://fireworks.ai/account/api-keys
  4. Click "Create API Key"
  5. Copy the key (starts with "fw_")

SUPPORTED MODELS:
  - kimi-k2.5 (default) - Best for complex reasoning
  - kimi-k2-instruct    - Faster, good for simple tasks

EOF
}

detect_install_dir() {
    local install_dir=""

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: prefer ~/bin, fallback to /usr/local/bin
        if [[ -d "$HOME/bin" ]] || mkdir -p "$HOME/bin" 2>/dev/null; then
            install_dir="$HOME/bin"
        elif [[ -w "/usr/local/bin" ]]; then
            install_dir="/usr/local/bin"
        else
            install_dir="/usr/local/bin"
        fi
    else
        # Linux: use XDG_BIN_HOME, ~/.local/bin, or fallback
        if [[ -n "${XDG_BIN_HOME:-}" ]]; then
            install_dir="$XDG_BIN_HOME"
        elif [[ -d "$HOME/.local/bin" ]] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
            install_dir="$HOME/.local/bin"
        elif [[ -w "/usr/local/bin" ]]; then
            install_dir="/usr/local/bin"
        else
            install_dir="$HOME/.local/bin"
        fi
    fi

    echo "$install_dir"
}

add_to_path_if_needed() {
    local install_dir="$1"
    local shell_rc=""
    local shell_name="${SHELL##*/}"

    # Check if already in PATH
    if [[ ":$PATH:" == *":$install_dir:"* ]]; then
        return 0
    fi

    # Detect shell and rc file
    case "$shell_name" in
        bash) shell_rc="$HOME/.bashrc" ;;
        zsh)  shell_rc="$HOME/.zshrc" ;;
        fish) shell_rc="$HOME/.config/fish/config.fish" ;;
        *)    shell_rc="$HOME/.profile" ;;
    esac

    # Check if already added to rc file (avoid duplicates)
    if [[ -f "$shell_rc" ]] && grep -q "claude-kimi installer" "$shell_rc" 2>/dev/null; then
        echo "✓ PATH already configured in $shell_rc"
        return 0
    fi

    # Add to shell rc file with correct syntax
    if [[ -f "$shell_rc" ]] || [[ "$shell_name" == "fish" ]]; then
        echo "" >> "$shell_rc"
        echo "# Added by claude-kimi installer" >> "$shell_rc"

        if [[ "$shell_name" == "fish" ]]; then
            echo "set -gx PATH \"$install_dir\" \$PATH" >> "$shell_rc"
        else
            echo "export PATH=\"$install_dir:\$PATH\"" >> "$shell_rc"
        fi

        echo ""
        echo "✓ Added $install_dir to PATH in $shell_rc"
        echo "  Run 'source $shell_rc' or restart your terminal to apply"
    fi
}

run_install() {
    local local_install=0
    local install_dir=""

    # Check for --local flag
    for arg in "$@"; do
        if [[ "$arg" == "--local" ]]; then
            local_install=1
        fi
    done

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           Claude + Fireworks AI - Installation                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Handle piped installation (curl | bash)
    if [[ "$PIPED_INSTALL" -eq 1 ]]; then
        echo "→ Detected piped installation, downloading script..."
        local temp_script="/tmp/claude-kimi-$$.sh"
        if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then
            echo "✗ Failed to download script from $SCRIPT_URL"
            exit 1
        fi
        chmod +x "$temp_script"
        # Re-exec the downloaded script with same args
        exec "$temp_script" "$@"
    fi

    if [[ "$local_install" -eq 1 ]]; then
        install_dir="$SCRIPT_DIR"
        echo "→ Local install mode: keeping script in current directory"
    else
        install_dir=$(detect_install_dir)
        echo "→ Detected install directory: $install_dir"

        # Create directory if needed
        if [[ ! -d "$install_dir" ]]; then
            echo "→ Creating directory: $install_dir"
            mkdir -p "$install_dir" || {
                echo "✗ Failed to create $install_dir"
                echo "  Try: ./claude-kimi.sh --install --local"
                exit 1
            }
        fi

        # Check if we can write to it
        if [[ ! -w "$install_dir" ]]; then
            echo "✗ Cannot write to $install_dir"
            echo "  Try with sudo: sudo ./claude-kimi.sh --install"
            echo "  Or use local install: ./claude-kimi.sh --install --local"
            exit 1
        fi
    fi

    # Install the script
    local target_path="$install_dir/claude-kimi"

    if [[ "$local_install" -eq 1 ]]; then
        chmod +x "$SCRIPT_DIR/$SCRIPT_NAME"
        target_path="$SCRIPT_DIR/$SCRIPT_NAME"
    elif [[ "$SCRIPT_DIR/$SCRIPT_NAME" != "$target_path" ]]; then
        echo "→ Installing script to $target_path"
        cp "$SCRIPT_DIR/$SCRIPT_NAME" "$target_path"
        chmod +x "$target_path"
    else
        chmod +x "$target_path"
    fi

    echo "✓ Script installed: $target_path"

    # Create config and data directories
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$DATA_DIR"
    echo "✓ Config directory: $CONFIG_DIR"
    echo "✓ Data directory: $DATA_DIR"

    # Add to PATH if needed (only for system install)
    if [[ "$local_install" -eq 0 ]]; then
        add_to_path_if_needed "$install_dir"
    fi

    # Check for claude CLI
    echo ""
    echo "Checking dependencies..."
    if ! command -v claude &> /dev/null; then
        echo "⚠ Claude CLI not found. Install with:"
        echo "  npm install -g @anthropic-ai/claude-code"
    else
        echo "✓ Claude CLI found"
    fi

    # Check for Python
    if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
        echo "⚠ Python not found. Please install Python 3.8+"
    else
        echo "✓ Python found"
    fi

    # Check for LiteLLM
    if command -v litellm &> /dev/null || python3 -c "import litellm" 2>/dev/null; then
        echo "✓ LiteLLM found"
    else
        echo "⚠ LiteLLM not found. Will be installed on first run."
    fi

    # API Key setup
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                    API Key Setup"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "To use Claude with Fireworks AI, you need a Fireworks API key."
    echo ""
    echo "Steps to get your key:"
    echo "  1. Go to: https://fireworks.ai"
    echo "  2. Click 'Sign Up' (or 'Log In' if you have an account)"
    echo "  3. After signing in, go to: https://fireworks.ai/account/api-keys"
    echo "  4. Click 'Create API Key'"
    echo "  5. Copy the key (starts with 'fw_')"
    echo ""

    local env_file="$CONFIG_DIR/.env"

    if [[ -f "$env_file" ]]; then
        echo "✓ Existing config found at: $env_file"
        echo -n "Do you want to update your API key? [y/N] "
        local response=""
        if [[ -t 0 ]]; then
            read -r response
        elif [[ -e /dev/tty ]]; then
            read -r response < /dev/tty
        fi
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo ""
            echo "═══════════════════════════════════════════════════════════════════"
            echo "                    Installation Complete!"
            echo "═══════════════════════════════════════════════════════════════════"
            echo ""
            echo "Usage: claude-kimi [claude-args...]"
            echo ""
            echo "Your API key is stored in: $env_file"
            echo ""
            exit 0
        fi
    fi

    echo "Please enter your Fireworks API key (starts with 'fw_'):"
    local api_key=""

    # Read from /dev/tty to support piped installs (curl | bash)
    if [[ -t 0 ]]; then
        # Interactive terminal - read silently
        read -r -s api_key
    elif [[ -e /dev/tty ]]; then
        # Piped input but terminal available - read from tty
        read -r -s api_key < /dev/tty
    else
        # No terminal available - skip
        api_key=""
    fi
    echo ""

    if [[ -z "${api_key:-}" ]]; then
        echo "✗ No API key provided. You can add it later to: $env_file"
        echo "  Edit the file and add: FIREWORKS_API_KEY=fw_your_key_here"
    elif [[ ! "$api_key" =~ ^fw_[a-zA-Z0-9_]+$ ]]; then
        echo "⚠ Warning: Key doesn't look like a Fireworks API key (should start with 'fw_')"
        echo "  Saving anyway. You can edit $env_file to fix it."
        echo "FIREWORKS_API_KEY=$api_key" > "$env_file"
        chmod 600 "$env_file"
    else
        echo "FIREWORKS_API_KEY=$api_key" > "$env_file"
        chmod 600 "$env_file"
        echo "✓ API key saved to: $env_file"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                    Installation Complete!"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    if [[ "$local_install" -eq 1 ]]; then
        echo "Run with: $target_path"
    else
        echo "Run with: claude-kimi"
        echo ""
        if [[ ":$PATH:" != *":$install_dir:"* ]]; then
            echo "NOTE: $install_dir is not in your PATH yet."
            echo "      Run 'source' on your shell config file or restart terminal."
        fi
    fi

    echo ""
    echo "Examples:"
    echo "  claude-kimi /path/to/project"
    echo "  claude-kimi --model kimi-k2-instruct"
    echo "  claude-kimi -p 'explain this code' file.ts"
    echo ""
    echo "Config file: $env_file"
    echo ""

    exit 0
}

run_uninstall() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           Claude + Fireworks AI - Uninstall                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    local install_dir=$(detect_install_dir)
    local target_path="$install_dir/claude-kimi"

    # Stop proxy if running (check data directory)
    if [[ -f "$PROXY_PID_FILE" ]]; then
        local pid
        pid=$(cat "$PROXY_PID_FILE" 2>/dev/null) || true
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "→ Stopping LiteLLM proxy..."
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$PROXY_PID_FILE" 2>/dev/null || true
    fi

    # Remove installed script
    if [[ -f "$target_path" ]]; then
        echo "→ Removing $target_path"
        rm -f "$target_path"
        echo "✓ Script removed"
    else
        echo "→ Script not found at $target_path"
    fi

    # Ask about config
    if [[ -d "$CONFIG_DIR" ]]; then
        echo -n "Remove config directory ($CONFIG_DIR)? [y/N] "
        local response=""
        if [[ -t 0 ]]; then read -r response; elif [[ -e /dev/tty ]]; then read -r response < /dev/tty; fi
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$CONFIG_DIR"
            echo "✓ Config removed"
        else
            echo "✓ Config kept at: $CONFIG_DIR"
        fi
    fi

    # Ask about data directory
    if [[ -d "$DATA_DIR" && "$DATA_DIR" != "$CONFIG_DIR" ]]; then
        echo -n "Remove data directory ($DATA_DIR)? [y/N] "
        local response=""
        if [[ -t 0 ]]; then read -r response; elif [[ -e /dev/tty ]]; then read -r response < /dev/tty; fi
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$DATA_DIR"
            echo "✓ Data directory removed"
        else
            echo "✓ Data directory kept"
        fi
    fi

    echo ""
    echo "✓ Uninstall complete"
    echo ""
    echo "Note: LiteLLM was installed via pip and was not removed."
    echo "      To remove it: pip uninstall litellm"
    echo ""
    exit 0
}

# ============================================
# MAIN - Parse global flags first
# ============================================

# Handle install/uninstall/help before normal flow
for arg in "$@"; do
    case "$arg" in
        --install)
            run_install "$@"
            ;;
        --uninstall)
            run_uninstall
            ;;
        --help|-h)
            show_install_help
            exit 0
            ;;
    esac
done

# Setup cleanup trap for normal operation
trap cleanup EXIT INT TERM

# Parse remaining arguments
CLAUDE_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fireworks-key)
            FIREWORKS_API_KEY="$2"
            shift 2
            ;;
        --fireworks-key=*)
            FIREWORKS_API_KEY="${1#*=}"
            shift
            ;;
        *)
            CLAUDE_ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate we have a Fireworks API key
if [[ -z "$FIREWORKS_API_KEY" ]]; then
    echo "Error: Fireworks API key required. Use one of:" >&2
    echo "  1. --fireworks-key <key>" >&2
    echo "  2. FIREWORKS_API_KEY environment variable" >&2
    echo "  3. Add FIREWORKS_API_KEY to $CONFIG_DIR/.env" >&2
    echo "" >&2
    echo "Run with --help for more information" >&2
    exit 1
fi

# Check for claude CLI
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' CLI not found. Install with: npm install -g @anthropic-ai/claude-code" >&2
    exit 1
fi

# Check for Python (needed for LiteLLM)
PYTHON_CMD=""
if command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
elif command -v python &> /dev/null; then
    PYTHON_CMD="python"
else
    echo "Error: Python is required but not installed." >&2
    exit 1
fi

# Check for pip
PIP_CMD=""
if command -v pip3 &> /dev/null; then
    PIP_CMD="pip3"
elif command -v pip &> /dev/null; then
    PIP_CMD="pip"
else
    echo "Error: pip is required but not installed." >&2
    exit 1
fi

# Function to check if LiteLLM is installed
check_litellm() {
    command -v litellm &> /dev/null || \
    $PYTHON_CMD -c "import litellm" 2>/dev/null
}

# Install LiteLLM if not available
if ! check_litellm; then
    echo "LiteLLM not found. Installing..."
    if ! $PIP_CMD install --user litellm; then
        echo "Warning: --user install failed, trying without --user..."
        if ! $PIP_CMD install litellm; then
            echo "Error: Failed to install LiteLLM" >&2
            exit 1
        fi
    fi
fi

# Find litellm command
LITELLM_CMD=""
if command -v litellm &> /dev/null; then
    LITELLM_CMD="litellm"
else
    # Try to find in user bin
    USER_BIN="${HOME}/.local/bin/litellm"
    if [[ -x "$USER_BIN" ]]; then
        LITELLM_CMD="$USER_BIN"
    else
        # Use python module
        LITELLM_CMD="$PYTHON_CMD -m litellm"
    fi
fi

# Ensure data directory exists
mkdir -p "$DATA_DIR"

# Create param filter callback (required to drop Anthropic-specific params)
CALLBACK_FILE="$DATA_DIR/param_filter.py"
if [[ ! -f "$CALLBACK_FILE" ]]; then
    cat > "$CALLBACK_FILE" << 'PYEOF'
from litellm.integrations.custom_logger import CustomLogger

class ParamFilterCallback(CustomLogger):
    """Filters out Anthropic-specific params that Fireworks doesn't support."""
    PARAMS_TO_DROP = ["context_management", "reasoning_effort", "betas", "anthropic_beta", "anthropic-beta"]

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        for param in self.PARAMS_TO_DROP:
            data.pop(param, None)
        return data

proxy_handler_instance = ParamFilterCallback()
PYEOF
fi

# Create config file in data directory
CONFIG_FILE="$DATA_DIR/config.yaml"
cat > "$CONFIG_FILE" << 'EOF'
model_list:
  # Primary model - kimi-k2.5
  - model_name: kimi-k2.5
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2p5
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

  # kimi-k2-instruct (faster, lighter)
  - model_name: kimi-k2-instruct
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2-instruct-0905
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

  # Claude model aliases - route to kimi-k2.5 (main model)
  - model_name: claude-sonnet-4-20250514
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2p5
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

  - model_name: claude-opus-4-20250514
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2p5
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

  - model_name: claude-opus-4-5-20251101
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2p5
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

  # Haiku aliases - route to kimi-k2-instruct (lighter model)
  - model_name: claude-haiku-4-5-20251001
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2-instruct-0905
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

  - model_name: claude-3-5-haiku-20241022
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2-instruct-0905
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

  - model_name: claude-3-5-sonnet-20241022
    litellm_params:
      model: fireworks_ai/accounts/fireworks/models/kimi-k2p5
      api_key: os.environ/FIREWORKS_API_KEY
      drop_params: true

litellm_settings:
  drop_params: true
  callbacks: param_filter.proxy_handler_instance

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF

# Check if proxy responds to health endpoint
proxy_responds() {
    curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        "http://localhost:$PROXY_PORT/health" > /dev/null 2>&1
}

# Check if proxy can actually make a completion (deeper health check)
proxy_healthy() {
    # First check if it responds at all
    if ! proxy_responds; then
        return 1
    fi

    # Then verify it can route a simple request (with short timeout)
    local response
    response=$(curl -s --max-time 10 -X POST "http://localhost:$PROXY_PORT/v1/messages" \
        -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -d '{"model": "kimi-k2.5", "max_tokens": 5, "messages": [{"role": "user", "content": "hi"}]}' 2>&1)

    # Check if response contains expected fields (not an error)
    # Handle both with and without spaces in JSON
    if echo "$response" | grep -qE '"type":\s*"message"'; then
        return 0
    fi

    return 1
}

# Kill existing proxy if running
kill_proxy() {
    # Kill by PID file
    if [[ -f "$PROXY_PID_FILE" ]]; then
        local pid
        pid=$(cat "$PROXY_PID_FILE" 2>/dev/null) || true
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            # Force kill if still running
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PROXY_PID_FILE"
    fi

    # Also kill any orphaned litellm on our port
    pkill -f "litellm.*--port.*$PROXY_PORT" 2>/dev/null || true
    sleep 1
}

# Acquire lock (with fallback for systems without flock)
acquire_lock() {
    if command -v flock &> /dev/null; then
        exec 200>"$LOCK_FILE"
        if ! flock -n 200 2>/dev/null; then
            echo "Another instance is starting the proxy, waiting..."
            flock 200 2>/dev/null || true
        fi
    else
        # Fallback: simple lock file with PID
        local max_wait=30
        local waited=0
        while [[ -f "$LOCK_FILE" ]] && [[ $waited -lt $max_wait ]]; do
            # Check if the process holding the lock is still alive
            local lock_pid
            lock_pid=$(cat "$LOCK_FILE" 2>/dev/null) || true
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                rm -f "$LOCK_FILE"
                break
            fi
            echo "Waiting for another instance..."
            sleep 1
            ((waited++))
        done
        echo $$ > "$LOCK_FILE"
    fi
}

release_lock() {
    if command -v flock &> /dev/null; then
        flock -u 200 2>/dev/null || true
    fi
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# Check proxy state and decide whether to start/restart
NEED_START=0

if proxy_responds; then
    echo -n "Checking existing proxy health..."
    if proxy_healthy; then
        echo " healthy! (reusing)"
    else
        echo " unhealthy, restarting..."
        kill_proxy
        NEED_START=1
    fi
else
    NEED_START=1
fi

if [[ "$NEED_START" -eq 1 ]]; then
    acquire_lock

    # Double-check after acquiring lock
    if proxy_responds && proxy_healthy; then
        echo "LiteLLM proxy already running on port $PROXY_PORT (reusing existing)"
    else
        # Kill any unhealthy/stale proxy
        kill_proxy

        echo "Starting LiteLLM proxy on port $PROXY_PORT..."

        # Start proxy (from DATA_DIR so it can find the callback)
        cd "$DATA_DIR"
        FIREWORKS_API_KEY="$FIREWORKS_API_KEY" \
        LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
        nohup $LITELLM_CMD --config "$CONFIG_FILE" --port "$PROXY_PORT" > "$PROXY_LOG_FILE" 2>&1 &
        cd - > /dev/null

        PROXY_PID=$!
        WE_STARTED_PROXY=1
        echo "$PROXY_PID" > "$PROXY_PID_FILE"

        # Wait for proxy to be ready
        echo -n "Waiting for proxy"
        for i in $(seq 1 30); do
            if proxy_responds; then
                echo " ready!"
                break
            fi
            if ! kill -0 "$PROXY_PID" 2>/dev/null; then
                echo ""
                echo "Error: Proxy failed to start. Check $PROXY_LOG_FILE" >&2
                tail -20 "$PROXY_LOG_FILE" 2>/dev/null || true
                exit 1
            fi
            echo -n "."
            sleep 1
        done

        if ! proxy_responds; then
            echo ""
            echo "Error: Proxy failed to start within 30 seconds." >&2
            echo "Check log: $PROXY_LOG_FILE" >&2
            exit 1
        fi
    fi

    release_lock
fi

# Detect model from claude args or default to kimi-k2.5
MODEL="kimi-k2.5"
i=0
while [[ $i -lt ${#CLAUDE_ARGS[@]} ]]; do
    arg="${CLAUDE_ARGS[$i]}"
    if [[ "$arg" == "--model" ]]; then
        next=$((i + 1))
        if [[ $next -lt ${#CLAUDE_ARGS[@]} ]]; then
            MODEL="${CLAUDE_ARGS[$next]}"
            break
        fi
    fi
    i=$((i + 1))
done

# Launch Claude with Fireworks routing
ANTHROPIC_BASE_URL="http://localhost:$PROXY_PORT" \
ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY" \
ANTHROPIC_API_KEY="" \
ANTHROPIC_MODEL="$MODEL" \
claude "${CLAUDE_ARGS[@]}"
