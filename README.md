# Claude Code with Fireworks AI

Run [Claude Code](https://github.com/anthropics/claude-code) powered by Fireworks AI models (Kimi K2.5, Kimi K2 Instruct) instead of Anthropic's API.

## Quick Start

```bash
# Download and install
curl -fsSL https://raw.githubusercontent.com/sjalq/claude-fireworks/main/claude-kimi.sh -o claude-kimi.sh
chmod +x claude-kimi.sh
./claude-kimi.sh --install

# Run
claude-kimi /path/to/project
```

## Requirements

- [Claude Code CLI](https://github.com/anthropics/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- Python 3.8+
- [Fireworks API key](https://fireworks.ai/account/api-keys)

## How It Works

The script runs a local [LiteLLM](https://github.com/BerriAI/litellm) proxy that translates Anthropic API calls to Fireworks AI. Claude Code connects to this proxy instead of Anthropic's servers.

```
Claude Code  -->  LiteLLM Proxy (localhost:4111)  -->  Fireworks AI
```

## Installation Options

```bash
# System install (adds to PATH)
./claude-kimi.sh --install

# Local install (current directory only)
./claude-kimi.sh --install --local

# Uninstall
./claude-kimi.sh --uninstall
```

## Usage

```bash
# Basic usage
claude-kimi /path/to/project

# Pass a prompt directly
claude-kimi -p "explain this code" file.ts

# Use the lighter/faster model
claude-kimi --model kimi-k2-instruct

# Provide API key via command line
claude-kimi --fireworks-key fw_xxx /path/to/project
```

## API Key Configuration

The script looks for your Fireworks API key in this order:

1. `--fireworks-key <key>` command line argument
2. `FIREWORKS_API_KEY` environment variable
3. Config file:
   - Linux: `~/.config/claude-fireworks/.env`
   - macOS: `~/Library/Application Support/claude-fireworks/.env`

## Supported Models

| Model | Description | Use Case |
|-------|-------------|----------|
| `kimi-k2.5` | Full model (default) | Complex reasoning, coding |
| `kimi-k2-instruct` | Lighter/faster | Simple tasks, quick responses |

## Troubleshooting

**Proxy won't start:**
```bash
# Check the log
cat ~/.local/share/claude-fireworks/proxy.log
```

**Slow responses:**
Check if you're hitting rate limits:
```bash
grep -c "429" ~/.local/share/claude-fireworks/proxy.log
```
Consider upgrading your Fireworks tier for higher rate limits.

**Kill stuck proxy:**
```bash
pkill -f "litellm.*4111"
```

## License

MIT
