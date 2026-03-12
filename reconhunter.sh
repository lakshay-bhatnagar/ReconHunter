#!/usr/bin/env bash

# Add Go bin, Homebrew paths (Intel & Silicon), and local bins
export PATH="$PATH:$HOME/go/bin:$(go env GOPATH 2>/dev/null)/bin:/usr/local/bin:/opt/homebrew/bin"

# Cross-platform timeout wrapper
if command -v gtimeout &>/dev/null; then
	alias timeout='gtimeout'
elif ! command -v timeout &>/dev/null; then
	echo -e "${RED}[!] timeout command not found. Install coreutils (Mac) or setup PATH.${NC}"
fi

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

VERSION="1.1.1"

mode="full"

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

# installation function macOS

install_tools_mac() {
	echo "[+] Installing required tools for macOS..."

	# Check if Homebrew is installed
	if ! command -v brew &>/dev/null; then
		echo "[!] Homebrew not found. Installing now..."
		/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	fi

	# Install standard packages
	brew install yq jq curl nmap whatweb findomain amass go
	brew install coreutils

	# Install Go-based tools (ProjectDiscovery & TomNomNom)
	echo "[+] Installing Go-based security tools..."
	go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
	go install github.com/projectdiscovery/httpx/cmd/httpx@latest
	go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
	go install github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest
	go install github.com/tomnomnom/assetfinder@latest
	go install github.com/tomnomnom/waybackurls@latest
	go install github.com/lc/gau/v2/cmd/gau@latest
	go install github.com/projectdiscovery/ffuf@latest

	# Optional: Arjun usually requires pip (Python)
	pip3 install arjun

	echo "[+] Installation complete. Ensure ~/go/bin is in your PATH."
}

# installation function linux

install_tools() {

	echo "[+] Installing required tools..."

	sudo apt update
	sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
	sudo chmod +x /usr/local/bin/yq
	sudo apt install -y jq curl whatweb nmap
	go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
	go install github.com/projectdiscovery/httpx/cmd/httpx@latest
	sudo apt install findomain
	go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
	# Better way to move binaries on Linux
	GOPATH_BIN=$(go env GOPATH)/bin
	sudo cp "$GOPATH_BIN/httpx" /usr/local/bin/
	go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
	go install github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest
	go install github.com/tomnomnom/assetfinder@latest
	go install github.com/tomnomnom/waybackurls@latest
	go install github.com/lc/gau/v2/cmd/gau@latest
	sudo mv ~/go/bin/gau /usr/local/bin/
	go install github.com/projectdiscovery/ffuf@latest
	echo "[+] Installation complete"
}

# validation of domain

