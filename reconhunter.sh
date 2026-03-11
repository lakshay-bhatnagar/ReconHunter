#!/usr/bin/env bash

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

mode="full"

set -euo pipefail

CONFIG_FILE="config.yaml"
ACTIVE_ENUM=false
BASE_OUTPUT=$(yq '.general.output_directory' "$CONFIG_FILE")
WORDLIST=$(yq '.wordlists.directory_bruteforce' "$CONFIG_FILE")
FFUF_THREADS=$(yq '.performance.ffuf_threads' "$CONFIG_FILE")
NMAP_TIMING=$(yq '.nmap.timing' "$CONFIG_FILE")
SCREENSHOT_DIR=$(yq '.screenshots.directory' "$CONFIG_FILE")
REPORT_FILE=$(yq '.report.filename' "$CONFIG_FILE")
CRT_API=$(yq '.apis.crtsh' "$CONFIG_FILE")

trap 'echo -e "\n${RED}[!] Error occurred at line $LINENO. Exiting.${NC}"' ERR

# installation function

install_tools() {

	echo "[+] Installing required tools..."

	sudo apt update
	sudo apt install yq
	sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
	sudo chmod +x /usr/local/bin/yq
	sudo apt install -y jq curl whatweb nmap
	go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
	go install github.com/projectdiscovery/httpx/cmd/httpx@latest
	sudo apt install findomain
	go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
	go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
	go install github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest
	go install github.com/tomnomnom/assetfinder@latest
	go install github.com/tomnomnom/waybackurls@latest
	go install github.com/lc/gau/v2/cmd/gau@latest
	go install github.com/projectdiscovery/ffuf@latest
	echo "[+] Installation complete"
}

# validation of domain

