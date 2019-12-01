FROM ubuntu:18.04
LABEL maintainer "Tsutomu Nakamura<tsuna.0x00@gmail.com>"

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y install \
        pkg-config attr acl samba smbclient ldap-utils \
        winbind libnss-winbind libpam-winbind \
        supervisor openvpn inetutils-ping \
        libpam-krb5 krb5-config krb5-user \
        python3 python3-pip \
    && apt-get clean

ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

