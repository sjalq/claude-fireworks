# Claude Code with Fireworks AI

Run [Claude Code](https://github.com/anthropics/claude-code) powered by Fireworks AI models (Kimi K2.5) instead of Anthropic's API.

## One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/sjalq/claude-fireworks/main/claude-kimi.sh | bash -s -- --install
```

This will:
1. Download the script to `~/.local/bin/claude-kimi`
2. Prompt you for your Fireworks API key
3. Add to your PATH if needed

Then run: `claude-kimi /path/to/project`

---

## Prerequisites

Before installing, you need:

### 1. Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
```

### 2. Python 3.8+

Most systems have this. Check with: `python3 --version`

### 3. Fireworks API Key

1. Go to **https://fireworks.ai**
2. Click **"Sign Up"** (or "Log In" if you have an account)
3. After signing in, go to **https://fireworks.ai/account/api-keys**
4. Click **"Create API Key"**
5. Copy the key (starts with `fw_`)

Keep this key ready - the installer will ask for it.

---

## Usage

```bash
# Open a project
claude-kimi /path/to/project

# Ask a question about a file
claude-kimi -p "explain this code" file.ts

# Use the faster/lighter model
claude-kimi --model kimi-k2-instruct
```

## How It Works

```
Claude Code  →  LiteLLM Proxy (localhost:4111)  →  Fireworks AI (Kimi K2.5)
```

The script runs a local proxy that translates Claude API calls to Fireworks AI.

## Models

| Model | Best For |
|-------|----------|
| `kimi-k2.5` (default) | Complex coding, reasoning |
| `kimi-k2-instruct` | Quick tasks, faster responses |

## Troubleshooting

**Slow responses?** You may be hitting rate limits. Check:
```bash
grep -c "429" ~/.local/share/claude-fireworks/proxy.log
```
Upgrade your Fireworks tier for higher limits.

**Proxy issues?** Check the log:
```bash
cat ~/.local/share/claude-fireworks/proxy.log
```

**Kill stuck proxy:**
```bash
pkill -f "litellm.*4111"
```

## Uninstall

```bash
claude-kimi --uninstall
```

## License

MIT