validate_domain() {
	if ! [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
		echo "${RED}[!] Invalid domain format${NC}"
		exit 1
	fi
}

# all the functions

run_enumeration() {

	# ---------------------
	# 1. Subdomain Enumeration
	# ---------------------

	echo "[+] Running subdomain tools in parallel..."

	assetfinder --subs-only "$domain" >"$output_dir/subs_assetfinder.txt" 2>/dev/null &

	subfinder -d "$domain" -silent >"$output_dir/subs_subfinder.txt" 2>/dev/null &

	if [[ "$mode" != "fast" ]]; then
		findomain -t "$domain" -u "$output_dir/subs_findomain.txt" >/dev/null 2>&1 &
		amass enum -passive -d "$domain" -silent -o "$output_dir/subs_amass.txt" 2>/dev/null &
	fi

	crt_output=$(curl -m 10 -s "$(printf "$CRT_API" "$domain")")

	if echo "$crt_output" | jq . >/dev/null 2>&1; then
		echo "$crt_output" |
			jq -r '.[].name_value' |
			sed 's/\*\.//g' |
			sort -u >>"$output_dir/subs_crtsh.txt"
	else
		echo "[!] crt.sh API returned invalid JSON, skipping..."
	fi

	# Optional active scan
	if [ "$ACTIVE_ENUM" = true ]; then
		echo "[+] Running Amass Active Enumeration..."
		amass enum -active -d "$domain" -silent -o "$output_dir/subs_amassactive.txt" 2>/dev/null &
	fi

	echo "[+] Waiting for enumeration tools to finish..."
	wait

	echo "${GREEN}[+] Merging and deduplicating subdomains..."

	cat "$output_dir"/subs_*.txt 2>/dev/null | sort -u >"$output_dir/all_subdomains.txt"

	print_stat "Subdomains found" "$output_dir/all_subdomains.txt"
}

run_dns() {
	# ---------------------
	# 2. DNS Resolution
	# ---------------------
	echo "${GREEN}[+] Resolving live subdomains..."
	dnsx -l "$output_dir/all_subdomains.txt" -silent -a -resp >"$output_dir/resolved.txt"
	print_stat "Resolved hosts" "$output_dir/resolved.txt"
}

# nmap port scanning

run_port_scanning() {
	# ---------------------
	# 3. Port Scanning
	# ---------------------
	echo "${GREEN}[+] Running Nmap port scan..."

	if [ -s "$output_dir/resolved.txt" ]; then
		nmap -iL "$output_dir/resolved.txt" -"${NMAP_TIMING}" -oA "$output_dir/nmap_scan"
		port_count=$(grep "open" "$output_dir/nmap_scan.gnmap" | wc -l 2>/dev/null || echo 0)
		echo -e "${GREEN}[ReconHunter] Open ports discovered: $port_count${NC}"
	else
		echo "${RED}[!] Skipping Nmap - No resolved hosts found."
	fi
}

run_http_probing() {
	# ---------------------
	# 4. HTTP Probing
	# ---------------------
	echo "${GREEN}[+] Probing live HTTP services..."
	httpx-toolkit -l "$output_dir/resolved.txt" -silent >"$output_dir/alive_http.txt"
}

run_tech_detection() {
	# ---------------------
	# 5. Technology Detection
	# ---------------------
	echo "${GREEN}[+] Detecting technologies with WhatWeb..."

	if command -v whatweb &>/dev/null; then
		whatweb -i "$output_dir/alive_http.txt" --log-json="$output_dir/whatweb.json" >"$output_dir/whatweb.txt"
	else
		echo "${RED}[!] WhatWeb not installed. Skipping tech detection."
	fi
}

run_screenshot_capture() {
	# ---------------------
	# 6. Screenshot Capture
	# ---------------------
	echo "${GREEN}[+] Capturing screenshots with Gowitness..."

	if command -v gowitness &>/dev/null; then
		mkdir -p "$output_dir/$SCREENSHOT_DIR"
		gowitness scan file -f "$output_dir/alive_http.txt" --screenshot-path "$output_dir/$SCREENSHOT_DIR"
	else
		echo "${RED}[!] Gowitness not installed. Skipping screenshots."
	fi
}

run_archive_url() {
	# ---------------------
	# 7. Archive URL Gathering
	# ---------------------
	echo "${GREEN}[+] Gathering URLs from gau and waybackurls..."
	if command -v getallurls &>/dev/null; then
		getallurls "$domain" >>"$output_dir/urls_gau.txt"
	else
		echo "${RED}[!] gau not installed"
	fi

	if command -v waybackurls &>/dev/null; then
		echo "$domain" | waybackurls >>"$output_dir/urls_wayback.txt"
	else
		echo "${RED}[!] waybackurls not installed"
	fi

	cat "$output_dir"/urls_*.txt 2>/dev/null | sort -u >"$output_dir/all_urls.txt"
	print_stat "URLs collected" "$output_dir/all_urls.txt"

}

run_parameter_discovery() {
	# ---------------------
	# 8. Parameter Discovery
	# ---------------------
	echo "${GREEN}[+] Running Arjun for parameter fuzzing..."
	if [ -s "$output_dir/alive_http.txt" ]; then
		arjun -i "$output_dir/alive_http.txt" -m GET -oT "$output_dir/arjun_params.txt" 2>/dev/null
	else
		echo "${RED}[!] Skipping Arjun - No alive HTTP hosts found."
	fi

}

run_directory_bruteforce() {
	# ---------------------
	# 9. Directory Bruteforcing
	# ---------------------
	echo "${GREEN}[+] Running ffuf on alive subdomains..."
	wordlist="$WORDLIST"
	if [ ! -f "$wordlist" ]; then
		echo "[!] Wordlist not found: $wordlist"
	else
		while read -r url; do
			ffuf -u "$url/FUZZ" -w "$wordlist" -t "$FFUF_THREADS" -o "$output_dir/ffuf_$(echo "$url" | cut -d/ -f3).json" -of json
		done <"$output_dir/alive_http.txt"
	fi

}

run_nuclei_scans() {
	# ---------------------
	# 10. Nuclei Vulnerability Scanning
	# ---------------------
	echo "${GREEN}[+] Scanning with Nuclei on alive http..."
	if [[ -s "$output_dir/alive_http.txt" ]]; then
		nuclei -l "$output_dir/alive_http.txt" -o "$output_dir/nuclei_output.txt"
	fi
	echo "${GREEN}[+] Scanning with Nuclei on all urls..."
	if [[ -s "$output_dir/all_urls.txt" ]]; then
		nuclei -l "$output_dir/all_urls.txt" -o "$output_dir/nuclei_urls.txt"
	fi
	print_stat "Vulnerabilities detected" "$output_dir/nuclei_output.txt"
	# ---------------------
	# Done
	# ---------------------
	echo "${GREEN}[✔] Recon complete! All output saved in: $output_dir"
}

run_recon_summary_report() {
	# ---------------------
	# Recon Summary
	# ---------------------

	echo
	echo "============================"
	echo "       RECON SUMMARY"
	echo "============================"

	sub_count=$(wc -l <"$output_dir/all_subdomains.txt" 2>/dev/null)
	alive_count=$(wc -l <"$output_dir/alive_http.txt" 2>/dev/null)
	url_count=$(wc -l <"$output_dir/all_urls.txt" 2>/dev/null)
	vuln_count=$(wc -l <"$output_dir/nuclei_output.txt" 2>/dev/null)

	echo "${NC}Total Subdomains Found : ${sub_count:-0}"
	echo "${NC}Alive HTTP Hosts       : ${alive_count:-0}"
	echo "${NC}URLs Collected         : ${url_count:-0}"
	echo "${NC}Vulnerabilities Found  : ${vuln_count:-0}"

	echo
	echo "${GREEN}[✔] Recon complete! All output saved in: $output_dir"

	# ---------------------
	# Report Generation
	# ---------------------

	echo
	echo "============================"
	echo "  GENERATING HTML REPORT"
	echo "============================"

	report="$output_dir/$REPORT_FILE"

	echo "[+] Generating HTML report..."

	cat <<EOF >"$report"
    <html>
    <head>
    <title>ReconHunter Report - $domain</title>

    <style>

    body{
        font-family: "Segoe UI", Arial, sans-serif;
        background:#0d1117;
        color:#e6edf3;
        margin:0;
        padding:0;
    }

    header{
        background:#161b22;
        padding:25px;
        border-bottom:1px solid #30363d;
    }

    header h1{
        margin:0;
        color:#58a6ff;
    }

    .container{
        padding:30px;
    }

    .cards{
        display:flex;
        gap:20px;
        flex-wrap:wrap;
        margin-bottom:30px;
    }

    .card{
        background:#161b22;
        padding:20px;
        border-radius:10px;
        border:1px solid #30363d;
        flex:1;
        min-width:200px;
        text-align:center;
    }

    .card h2{
        margin:0;
        font-size:28px;
        color:#58a6ff;
    }

    .card p{
        margin:5px 0 0 0;
        color:#8b949e;
    }

    .section{
        margin-top:40px;
    }

    .section h2{
        border-bottom:1px solid #30363d;
        padding-bottom:10px;
        margin-bottom:15px;
        color:#58a6ff;
    }

    table{
        width:100%;
        border-collapse:collapse;
    }

    th,td{
        padding:10px;
        border:1px solid #30363d;
        text-align:left;
    }

    th{
        background:#161b22;
    }

    pre{
        background:#161b22;
        padding:20px;
        border-radius:10px;
        overflow:auto;
        max-height:400px;
    }

    footer{
        text-align:center;
        margin-top:50px;
        padding:20px;
        color:#8b949e;
        border-top:1px solid #30363d;
    }

    .badge{
        padding:4px 10px;
        border-radius:6px;
        font-size:12px;
        font-weight:bold;
    }

    .critical{background:#ff4d4f;}
    .high{background:#ff7b72;}
    .medium{background:#e3b341;}
    .low{background:#3fb950;}

    </style>
    </head>

    <body>

    <header>
    <h1>ReconHunter Security Report</h1>
    <p>Target: <b>$domain</b></p>
    <p>Generated: $(date)</p>
    </header>

    <div class="container">

    <div class="cards">

    <div class="card">
    <h2>$sub_count</h2>
    <p>Subdomains Found</p>
    </div>

    <div class="card">
    <h2>$alive_count</h2>
    <p>Alive Hosts</p>
    </div>

    <div class="card">
    <h2>$url_count</h2>
    <p>URLs Collected</p>
    </div>

    <div class="card">
    <h2>$vuln_count</h2>
    <p>Vulnerabilities</p>
    </div>

    </div>


    <div class="section">
    <h2>Subdomains</h2>
    <pre>
    $(head -n 100 "$output_dir/all_subdomains.txt" 2>/dev/null)
    </pre>
    </div>


    <div class="section">
    <h2>Alive Hosts</h2>
    <pre>
    $(head -n 100 "$output_dir/alive_http.txt" 2>/dev/null)
    </pre>
    </div>


    <div class="section">
    <h2>Discovered URLs</h2>
    <pre>
    $(head -n 100 "$output_dir/all_urls.txt" 2>/dev/null)
    </pre>
    </div>


    <div class="section">
    <h2>Nuclei Vulnerabilities</h2>

    <pre>
    $(cat "$output_dir/nuclei_output.txt" 2>/dev/null)
    </pre>

    </div>

    <div class="section">
    <h2>Technology Detection</h2>

    <pre>
    $(cat "$output_dir/whatweb.txt" 2>/dev/null)
    </pre>

    </div>

    </div>

    <footer>

    ReconHunter Automated Recon Framework  
    Created by Lakshay Bhatnagar

    </footer>

    </body>
    </html>
EOF
}

# ---------------------
# Parse CLI Flags
# ---------------------

domain=""
mode="full"

while [[ $# -gt 0 ]]; do
	case "$1" in
	-d | --domain)
		domain="$2"
		shift 2
		;;

	-o | --output)
		output_dir="$2"
		shift 2
		;;

	--fast)
		mode="fast"
		shift
		;;

	--full)
		mode="full"
		shift
		;;

	--scan)
		mode="scan"
		shift
		;;

	--active)
		ACTIVE_ENUM=true
		shift
		;;

	--install)
		install_tools
		exit
		;;

	-h | --help)
		echo "ReconHunter - Automated Recon Tool"
		echo
		echo "Usage:"
		echo "  reconhunter -d <domain> [--fast|--full|--scan] [options]"
		echo
		echo "Options:"
		echo "  -d, --domain     Target domain"
		echo "  -o, --output     Custom output directory (Optional)"
		echo "  --fast           Quick recon"
		echo "  --full           Full recon pipeline"
		echo "  --scan           Vulnerability scanning only"
		echo "  --active         Enable active enumeration (amass active)"
		echo "  --install        Install required tools"
		echo "  -h, --help       Show this help menu"
		exit
		;;

	--version)
		echo "ReconHunter v1.0"
		exit
		;;

	*)
		echo "Unknown option: $1"
		exit 1
		;;
	esac
