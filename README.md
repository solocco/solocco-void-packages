# solocco-void-packages

Unofficial Void Linux binary packages, built automatically via GitHub Actions.

## Available Packages

| Package | Description |
|---|---|
| `zen-browser-bin` | [Zen Browser](https://www.zen-browser.app/) — A calmer internet |
| `google-chrome-bin` | [Google Chrome](https://www.google.com/chrome/) — Fast and secure browser |

---

## Installation

### 1. Add Repository

```bash
echo "repository=https://github.com/solocco/solocco-void-packages/releases/latest/download" | sudo tee /etc/xbps.d/20-solocco.conf
```

### 2. Sync

```bash
sudo xbps-install -S
```

> xbps will prompt you to import the repository's public key. Type `y` to accept.

### 3. Install Packages

```bash
# Zen Browser
sudo xbps-install -S zen-browser-bin

# Google Chrome
sudo xbps-install -S google-chrome-bin

# Or both at once
sudo xbps-install -S zen-browser-bin google-chrome-bin
```

---

## Update

```bash
sudo xbps-install -Su
```

New versions are checked daily and built automatically.

---

## Removal

```bash
# Remove a package
sudo xbps-remove zen-browser-bin
sudo xbps-remove google-chrome-bin

# Remove the repository (optional)
sudo rm /etc/xbps.d/20-solocco.conf
```

---

## Maintainer

[solocco](https://github.com/solocco)
