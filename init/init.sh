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
ceph_ips=("192.168.100.44" "192.168.100.45" "192.168.100.46")

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
ceph_children=true
for ip in "${ceph_ips[@]}"; do
    if [[ ! " ${master_ips[*]} ${worker_ips[*]} " =~ " ${ip} " ]]; then
        ceph_children=false
        break
    fi
done

cat > /etc/ansible/hosts/hosts <<EOF
[k8s_master]
$(printf "%s\n" "${master_ips[@]}")

[k8s_worker]
$(printf "%s\n" "${master_ips[@]}")
$(printf "%s\n" "${worker_ips[@]}")
EOF

if $ceph_children; then
cat >> /etc/ansible/hosts/hosts <<EOF
[k8s_ceph:children]
k8s_master
k8s_worker
EOF
else
cat >> /etc/ansible/hosts/hosts <<EOF
[k8s_ceph]
$(printf "%s\n" "${ceph_ips[@]}")
EOF
fi

cat >> /etc/ansible/hosts/hosts <<EOF

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

cat << EOF > /etc/infranwaves/globals.yml
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
mysql_node: node01
enable_cephadm: false
enable_rook_ceph: false
ceph_mon_ip: ${ceph_ips[0]}
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
# 8. 设置主机名
########################################

declare -A host_map
for i in "${!master_ips[@]}"; do
    hn=$(printf "master%02d" $((i+1)))
    host_map[${master_ips[$i]}]=$hn
done
for i in "${!worker_ips[@]}"; do
    ip=${worker_ips[$i]}
    if [[ -z ${host_map[$ip]} ]]; then
        hn=$(printf "node%02d" $((i+1)))
        host_map[$ip]=$hn
    fi
done
if ! $ceph_children; then
    for i in "${!ceph_ips[@]}"; do
        ip=${ceph_ips[$i]}
        if [[ -z ${host_map[$ip]} ]]; then
            hn=$(printf "ceph%02d" $((i+1)))
            host_map[$ip]=$hn
        fi
    done
fi

for ip in "${!host_map[@]}"; do
    hn=${host_map[$ip]}
    ansible "$ip" -i /etc/ansible/hosts/hosts -m shell \
      -a "hostnamectl set-hostname ${hn}" \
      -e "ansible_python_interpreter=/usr/bin/python3" \
      -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"
done

########################################
# 9. 完成
########################################

echo "初始化完成"
echo "HTTP 离线源: http://$(hostname -I | awk '{print $1}'):${HTTP_PORT}/"

