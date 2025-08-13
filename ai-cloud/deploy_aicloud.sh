#!/bin/bash
set -e

# 定义变量
HELM_VERSION="v3.16.0"
VOLCANO_CHART="volcano-aicloud-0.0.1.tgz"
VENUS_CHART="venus-aicloud-0.0.1.tgz"
MASTER_IP=$(hostname -I | awk '{print $1}')

# 检查命令执行结果的函数
check_command() {
    if [ $? -ne 0 ]; then
        echo "错误: $1 执行失败"
        exit 1
    fi
}

# 安装Helm
echo "正在安装 Helm ${HELM_VERSION}..."
if [ ! -f "helm-${HELM_VERSION}-linux-amd64.tar.gz" ]; then
    echo "错误: helm安装包不存在"
    exit 1
fi
tar -zxvf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
cp linux-amd64/helm /usr/bin/
helm version
check_command "Helm安装"

# 部署存储类
echo "正在部署NFS客户端供应器..."
if [ ! -f "nfs-client-provisioner.yaml" ]; then
    echo "错误: nfs-client-provisioner.yaml文件不存在"
    exit 1
fi
sed -i "s/192.168.48.250/${MASTER_IP}/g" nfs-client-provisioner.yaml
kubectl apply -f nfs-client-provisioner.yaml
sleep 5
check_command "NFS客户端供应器部署"

# 部署监控组件
echo "正在部署监控组件..."
if ! kubectl get ns monitoring >/dev/null 2>&1; then
    kubectl create ns monitoring
    echo "已创建 monitoring 命名空间"
else
    echo "monitoring 命名空间已存在，跳过创建"
fi
for file in node-export.yaml metric-server.yaml kube-state-metrics.yaml; do
    if [ ! -f "$file" ]; then
        echo "错误: $file 文件不存在"
        exit 1
    fi
    kubectl apply -f $file
	sleep 5
    check_command "$file 部署"
done




# 部署Volcano AI Cloud
echo "正在部署Volcano AI Cloud..."
if [ ! -f "${VOLCANO_CHART}" ]; then
    echo "错误: ${VOLCANO_CHART} 文件不存在"
    exit 1
fi
tar -zxvf ${VOLCANO_CHART}
helm install volcano ./volcano-aicloud --namespace volcano-system --create-namespace
sleep 10
check_command "Volcano AI Cloud部署"

# 检查Volcano状态
echo "检查Volcano部署状态..."
helm status volcano --namespace volcano-system

# 重建证书Secret
echo "重建证书Secret..."
kubectl delete secret -n volcano-monitoring api-cert-secret etcd-cert-secret 2>/dev/null
kubectl create secret generic api-cert-secret \
    --from-file=apiserver-kubelet-client.crt=/etc/kubernetes/pki/apiserver-kubelet-client.crt \
    --from-file=apiserver-kubelet-client.key=/etc/kubernetes/pki/apiserver-kubelet-client.key \
    --from-file=ca.crt=/etc/kubernetes/pki/ca.crt -n volcano-monitoring
check_command "api-cert-secret创建"

kubectl create secret generic etcd-cert-secret \
    --from-file=ca.pem=/etc/ssl/etcd/ssl/ca.pem \
    --from-file=key.pem=/etc/ssl/etcd/ssl/admin-master-key.pem \
    --from-file=cert.pem=/etc/ssl/etcd/ssl/admin-master.pem -n volcano-monitoring
check_command "etcd-cert-secret创建"

# 部署Venus AI Cloud
echo "正在部署Venus AI Cloud..."
if [ ! -f "${VENUS_CHART}" ]; then
    echo "错误: ${VENUS_CHART} 文件不存在"
    exit 1
fi
tar -zxvf ${VENUS_CHART}
sed -i "s/10.8.0.56/${MASTER_IP}/g" ./venus-aicloud/values.yaml
helm install venus ./venus-aicloud --namespace venus --create-namespace
sleep 10
check_command "Venus AI Cloud部署"

# 检查Venus状态
echo "检查Venus部署状态..."
kubectl get all -n venus

# 输出登录信息
echo "=============================================="
echo "部署完成!"
echo "可以通过以下地址访问:"
echo "http://${MASTER_IP}:32000/"
echo "用户名: admin"
echo "密码: infrawaves"
echo "=============================================="

exit 0