done

# ---------------------
# Domain Input
# ---------------------

if [[ -z "$domain" ]]; then
	echo "Error: Domain required"
	echo "Usage: reconhunter -d example.com --full"
	exit 1
fi

validate_domain
if [[ -z "${output_dir:-}" ]]; then
	timestamp=$(date +"%Y%m%d_%H%M%S")
	# base_output="reports"
	output_dir="${BASE_OUTPUT}/recon_${domain}_${timestamp}"
fi
mkdir -p "$output_dir"

# ---------------------
# Banner
# ---------------------

echo
echo "====================================================="
echo "               ReconHunter v1.0"
echo "           Automated Recon Framework"
echo " ⭐ GitHub: github.com/lakshay-bhatnagar/ReconHunter"
echo "====================================================="
echo
echo "[*] Mode: $mode"
echo "[*] Target: $domain"
echo "[*] Output directory: $output_dir"
echo

# ---------------------
# Tool Dependency Check
# ---------------------

tools=(
	assetfinder
	subfinder
	findomain
	amass
	dnsx
	httpx-toolkit
	nuclei
	ffuf
	arjun
	jq
	curl
)

echo "[+] Checking required tools..."

missing=0

for tool in "${tools[@]}"; do
	if ! command -v "$tool" &>/dev/null; then
		echo "[!] $tool not installed"
		missing=1
	fi
