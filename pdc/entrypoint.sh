#!/bin/bash
WORK_DIR="/opt/app"

LDAP_HOST="samba_ad"
LDAP_PORT=389
LDAP_URI="ldap://${LDAP_HOST}:${LDAP_PORT}"
LDAP_PASSWORD="p@ssword0"
LDAP_SAMBA_DOMAIN="MYSITE"
LDAP_DOMAIN_FQDN="mysite.example.com"
LDAP_ROOT_DN=$(sed -e 's/^/DC=/' -e 's/\./,DC=/g' <<< "$LDAP_DOMAIN_FQDN")
LDAP_ADMIN_USER="Administrator"
LDAP_ADMIN_DN="CN=${LDAP_ADMIN_USER},CN=Users,${LDAP_ROOT_DN}"
LDAP_LOWER_LIMIT_OF_UID_NUMBER=999
LDAP_DEFAULT_GID_NUMBER=513
LDAP_DOMAIN_OF_MAIL_ADDRESS="$LDAP_DOMAIN_FQDN"
LDAP_DEFAULT_CAMPANY_NAME="Nanigashi Corp"


main() {
    #cd "$WORK_DIR"
    #source .env

#    ${WORK_DIR}/docker/common/set_hosts.sh
#    ${WORK_DIR}/docker/common/set_resolver.sh

    local fqdn="${LDAP_HOST^^}.${LDAP_DOMAIN_OF_MAIL_ADDRESS}"
    local host_ip=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

    if [[ ! -f /etc/samba/external/smb.conf ]]; then

        [[ -f /etc/krb5.conf ]] && mv /etc/krb5.conf /etc/krb5.conf.org
        [[ -f /etc/samba/smb.conf ]] && mv /etc/samba/smb.conf /etc/samba/smb.conf.org

        # Add hostname
        host_ip=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        echo "${host_ip} $fqdn ${LDAP_HOST^^}" >> /etc/hosts

        samba-tool domain provision --use-rfc2307 --domain=${LDAP_SAMBA_DOMAIN} \
                --realm=${LDAP_DOMAIN_OF_MAIL_ADDRESS^^} --server-role=dc \
                --dns-backend=SAMBA_INTERNAL --adminpass=${LDAP_PASSWORD} --host-ip=${host_ip}

        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

        samba-tool domain passwordsettings set --complexity=off
        samba-tool domain passwordsettings set --history-length=0
        samba-tool domain passwordsettings set --min-pwd-age=0
        samba-tool domain passwordsettings set --max-pwd-age=0

        TAB=$'\t'
        sed -i "/\[global\]/a \
\\\twins support = yes\\n\
${TAB}template shell = /bin/bash\\n\
${TAB}winbind nss info = rfc2307\\n\
${TAB}password hash userPassword schemes = CryptSHA256 CryptSHA512
" /etc/samba/smb.conf

        sed -i '/^\s\+dns forwarder = .*/d' /etc/samba/smb.conf
        sed -i "/\[global\]/a \
    \\\tdns forwarder = 8.8.8.8\
" /etc/samba/smb.conf

        sed -i "/\[global\]/a \
    \\\tldap server require strong auth = no\
" /etc/samba/smb.conf

        echo "[supervisord]" > /etc/supervisor/conf.d/supervisord.conf
        echo "nodaemon=true" >> /etc/supervisor/conf.d/supervisord.conf
        echo "" >> /etc/supervisor/conf.d/supervisord.conf
        echo "[program:samba]" >> /etc/supervisor/conf.d/supervisord.conf
        echo "command=/usr/sbin/samba -i" >> /etc/supervisor/conf.d/supervisord.conf
        #echo "[program:health_server]" >> /etc/supervisor/conf.d/supervisord.conf
        #echo "command=node /opt/app/docker/ldap/health_server.js" >> /etc/supervisor/conf.d/supervisord.conf

        /usr/sbin/samba -D
        sync
        #add_dns_records || return 1
        create_groups
        create_users
        kill $(cat /var/run/samba/samba.pid)

        mkdir -p /etc/samba/external
        cp /etc/samba/smb.conf /etc/samba/external/smb.conf
    fi

    #if ! grep -q -F "$fqdn" /etc/hosts; then
    #    echo "s/${host_ip}//g" >> /etc/hosts
    #fi

    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
}

add_dns_records() {
    local ip
    local host_name
    local user
    local count=0
    local try_num=360
    local result=1
    read ip host_name < <(getent hosts ${RACK_HOST})
    user="$(echo $LDAP_ADMIN_DN | cut -d',' -f1 | cut -d'=' -f2)"

    while [[ $result -ne 0 ]] && [[ $try_num -gt $count ]]; do
        samba-tool dns add 127.0.0.1 ${LDAP_DOMAIN_OF_MAIL_ADDRESS} ${RACK_HOST} A ${ip} -U ${user} --password ${LDAP_PASSWORD}
        result=$?
        [[ $result -eq 0 ]] && break
        sleep 0.5
        (( ++count ))
    done

    [[ $result -ne 0 ]] && echo "ERROR: Failed to add DNS record" >&2

    return $result
}

