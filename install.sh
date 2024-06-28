#!/bin/bash

if [ ! -f ".env" ]; then
    echo ".env file does not exist."
    exit
fi

source .env

# Varibales
export PUBLIC_IP=$(curl -4 -s ifconfig.me)

# SCRIPT SETUP
export PROJECT_PATH="$(dirname $(realpath "$0"))"
cd "$PROJECT_PATH" || exit

export PROJECT_CONFIGS="$PROJECT_PATH/configs"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

# UTILITY FUNCTIONS
export TERMINAL_COLUMNS="$(stty -a 2>/dev/null | grep -Po '(?<=columns )\d+' || echo 0)"

print_separator() {
    for ((i = 0; i < "$TERMINAL_COLUMNS"; i++)); do
        printf $1
    done
}

echo_run() {
    line_count=$(wc -l <<<$1)
    echo -n ">$(if [ ! -z ${2+x} ]; then echo "($2)"; fi)_ $(sed -e '/^[[:space:]]*$/d' <<<$1 | head -1 | xargs)"
    if (($line_count > 1)); then
        echo -n "(command truncated....)"
    fi
    echo
    if [ -z ${2+x} ]; then
        eval $1
    else
        FUNCTIONS=$(declare -pf)
        echo "$FUNCTIONS; $1" | sudo --preserve-env -H -u $2 bash
    fi
    print_separator "+"
    echo -e "\n"
}

function gcf() {
    export GCF_ED="$"
    envsubst <$1
}

function gcfc() {
    gcf $PROJECT_CONFIGS/$1
}

function certbot_domains_fix() {
    echo -n $(certbot certificates --cert-name $DOMAIN 2>/dev/null | grep Domains | cut -d':' -f2 | xargs | tr -s '[:blank:]' ',')
}

function certbot_expand_nginx() {
    OLD_DOMAINS=$(certbot_domains_fix)
    DOMAINS=""
    if [ ! -z $OLD_DOMAINS ]; then
        DOMAINS="$OLD_DOMAINS,$@"
    else
        DOMAINS="$@"
    fi
    echo_run "certbot --nginx --cert-name $DOMAIN -d $DOMAINS --email $CERTBOT_EMAIL --expand --agree-tos --noninteractive"
}

function get_subdomains() {
    echo -n $1 | awk -F. '{NF-=2} $1=$1' | tr -s '[:blank:]' '.'
}

function ln_nginx() {
    echo_run "ln -fs /etc/nginx/sites-available/$1.conf /etc/nginx/sites-enabled/"
}

# ACTIONS

server_initial_setup() {
    echo_run "apt update -y"
    echo_run "apt install -y nginx certbot python3-certbot-nginx"
    echo_run "apt full-upgrade -y"
    echo_run "apt autoremove -y"
    echo_run "sleep 5"
    echo_run "reboot"
}

install_ssl() {
    echo -e "Add the following DNS record to $(echo -n $DOMAIN | rev | cut -d"." -f1,2 | rev) DNS settings:"
    echo -e "\tType: A"
    echo -e "\tName: $(get_subdomains $TELEGRAM_DOMAIN)"
    echo -e "\tValue: $PUBLIC_IP"
    echo "Press enter to continue"
    echo_run "read"
    echo_run "systemctl stop nginx.service"
    echo_run "certbot certonly -d $TELEGRAM_DOMAIN --email $CERTBOT_EMAIL --standalone --agree-tos --noninteractive"
    echo_run "killall -9 nginx"
    echo_run "systemctl restart nginx"
}

install_telegram_nginx() {
    NGINX_CONFIG_FILENAME="$TELEGRAM_DOMAIN.conf"
    echo_run "gcfc telegram-proxy/nginx.conf > /etc/nginx/sites-available/$NGINX_CONFIG_FILENAME"
    ln_nginx $TELEGRAM_DOMAIN
    certbot_expand_nginx $TELEGRAM_DOMAIN
    echo_run "systemctl restart nginx"
    echo "URL: https://$TELEGRAM_DOMAIN"
    echo "When you open the URL, you should redirect to the Telegram bots documentation page."
}

create_telegram_proxy_user() {
    read -p "Enter username: " USERNAME
    read -p "Enter password: " PASSWORD
    echo_run "echo "$USERNAME:$(openssl passwd -6 $PASSWORD)" >> $TELEGRAM_AUTH_FILE"
}

ACTIONS=(
    server_initial_setup
    install_ssl
    install_telegram_nginx
    create_telegram_proxy_user
)

while true; do
    echo "Which action? $(if [ ! -z ${LAST_ACTION} ]; then echo "($LAST_ACTION)"; fi)"
    for i in "${!ACTIONS[@]}"; do
        echo -e "\t$((i + 1)). ${ACTIONS[$i]}"
    done
    read ACTION
    LAST_ACTION=$ACTION
    print_separator "-"
    $ACTION
    print_separator "-"
done
