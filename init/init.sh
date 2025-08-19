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
# 可通过参数传入，如：
#   ./init.sh master_ips=192.168.100.41-192.168.100.43 \
#             cpu_worker_ips=192.168.100.44-192.168.100.50 \
#             gpu_worker_ips=192.168.100.60-192.168.100.61 \
#             ceph_ips=192.168.100.70-192.168.100.72
master_ips=()
cpu_worker_ips=()
gpu_worker_ips=()
ceph_ips=()
master_ipmi_ips=()
cpu_worker_ipmi_ips=()
gpu_worker_ipmi_ips=()
ceph_ipmi_ips=()
master_storage_ips=()
cpu_worker_storage_ips=()
gpu_worker_storage_ips=()
ceph_storage_ips=()
master_hns=()
cpu_worker_hns=()
gpu_worker_hns=()
ceph_hns=()

expand_ip_range() {
    local input="$1" part
    for part in $input; do
        if [[ $part =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            local start_ip=${BASH_REMATCH[1]}
            local end_ip=${BASH_REMATCH[2]}
            local prefix=${start_ip%.*}
            local start=${start_ip##*.}
            local end_prefix=${end_ip%.*}
            local end=${end_ip##*.}
            if [[ $prefix == $end_prefix ]]; then
                for i in $(seq $start $end); do
                    printf "%s " "${prefix}.${i}"
                done
            else
                printf "%s " "$part"
            fi
        elif [[ $part =~ ^([0-9]+\.[0-9]+\.[0-9]+\.)([0-9]+)-([0-9]+)$ ]]; then
            local prefix=${BASH_REMATCH[1]}
            local start=${BASH_REMATCH[2]}
            local end=${BASH_REMATCH[3]}
            for i in $(seq $start $end); do
                printf "%s " "${prefix}${i}"
            done
        else
            printf "%s " "$part"
        fi
    done
}

generate_entries() {
    local prefix=$1 ips_var=$2 ipmi_var=$3 storage_var=$4 hns_var=$5 entries_var=$6
    local -n ips=$ips_var
    local -n ipmi_ips=$ipmi_var
    local -n storage_ips=$storage_var
    local -n hostnames=$hns_var
    local -n entries=$entries_var
    hostnames=()
    entries=()
    for i in "${!ips[@]}"; do

        local suffix
        suffix=$(printf "%02d" $((i+1)))
        hostnames[i]="${prefix}${suffix}"
        local line="${hostnames[i]} ansible_host=${ips[i]}"
        if [[ -n ${ipmi_ips[i]:-} ]]; then
            line+=" ipmi_ip=${ipmi_ips[i]}"
        fi
        if [[ -n ${storage_ips[i]:-} ]]; then
            line+=" storage_ip=${storage_ips[i]}"
        fi
        entries[i]="$line"
    done
}

for arg in "$@"; do
    case $arg in
        master_ips=*) master_input=${arg#master_ips=};;
        cpu_worker_ips=*) cpu_worker_input=${arg#cpu_worker_ips=};;
        gpu_worker_ips=*) gpu_worker_input=${arg#gpu_worker_ips=};;
        ceph_ips=*) ceph_input=${arg#ceph_ips=};;
    esac
done

if [[ -z $master_input ]]; then
    read -p "请输入 master IPs (空格或范围): " master_input
fi
if [[ -z $cpu_worker_input ]]; then
    read -p "请输入 CPU worker IPs (空格或范围): " cpu_worker_input
fi
if [[ -z $gpu_worker_input ]]; then
    read -p "请输入 GPU worker IPs (空格或范围): " gpu_worker_input
fi
if [[ -z $ceph_input ]]; then
    read -p "请输入 Ceph IPs (空格或范围): " ceph_input
fi

read -a master_ips <<< "$(expand_ip_range "$master_input")"
read -a cpu_worker_ips <<< "$(expand_ip_range "$cpu_worker_input")"
read -a gpu_worker_ips <<< "$(expand_ip_range "$gpu_worker_input")"
read -a ceph_ips <<< "$(expand_ip_range "$ceph_input")"

read -p "请输入 master 带外 IPs (空格或范围): " master_ipmi_input
read -p "请输入 CPU worker 带外 IPs (空格或范围): " cpu_worker_ipmi_input
read -p "请输入 GPU worker 带外 IPs (空格或范围): " gpu_worker_ipmi_input

read -p "请输入 master 存储 IPs (空格或范围): " master_storage_input
read -p "请输入 CPU worker 存储 IPs (空格或范围): " cpu_worker_storage_input
read -p "请输入 GPU worker 存储 IPs (空格或范围): " gpu_worker_storage_input


read -a master_ipmi_ips <<< "$(expand_ip_range "$master_ipmi_input")"
read -a cpu_worker_ipmi_ips <<< "$(expand_ip_range "$cpu_worker_ipmi_input")"
read -a gpu_worker_ipmi_ips <<< "$(expand_ip_range "$gpu_worker_ipmi_input")"


read -a master_storage_ips <<< "$(expand_ip_range "$master_storage_input")"
read -a cpu_worker_storage_ips <<< "$(expand_ip_range "$cpu_worker_storage_input")"
read -a gpu_worker_storage_ips <<< "$(expand_ip_range "$gpu_worker_storage_input")"


read -p "请输入带外网关: " IPMI_GATEWAY
read -p "请输入带外掩码: " IPMI_NETMASK
read -p "请输入存储网关: " STORAGE_GATEWAY
read -p "请输入存储掩码: " STORAGE_NETMASK

# worker 节点 (CPU + GPU)
worker_ips=("${cpu_worker_ips[@]}" "${gpu_worker_ips[@]}")

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
# 合并 master 与 CPU worker 节点并生成唯一主机名
node_ips=()
node_ipmi=()
node_storage=()
for i in "${!master_ips[@]}"; do
    node_ips+=("${master_ips[i]}")
    node_ipmi+=("${master_ipmi_ips[i]:-}")
    node_storage+=("${master_storage_ips[i]:-}")
done
for i in "${!cpu_worker_ips[@]}"; do
    ip=${cpu_worker_ips[i]}
    if [[ ! " ${node_ips[*]} " =~ " ${ip} " ]]; then
        node_ips+=("$ip")
        node_ipmi+=("${cpu_worker_ipmi_ips[i]:-}")
        node_storage+=("${cpu_worker_storage_ips[i]:-}")
    fi
done
generate_entries node node_ips node_ipmi node_storage node_hns node_entries

# 构建 IP 映射到主机名及其他属性
declare -A ip_to_hn ip_to_ipmi ip_to_storage
for idx in "${!node_ips[@]}"; do
    ip=${node_ips[idx]}
    ip_to_hn[$ip]=${node_hns[idx]}
    if [[ -n ${node_ipmi[idx]} ]]; then ip_to_ipmi[$ip]=${node_ipmi[idx]}; fi
    if [[ -n ${node_storage[idx]} ]]; then ip_to_storage[$ip]=${node_storage[idx]}; fi
done

# 根据映射生成 master 与 CPU worker 组条目
master_entries=()
master_hns=()
for ip in "${master_ips[@]}"; do
    hn=${ip_to_hn[$ip]}
    master_hns+=("$hn")
    line="$hn ansible_host=$ip"
    if [[ -n ${ip_to_ipmi[$ip]:-} ]]; then line+=" ipmi_ip=${ip_to_ipmi[$ip]}"; fi
    if [[ -n ${ip_to_storage[$ip]:-} ]]; then line+=" storage_ip=${ip_to_storage[$ip]}"; fi
    master_entries+=("$line")
done
cpu_entries=()
cpu_worker_hns=()
for ip in "${cpu_worker_ips[@]}"; do
    hn=${ip_to_hn[$ip]}
    cpu_worker_hns+=("$hn")
    line="$hn ansible_host=$ip"
    if [[ -n ${ip_to_ipmi[$ip]:-} ]]; then line+=" ipmi_ip=${ip_to_ipmi[$ip]}"; fi
    if [[ -n ${ip_to_storage[$ip]:-} ]]; then line+=" storage_ip=${ip_to_storage[$ip]}"; fi
    cpu_entries+=("$line")
done

# GPU 节点保持原有命名
generate_entries gpu gpu_worker_ips gpu_worker_ipmi_ips gpu_worker_storage_ips gpu_worker_hns gpu_entries
if ! $ceph_children; then
    generate_entries ceph ceph_ips ceph_ipmi_ips ceph_storage_ips ceph_hns ceph_entries
fi

cat > /etc/ansible/hosts/hosts <<EOF
[k8s_master]
$(printf "%s\n" "${master_entries[@]}")

[k8s_cpu_worker]

$(printf "%s\n" "${cpu_entries[@]}")

[k8s_gpu_worker]
$(printf "%s\n" "${gpu_entries[@]}")

[k8s_worker:children]
k8s_cpu_worker
k8s_gpu_worker
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
$(printf "%s\n" "${ceph_entries[@]}")
EOF
fi

cat >> /etc/ansible/hosts/hosts <<EOF

[nfs_server]
${master_hns[0]}

[all:vars]
ansible_user=${ANSIBLE_USER}
ansible_ssh_pass=${ANSIBLE_PASS}
ansible_become=true
ansible_become_method=sudo
ansible_become_pass=${ANSIBLE_PASS}
ansible_python_interpreter=/usr/bin/python3
ipmi_gateway=${IPMI_GATEWAY}
ipmi_netmask=${IPMI_NETMASK}
storage_gateway=${STORAGE_GATEWAY}
storage_netmask=${STORAGE_NETMASK}
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
mysql_node: ${cpu_worker_hns[0]}
enable_cephadm: false
enable_rook_ceph: false
ceph_mon_ip: ${ceph_ips[0]}
ipmi_gateway: ${IPMI_GATEWAY}
ipmi_netmask: ${IPMI_NETMASK}
storage_gateway: ${STORAGE_GATEWAY}
storage_netmask: ${STORAGE_NETMASK}
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

for hn in "${master_hns[@]}"; do
    ansible "$hn" -i /etc/ansible/hosts/hosts -m shell \
      -a "hostnamectl set-hostname ${hn}" \
      -e "ansible_python_interpreter=/usr/bin/python3" \
      -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"
done
for hn in "${cpu_worker_hns[@]}"; do
    ansible "$hn" -i /etc/ansible/hosts/hosts -m shell \
      -a "hostnamectl set-hostname ${hn}" \
      -e "ansible_python_interpreter=/usr/bin/python3" \
      -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"
done
for hn in "${gpu_worker_hns[@]}"; do
    ansible "$hn" -i /etc/ansible/hosts/hosts -m shell \
      -a "hostnamectl set-hostname ${hn}" \
      -e "ansible_python_interpreter=/usr/bin/python3" \
      -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"
done
if ! $ceph_children; then
    for hn in "${ceph_hns[@]}"; do
        ansible "$hn" -i /etc/ansible/hosts/hosts -m shell \
          -a "hostnamectl set-hostname ${hn}" \
          -e "ansible_python_interpreter=/usr/bin/python3" \
          -e "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"
    done
fi

########################################
# 9. 完成
########################################

echo "初始化完成"
echo "HTTP 离线源: http://$(hostname -I | awk '{print $1}'):${HTTP_PORT}/"

