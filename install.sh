#!/usr/bin/env bash

GREEN="\033[0;32m"
NC="\033[0m"

echo -e "${GREEN}[+] Detecting OS...${NC}"

if [[ "$OSTYPE" == "darwin"* ]]; then
	echo "[+] macOS detected"

	# 1. Force Homebrew path into current script session
	export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

	if ! command -v brew &>/dev/null; then
		echo "[+] Installing Homebrew..."
		/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	fi

	echo "[+] Installing dependencies via Homebrew..."
	# Removed whatweb from this line to prevent the error you saw
	brew install jq curl nmap ffuf yq findomain go coreutils amass python git

	# 2. Install WhatWeb via Ruby Gem instead
	if ! command -v whatweb &>/dev/null; then
		echo "[+] Installing WhatWeb via gem..."
		sudo gem install whatweb
	fi

elif [[ "$OSTYPE" == "linux-gnu"* ]]; then

	echo "[+] Linux detected"

	sudo apt update
	sudo apt install -y jq curl whatweb nmap ffuf golang git unzip python3-pip amass

	echo "[+] Installing yq..."

	sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
	sudo chmod +x /usr/local/bin/yq

	if ! command -v findomain &>/dev/null; then
		echo "[+] Installing findomain..."

		curl -LO https://github.com/Findomain/Findomain/releases/latest/download/findomain-linux.zip
		unzip findomain-linux.zip
		sudo mv findomain /usr/local/bin/
		rm findomain-linux.zip
	fi

fi

if ! command -v go &>/dev/null; then
	# Final attempt to find it before failing
	if [ -f "/opt/homebrew/bin/go" ]; then
		export PATH="/opt/homebrew/bin:$PATH"
	elif [ -f "/usr/local/bin/go" ]; then
		export PATH="/usr/local/bin:$PATH"
	else
		echo -e "${RED}[!] Go installation failed or not found in PATH.${NC}"
		exit 1
	fi
fi

echo -e "${GREEN}[+] Installing Go tools...${NC}"

export PATH="$PATH:$(go env GOPATH)/bin"

go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
go install github.com/projectdiscovery/httpx/cmd/httpx@latest
go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
go install github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest
go install github.com/tomnomnom/assetfinder@latest
go install github.com/tomnomnom/waybackurls@latest
go install github.com/lc/gau/v2/cmd/gau@latest
go install github.com/sensepost/gowitness@latest
go install github.com/ffuf/ffuf/v2@latest

echo "[+] Installing Arjun..."
pip3 install arjun --break-system-packages >/dev/null 2>&1 || pip3 install arjun >/dev/null 2>&1

echo -e "${GREEN}[+] Downloading SecLists...${NC}"

if [ ! -d "$HOME/SecLists" ]; then
	git clone --depth 1 https://github.com/danielmiessler/SecLists "$HOME/SecLists"
else
	echo "[*] SecLists already exists, skipping download."
fi

echo
echo -e "${GREEN}[+] Setup complete!${NC}"
echo "[*] Add this to your shell config:"
echo "export PATH=\$PATH:\$(go env GOPATH)/bin"
