#!/bin/bash
set -e

echo "初始化开始"

########################################
# 0. 自动识别BASE目录 
########################################

BASE_DIR=$(cd $(dirname $0); pwd)
OFFLINE_DIR="${BASE_DIR}/all-deb"
REPO_DIR="${BASE_DIR}/repo"
HTTP_PORT=80

# 节点IP列表
master_ips=("192.168.100.41")
worker_ips=("192.168.100.42" "192.168.100.43")

# ansible用户及免密信息
ANSIBLE_USER="test"
ANSIBLE_PASS="1qaz@WSX"
ROOT_PASS="1qaz@WSX"

########################################
# 1. 安装全部离线包
########################################
apt remove -y systemd-timesyncd
cd "$OFFLINE_DIR"
dpkg -i *.deb || true
########################################
# 2. 配置 Apache HTTPD
########################################

sed -i "s|DocumentRoot /var/www/html|DocumentRoot ${REPO_DIR}|" /etc/apache2/sites-enabled/000-default.conf

# 加权限配置，避免 403
grep -q "${REPO_DIR}" /etc/apache2/apache2.conf || cat << EOF >> /etc/apache2/apache2.conf

<Directory ${REPO_DIR}/>
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF

systemctl enable apache2
systemctl restart apache2

########################################
# 3. 构建离线仓库目录
########################################

mkdir -p "$REPO_DIR"
cp "$OFFLINE_DIR"/*.deb "$REPO_DIR/"

########################################
# 4. 生成 APT 索引文件
########################################

dpkg -i "$OFFLINE_DIR"/dpkg-dev_*.deb || true

cd "$REPO_DIR"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
gzip -df Packages.gz  # 强制覆盖，避免交互

########################################
# 5. 配置 APT 源
########################################

echo "deb [trusted=yes] http://localhost:${HTTP_PORT}/ ./" > /etc/apt/sources.list.d/local-offline.list
apt update

########################################
# 6. 生成 Ansible 配置文件
########################################

mkdir -p /etc/ansible/hosts

cat << EOF > /etc/ansible/hosts/hosts
[k8s_master]
$(for ip in "${master_ips[@]}"; do echo "$ip"; done)

[k8s_worker]
$(for ip in "${worker_ips[@]}"; do echo "$ip"; done)

[nfs_server]
${master_ips[0]}

[all:vars]
ansible_user=${ANSIBLE_USER}
ansible_ssh_pass=${ANSIBLE_PASS}
ansible_become=true
ansible_become_method=sudo
ansible_become_pass=${ANSIBLE_PASS}
ansible_python_interpreter=/usr/bin/python3
EOF

mkdir -p /etc/infranwaves

cat << EOF > /etc/infranwaves/global.yml
offline_package_path: ${BASE_DIR}
nfs_server_ip: ${master_ips[0]}
enable_nfs: true
nfs_mount_path: /mnt/nfs
nfs_k8_path: /mnt/data
harbor_data_dir: /data
harbor_cert_dir: "{{ harbor_data_dir }}/harbor"
harbor_domain: harbor.local.clusters
harbor_ip: ${master_ips[0]}
harbor_user: admin
harbor_password: Harbor12345
k8s_version: v1.28.8
kubekey_version: v3.1.8
timezone: Asia/Shanghai
ntp_server: ${master_ips[0]}
mysql_node: node1
EOF

########################################
# 7. 生成 SSH密钥对 & 批量免密分发
########################################

if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
fi

ansible all -i /etc/ansible/hosts/hosts -m authorized_key \
  -a "user=root state=present key=\"$(cat /root/.ssh/id_rsa.pub)\"" \
  -e "ansible_python_interpreter=/usr/bin/python3" \
  -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"

########################################
# 8. 完成
########################################

echo "初始化完成"
echo "HTTP 离线源: http://$(hostname -I | awk '{print $1}'):${HTTP_PORT}/"

