#!/bin/bash

echo "[+] Installing ReconHunter dependencies..."

sudo apt update
sudo apt install -y jq curl whatweb nmap ffuf

echo "[+] Installing Go tools..."

go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
go install github.com/projectdiscovery/httpx/cmd/httpx@latest
go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
go install github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest
go install github.com/tomnomnom/assetfinder@latest
go install github.com/tomnomnom/waybackurls@latest

echo "[+] Downloading SecLists..."

git clone https://github.com/danielmiessler/SecLists ~/SecLists

echo "[+] Setup complete!"