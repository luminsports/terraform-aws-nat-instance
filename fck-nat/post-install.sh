#!/bin/sh

echo "eni_id=${eni_id}" >> /etc/fck-nat.conf
echo "eip_id=${eip_id}" >> /etc/fck-nat.conf

systemctl enable fck-nat
systemctl start fck-nat

dnf install -y kpatch-dnf
dnf kernel-livepatch -y auto
dnf install -y kpatch-runtime
dnf update -y kpatch-runtime
systemctl enable kpatch.service && sudo systemctl start kpatch.service
dnf update -y --security
