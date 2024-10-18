dnf install -y kpatch-dnf
dnf kernel-livepatch -y auto
dnf install -y kpatch-runtime
dnf upgrade -y kpatch-runtime
systemctl enable kpatch.service && sudo systemctl start kpatch.service
dnf upgrade -y --security
