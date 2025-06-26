#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

domain=$1
output_dir=recon_$domain
mkdir -p $output_dir

# ASCII Art
figlet ReconHunter 2>/dev/null || echo "==== ReconHunter ===="
echo "                        by Lakshay and Mansi"
echo "[*] Starting reconnaissance for: $domain"
echo "[*] Output directory: $output_dir"
echo

# Check if jq is installed
if ! command -v jq &>/dev/null; then
    echo "[!] 'jq' is not installed. Please install it to parse JSON from crt.sh"
    echo "    Example: sudo apt install jq"
    exit 1
fi

# ---------------------
# 1. Subdomain Enumeration
# ---------------------
echo "[+] Running Assetfinder..."
assetfinder --subs-only $domain >> $output_dir/subs_assetfinder.txt

echo "[+] Running Subfinder..."
subfinder -d $domain -silent >> $output_dir/subs_subfinder.txt

echo "[+] Running Findomain..."
findomain -t $domain -u $output_dir/subs_findomain.txt

echo "[+] Running crt.sh scraping..."
curl -s "https://crt.sh/?q=%25.$domain&output=json" | jq -r '.[].name_value' | sed 's/\*\.//g' | sort -u >> $output_dir/subs_crtsh.txt

echo "[+] Running Amass (passive)..."
amass enum -passive -d $domain -silent -o $output_dir/subs_amasspassive.txt

echo "[+] Running Amass (active)..."
amass enum -active -d $domain -silent -o $output_dir/subs_amassactive.txt

echo "[+] Merging and deduplicating subdomains..."
cat $output_dir/subs_*.txt | sort -u > $output_dir/all_subdomains.txt

# ---------------------
# 2. DNS Resolution
# ---------------------
echo "[+] Resolving live subdomains..."
dnsx -l $output_dir/all_subdomains.txt -silent -a -resp > $output_dir/resolved.txt

# ---------------------
# 3. HTTP Probing
# ---------------------
echo "[+] Probing live HTTP services..."
httpx-toolkit -l $output_dir/resolved.txt -silent > $output_dir/alive_http.txt

# ---------------------
# 4. Archive URL Gathering
# ---------------------
echo "[+] Gathering URLs from gau and waybackurls..."
if command -v getallurls &>/dev/null; then
    getallurls $domain >> $output_dir/urls_gau.txt
else
    echo "[!] gau not installed"
fi

if command -v waybackurls &>/dev/null; then
    echo $domain | waybackurls >> $output_dir/urls_wayback.txt
else
    echo "[!] waybackurls not installed"
fi

cat $output_dir/urls_*.txt 2>/dev/null | sort -u > $output_dir/all_urls.txt

# ---------------------
# 5. Parameter Discovery
# ---------------------
echo "[+] Running Arjun for parameter fuzzing..."
if [ -s $output_dir/alive_http.txt ]; then
    arjun -i $output_dir/alive_http.txt -m GET -oT $output_dir/arjun_params.txt 2>/dev/null
else
    echo "[!] Skipping Arjun – No alive HTTP hosts found."
fi

# ---------------------
# 6. Directory Bruteforcing (optional: uncomment to use)
# ---------------------
echo "[+] Running ffuf on alive subdomains..."
wordlist="/usr/share/wordlists/dirbuster/directory-list-2.3-medium.txt"
if [ ! -f "$wordlist" ]; then
    echo "[!] Wordlist not found: $wordlist"
else
    while read url; do
        ffuf -u $url/FUZZ -w $wordlist -t 40 -o $output_dir/ffuf_$(echo $url | cut -d/ -f3).json -of json
    done < $output_dir/alive_http.txt
fi

# ---------------------
# 7. Nuclei Vulnerability Scanning
# ---------------------
echo "[+] Scanning with Nuclei on alive http..."
nuclei -l $output_dir/alive_http.txt -o $output_dir/nuclei_output.txt
echo "[+] Scanning with Nuclei on all urls..."
nuclei -l $output_dir/all_urls.txt -o $output_dir/nuclei_urls.txt
# ---------------------
# Done
# ---------------------
echo "[✔] Recon complete! All output saved in: $output_dir"