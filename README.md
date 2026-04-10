
```bash
echo "repository=https://github.com/solocco/solocco-void-packages/releases/latest/download" | sudo tee /etc/xbps.d/20-solocco.conf
```



```bash
sudo xbps-install -S
```


```bash
# Zen Browser
sudo xbps-install -S zen-browser-bin

# Google Chrome
sudo xbps-install -S google-chrome-bin

# Or both at once
sudo xbps-install -S zen-browser-bin google-chrome-bin
```


```bash
sudo xbps-install -Su
```


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