create_groups() {
    local gid gidNumber displayName

    local count=0
    local try_num=360
    local result=1

    while IFS="," read gid gidNumber displayName; do
        result=1
        count=0
        while [[ $result -ne 0 ]] && [[ $try_num -gt $count ]]; do
            (( ++count ))
            echo "# Creating group $gid"
            # Check existence
            ldapsearch -x -LLL -o 'ldif-wrap=no' -H ldap://localhost:389 -w "${LDAP_PASSWORD}" \
                    -D "CN=Administrator,CN=Users,${LDAP_ROOT_DN}" \
                    -b "CN=${gid},CN=Users,${LDAP_ROOT_DN}" \
                    "(objectCategory=CN=Group,CN=Schema,CN=Configuration,${LDAP_ROOT_DN})" > /dev/null 2>&1
            result=$?

            if [[ $result -eq 255 ]]; then
                # Can't contact LDAP server (-1)
                echo "Can't contact LDAP server.[return code=${result}]"
                sleep 0.5
                continue
            elif [[ $result -ne 0 ]]; then
                # Create a new group if the group does not existed.
                echo "gid: $gid doesn't existed. It will be created.[return code=${result}]"
                samba-tool group add "$gid" || { sleep 0.5; continue; }
            else
                echo "gid: $gid has already existed.[return code=${result}]"
            fi

            ldapmodify -H ldap://localhost:389 -D "CN=Administrator,CN=Users,${LDAP_ROOT_DN}" -w "$LDAP_PASSWORD" << EOF2 || { sleep 0.5; continue; }
dn: CN=${gid},CN=Users,${LDAP_ROOT_DN}
changetype: modify
add: gidNumber
gidNumber: ${gidNumber}
-
add: displayName
displayName: ${displayName}
EOF2
        done

    done << EOF
Domain Admins,512,Domain Admins
Domain Users,513,Domain Users
Domain Guests,514,Domain Guests
Proper,1001,正社員
Leader,1002,リーダー
Development,1003,開発部
Management,1004,管理部
Sales,1005,営業部
Senior,1006,管理職
Hoge,1007,ほげ部
EOF
}

create_users() {
    sleep 1
    local number=1000
    local employeeNumber uid surname givenname description
    while IFS="," read employeeNumber uid surname givenname employeeType businessCategory description groups; do
        (( number++ ))
        echo "# Creating a user ${uid}"
        samba-tool user create ${uid} ${LDAP_PASSWORD} \
                --uid ${uid} \
                --use-username-as-cn \
                --uid-number ${number} \
                --surname "$surname" \
                --given-name "$givenname" \
                --gid-number 513 \
                --job-title "正社員" \
                --department "開発部" \
                --company "ほげ株式会社" \
                --mail-address "${uid}@${LDAP_DOMAIN_OF_MAIL_ADDRESS}" \
                --login-shell /bin/bash \
                --unix-home /home/${uid}

        while IFS=";" read group; do
            samba-tool group addmembers "$group" "$uid"
        done < <(sed 's/;/\n/g' <<< "$groups")

        ldapmodify -H ldap://localhost:389 -D "CN=Administrator,CN=Users,${LDAP_ROOT_DN}" -w "$LDAP_PASSWORD" << EOF2
dn: CN=${uid},CN=Users,${LDAP_ROOT_DN}
changetype: modify
add: employeeType
employeeType: ${employeeType}
-
add: employeeNumber
employeeNumber: ${employeeNumber}
-
add: description
description: ${description}
-
add: businessCategory
businessCategory: ${businessCategory}
-
replace: displayName
displayName: ${surname} ${givenname}
EOF2
    done << EOF
0001,taro-suzuki,鈴木,太郎,社長,会社,太郎の備考,Domain Admins;Proper;Leader;Senior
0002,jiro-tanaka,田中,次郎,部長,開発部,次郎の備考,Domain Admins;Proper;Development;Leader;Senior
0003,hanako-kato,加藤,花子,課長,管理部,花子の備考,Domain Admins;Proper;Management;Leader;Senior
0004,hayato-nohara,野原,勇人,係長,営業部,勇人の備考,Proper;Sales;Leader;Senior
0005,kento-shimamoto,島本,健人,主任,ほげ部,健人の備考,Proper;Hoge;Leader;Senior
0006,takashi-ugajin,宇賀神,貴,正社員,開発部,貴の備考,Proper;Development;Leader
0007,takafumi-kasagi,笠木,貴文,正社員,開発部,貴文の備考,Domain Admins;Proper;Development;Leader
0008,hidehiko-matsumi,松見,英彦,正社員,営業部,英彦の備考,Proper;Sales
0009,ren-komine,小嶺,蓮,派遣社員,管理部,蓮の備考,Management
0010,toshiharu-kitakaze,北風,利治,契約社員,開発部,利治の備考,Development
EOF

}

main "$@"