done

if [[ "$missing" -eq 1 ]]; then
	echo "[!] Missing dependencies. Run: reconhunter --install"
	exit 1
fi

echo

print_stat() {
	label=$1
	file=$2

	if [[ -f "$file" ]]; then
		count=$(wc -l <"$file" 2>/dev/null)
	else
		count=0
	fi

	echo -e "${GREEN}[ReconHunter] $label: $count${NC}"
}

# Check if jq is installed
if ! command -v jq &>/dev/null; then
	echo "[!] 'jq' is not installed. Please install it to parse JSON from crt.sh"
	echo "    Example: sudo apt install jq"
	exit 1
fi

log_file="$output_dir/recon.log"

exec > >(tee -a "$log_file")
exec 2>&1

# Fast Mode

if [[ "$mode" == "fast" ]]; then
	echo "[1/6] Subdomain Enumeration"
	run_enumeration
	echo "[2/6] DNS Resolution"
	run_dns
	echo "[3/6] HTTP Probing"
	run_http_probing
	echo "[4/6] Archive URL Gathering"
	run_archive_url
	echo "[5/6] Nuclei Vulnerability Scanning"
	run_nuclei_scans
	echo "[6/6] Recon Summary and Report Generation"
	run_recon_summary_report
fi

# Full Mode

if [[ "$mode" == "full" ]]; then
	if [[ "$mode" == "full" ]] && [[ "$ACTIVE_ENUM" == false ]]; then
		ACTIVE_ENUM=true
	fi
	echo "[1/11] Subdomain Enumeration"
	run_enumeration
	echo "[2/11] DNS Resolution"
	run_dns
	echo "[3/11] Port Scanning"
	run_port_scanning
	echo "[4/11] HTTP Probing"
	run_http_probing
	echo "[5/11] Technology Detection"
	run_tech_detection
	echo "[6/11] Screenshot Capture"
	run_screenshot_capture
	echo "[7/11] Archive URL Gathering"
	run_archive_url
	echo "[8/11] Parameter Discovery"
	run_parameter_discovery
	echo "[9/11] Directory Bruteforcing"
	run_directory_bruteforce
	echo "[10/11] Nuclei Vulnerability Scanning"
	run_nuclei_scans
	echo "[11/11] Recon Summary and Report Generation"
	run_recon_summary_report
fi

# Scan Mode

if [[ "$mode" == "scan" ]]; then
	echo "[1/2] Parameter Discovery"
	run_parameter_discovery
	echo "[2/2] Nuclei Vulnerability Scanning"
	run_nuclei_scans
fi
