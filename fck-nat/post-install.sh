#!/bin/sh

echo "eni_id=${eni_id}" >> /etc/fck-nat.conf
echo "eip_id=${eip_id}" >> /etc/fck-nat.conf

systemctl enable fck-nat
systemctl start fck-nat