validate_domain() {
	if ! [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
		echo -e "${RED}[!] Invalid domain format${NC}"
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

	crt_output=$(curl -m 10 -s "https://crt.sh/?q=%25.$domain&output=json")

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
	for job in $(jobs -p); do
		wait "$job" || true
	done

	echo -e "${GREEN}[+] Merging and deduplicating subdomains..."

	cat "$output_dir"/subs_*.txt 2>/dev/null | sort -u >"$output_dir/all_subdomains.txt"

	print_stat "Subdomains found" "$output_dir/all_subdomains.txt"
}

run_dns() {
	echo -e "${GREEN}[+] Resolving IP addresses of alive hosts...${NC}"

	cat "$output_dir/alive_http.txt" |
		sed 's|https\?://||' |
		dnsx -silent \
			>"$output_dir/resolved.txt"

	print_stat "Resolved hosts" "$output_dir/resolved.txt"
}

# nmap port scanning

run_port_scanning() {

	# ---------------------
	# 4. Port Scanning
	# ---------------------

	echo -e "${GREEN}[+] Running Nmap port scan...${NC}"

	if [[ -s "$output_dir/alive_http.txt" ]]; then

		cat "$output_dir/alive_http.txt" |
			sed 's|https\?://||' |
			sort -u \
				>"$output_dir/nmap_targets.txt"

		nmap -iL "$output_dir/nmap_targets.txt" -"${NMAP_TIMING}" -oA "$output_dir/nmap_scan"

		port_count=$(grep "open" "$output_dir/nmap_scan.gnmap" 2>/dev/null | wc -l || echo 0)

		echo -e "${GREEN}[ReconHunter] Open ports discovered: $port_count${NC}"

	else
		echo -e "${RED}[!] Skipping Nmap - No alive hosts found.${NC}"
	fi
}

run_http_probing() {
	echo -e "${GREEN}[+] Probing HTTP services...${NC}"

	httpx \
		-l "$output_dir/all_subdomains.txt" \
		-silent \
		-threads 100 \
		-o "$output_dir/alive_http.txt"

	print_stat "Alive HTTP hosts" "$output_dir/alive_http.txt"
}

run_tech_detection() {
	# ---------------------
	# 5. Technology Detection
	# ---------------------
	echo -e "${GREEN}[+] Detecting technologies with WhatWeb..."

	if command -v whatweb &>/dev/null; then
		whatweb -i "$output_dir/alive_http.txt" --log-json="$output_dir/whatweb.json" >"$output_dir/whatweb.txt"
	else
		echo -e "${RED}[!] WhatWeb not installed. Skipping tech detection."
	fi
}

run_screenshot_capture() {
	# ---------------------
	# 6. Screenshot Capture
	# ---------------------
	echo -e "${GREEN}[+] Capturing screenshots with Gowitness..."

	if command -v gowitness &>/dev/null; then
		mkdir -p "$output_dir/$SCREENSHOT_DIR"
		gowitness scan file -f "$output_dir/alive_http.txt" --screenshot-path "$output_dir/$SCREENSHOT_DIR"
	else
		echo -e "${RED}[!] Gowitness not installed. Skipping screenshots."
	fi
}

run_archive_url() {
	# ---------------------
	# 7. Archive URL Gathering
	# ---------------------
	echo -e "${GREEN}[+] Gathering URLs from gau and waybackurls..."
	if command -v gau &>/dev/null; then
		timeout 60 gau "$domain" >>"$output_dir/urls_gau.txt" 2>/dev/null
	else
		echo -e "${RED}[!] gau not installed"
	fi

	if command -v waybackurls &>/dev/null; then
		echo "$domain" | waybackurls >>"$output_dir/urls_wayback.txt"
	else
		echo -e "${RED}[!] waybackurls not installed"
	fi

	cat "$output_dir"/urls_*.txt 2>/dev/null | sort -u >"$output_dir/all_urls.txt"
	print_stat "URLs collected" "$output_dir/all_urls.txt"

}

run_parameter_discovery() {
	# ---------------------
	# 8. Parameter Discovery
	# ---------------------
	echo -e "${GREEN}[+] Running Arjun for parameter fuzzing..."
	if [ -s "$output_dir/alive_http.txt" ]; then
		arjun -i "$output_dir/alive_http.txt" -m GET -oT "$output_dir/arjun_params.txt" 2>/dev/null
	else
		echo -e "${RED}[!] Skipping Arjun - No alive HTTP hosts found."
	fi

}

run_directory_bruteforce() {
	# ---------------------
	# 9. Directory Bruteforcing
	# ---------------------
	echo -e "${GREEN}[+] Running ffuf on alive subdomains..."
	wordlist="$WORDLIST"
	if [ ! -f "$wordlist" ]; then
		echo "[!] Wordlist not found: $wordlist"
	else
		while read -r url; do
			(
				ffuf -u "$url/FUZZ" \
					-w "$wordlist" \
					-t "$FFUF_THREADS" \
					-o "$output_dir/ffuf_$(echo "$url" | cut -d/ -f3).json" \
					-of json
			) &
		done <"$output_dir/alive_http.txt"

		wait
	fi

}

run_nuclei_scans() {

	echo -e "${GREEN}[+] Scanning with Nuclei on alive HTTP hosts...${NC}"

	if [[ -s "$output_dir/alive_http.txt" ]]; then
		nuclei \
			-l "$output_dir/alive_http.txt" \
			-o "$output_dir/nuclei_output.txt" \
			-rl 50 \
			-silent \
			-severity critical,high,medium,low
	fi

	echo -e "${GREEN}[+] Preparing URLs for Nuclei scanning...${NC}"

	if [[ -s "$output_dir/all_urls.txt" ]]; then

		grep "=" "$output_dir/all_urls.txt" |
			grep -Ev "\.(jpg|jpeg|png|gif|css|js|svg|woff|ttf|ico|pdf|mp4|mp3)$" |
			sort -u |
			head -n 20000 \
				>"$output_dir/nuclei_targets.txt"

	fi

	echo -e "${GREEN}[+] Scanning filtered URLs with Nuclei...${NC}"

	if [[ -s "$output_dir/nuclei_targets.txt" ]]; then
		nuclei \
			-l "$output_dir/nuclei_targets.txt" \
			-as "$output_dir/nuclei_output.txt" \
			-rl 50 \
			-silent \
			-severity critical,high,medium,low
	fi

	# Deduplicate results
	if [[ -f "$output_dir/nuclei_output.txt" ]]; then
		sort -u "$output_dir/nuclei_output.txt" -o "$output_dir/nuclei_output.txt"
	fi

	print_stat "Vulnerabilities detected" "$output_dir/nuclei_output.txt"
}

run_recon_summary_report() {
	# ---------------------
	# Recon Summary
	# ---------------------

	echo
	echo "============================"
	echo "       RECON SUMMARY"
	echo "============================"

	sub_count=$(wc -l <"$output_dir/all_subdomains.txt" 2>/dev/null || echo 0)
	alive_count=$(wc -l <"$output_dir/alive_http.txt" 2>/dev/null || echo 0)
	url_count=$(wc -l <"$output_dir/all_urls.txt" 2>/dev/null || echo 0)

	if [[ -f "$output_dir/nuclei_output.txt" ]]; then
		vuln_count=$(wc -l <"$output_dir/nuclei_output.txt")
	else
		vuln_count=0
	fi

	echo
	echo -e "${NC}Total Subdomains Found : ${sub_count:-0}"
	echo -e "${NC}Alive HTTP Hosts       : ${alive_count:-0}"
	echo -e "${NC}URLs Collected         : ${url_count:-0}"
	echo -e "${NC}Vulnerabilities Found  : ${vuln_count:-0}"

	echo

	# ---------------------
	# Report Generation
	# ---------------------

	echo
	echo "============================"
	echo "  GENERATING HTML REPORT"
	echo "============================"

	report="$output_dir/$REPORT_FILE"

	echo "[+] Generating HTML report..."
	echo
	echo -e "${GREEN}[✔] Recon complete! All output saved in: $output_dir"

	critical_count=$(grep -i "critical" "$output_dir/nuclei_output.txt" 2>/dev/null | wc -l || echo 0)
	high_count=$(grep -i "high" "$output_dir/nuclei_output.txt" 2>/dev/null | wc -l || echo 0)
	medium_count=$(grep -i "medium" "$output_dir/nuclei_output.txt" 2>/dev/null | wc -l || echo 0)
	low_count=$(grep -i "low" "$output_dir/nuclei_output.txt" 2>/dev/null | wc -l || echo 0)

	cat <<EOF >"$report"
    <html>
	<head>
	<title>ReconHunter Report - $domain</title>

	<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>

	<style>

	body{
		font-family: "Segoe UI", Arial, sans-serif;
		background:#0d1117;
		color:#e6edf3;
		margin:0;
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

	/* Dashboard cards */

	.cards{
		display:grid;
		grid-template-columns:repeat(auto-fit,minmax(220px,1fr));
		gap:20px;
		margin-bottom:40px;
	}

	.card{
		background:#161b22;
		padding:25px;
		border-radius:12px;
		border:1px solid #30363d;
		transition:0.2s;
	}

	.card:hover{
		transform:translateY(-3px);
		border-color:#58a6ff;
	}

	.card h2{
		margin:0;
		font-size:34px;
		color:#58a6ff;
	}

	.card p{
		margin-top:5px;
		color:#8b949e;
	}

	/* Sections */

	.section{
		margin-top:40px;
	}

	.section h2{
		border-bottom:1px solid #30363d;
		padding-bottom:10px;
		color:#58a6ff;
	}

	/* Scrollable data blocks */

	pre{
		background:#161b22;
		padding:20px;
		border-radius:10px;
		overflow:auto;
		max-height:350px;
	}

	/* Chart container */

	.chart-container{
		background:#161b22;
		border:1px solid #30363d;
		padding:20px;
		border-radius:10px;
		margin-bottom:40px;
	}

	/* Clickable URLs */

	.list a{
    color:#58a6ff;
    text-decoration:none;
	}

	/* FIX: Reduced Pie Chart Size */
    .pie-chart-wrapper {
        max-width: 400px;
        margin: 0 auto; /* Centers the pie chart */
    }

	.list a:hover{
		text-decoration:underline;
	}

	/* Footer */

	footer{
		text-align:center;
		padding:25px;
		border-top:1px solid #30363d;
		margin-top:50px;
		color:#8b949e;
	}

	</style>
	</head>


	<body>

	<header>
	<h1>ReconHunter Dashboard</h1>
	<p>Target: <b>$domain</b></p>
	<p>Generated: $(date)</p>
	</header>


	<div class="container">

	<!-- Summary Cards -->

	<div class="cards">

	<div class="card">
	<h2>$sub_count</h2>
	<p>Subdomains</p>
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


	<!-- Visualization -->

	<div class="chart-container">
	<canvas id="reconChart"></canvas>
	</div>


	<!-- Subdomains -->

	<div class="section">
    <h2>Subdomains</h2>
    <pre class="list">
		$(head -n 100 "$output_dir/all_subdomains.txt" | sed 's|^|<a href="http://&" target="_blank">|; s|$|</a>|')
    </pre>
	</div>


	<!-- Alive Hosts -->

	<div class="section">
    <h2>Alive Hosts</h2>
    <pre class="list">
		$(head -n 100 "$output_dir/alive_http.txt" | sed 's|^|<a href="|; s|$|" target="_blank">&</a>|')
    </pre>
	</div>


	<!-- URLs -->

	<div class="section">
	<h2>Discovered URLs</h2>

	<pre>
	$(head -n 100 "$output_dir/all_urls.txt" 2>/dev/null)
	</pre>

	</div>


	<!-- Nuclei -->

	<div class="section">
	<h2>Nuclei Vulnerabilities</h2>

	<pre>
	$(cat "$output_dir/nuclei_output.txt" 2>/dev/null)
	</pre>

	</div>


	<!-- Technology -->

	<div class="section">
	<h2>Technology Detection</h2>

	<pre>
	$(cat "$output_dir/whatweb.txt" 2>/dev/null)
	</pre>

	</div>

	</div>

	<!-- Chart -->

	<div class="chart-container">
	<h2>Vulnerability Severity Distribution</h2>
	<div class="pie-chart-wrapper">
        <canvas id="severityChart"></canvas>
    </div>
	</div>
	</div>

	<footer>
	ReconHunter Automated Recon Framework<br>
	Created by Lakshay Bhatnagar
	</footer>


	<script>

	const ctx = document.getElementById('reconChart');

	new Chart(ctx, {
		type: 'bar',
		data: {
			labels: [
				'Subdomains',
				'Alive Hosts',
				'Vulnerabilities'
			],
			datasets: [{
				label: 'Recon Results',
				data: [
					$sub_count,
					$alive_count,
					$vuln_count
				],
				backgroundColor:[
					'#58a6ff',
					'#3fb950',
					'#e3b341',
				]
			}]
		},
		options:{
			plugins:{
				legend:{display:false}
			},
			scales:{
				y:{
					beginAtZero:true
				}
			}
		}
	});

	const severityCtx = document.getElementById('severityChart');

	new Chart(severityCtx, {
		type: 'pie',
		data: {
			labels: ['Critical','High','Medium','Low'],
			datasets: [{
				data: [
					$critical_count,
					$high_count,
					$medium_count,
					$low_count
				],
				backgroundColor: [
					'#ff4d4f',
					'#ff7b72',
					'#e3b341',
					'#3fb950'
				]
			}]
		},
		options:{
			plugins:{
				legend:{
					labels:{
						color:'#e6edf3'
					}
				}
			}
		}
	});

	</script>

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
		if [[ "$OSTYPE" == "darwin"* ]]; then
			install_tools_mac
		else
			install_tools
		fi
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
		echo "ReconHunter $VERSION"
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
echo "========================================================="
echo "      ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗"
echo "      ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║"
echo "      ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║"
echo "      ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║"
echo "      ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║"
echo "      ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝ˇ"
echo "               ReconHunter v$VERSION"
echo "           Automated Recon Framework"
echo " ⭐ GitHub: github.com/lakshay-bhatnagar/ReconHunter"
echo "========================================================="
echo
echo "[*] Mode: $mode"
echo "[*] Target: $domain"
echo "[*] Output directory: $output_dir"
echo

start_time=$(date +%s)
# ---------------------
# Tool Dependency Check
# ---------------------

tools=(
	assetfinder
	subfinder
	findomain
	amass
	dnsx
	httpx
	gau
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
	echo "[!] Missing dependencies. Run: ./reconhunter --install"
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
	echo "[2/6] HTTP Probing"
	run_http_probing
	echo "[3/6] DNS Resolution"
	run_dns
	echo "[4/6] Archive URL Gathering"
	run_archive_url
	echo "[5/6] Nuclei Vulnerability Scanning"
	run_nuclei_scans
	echo "[6/6] Recon Summary and Report Generation"
	run_recon_summary_report
fi

# Full Mode

if [[ "$mode" == "full" ]]; then
	echo "[1/11] Subdomain Enumeration"
	run_enumeration
	echo "[2/11] HTTP Probing"
	run_http_probing
	echo "[3/11] DNS Resolution"
	run_dns
	echo "[4/11] Port Scanning"
	run_port_scanning
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

end_time=$(date +%s)
runtime=$((end_time - start_time))

echo "[ReconHunter] Scan finished in ${runtime}s"
