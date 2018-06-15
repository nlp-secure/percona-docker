#!/bin/bash

chown -R 1001 /var/lib/proxysql

/usr/bin/proxysql --initial -f -c /etc/proxysql.cnf