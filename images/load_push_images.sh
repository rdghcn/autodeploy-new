#!/bin/bash

# 1. 创建Harbor项目
echo "Creating Harbor project..."
curl -k -X POST "https://harbor.local.clusters/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -u "admin:Harbor12345" \
  -d '{
    "project_name": "kubesphereio",
    "metadata": {
      "public": "true"
    }
  }'

curl -k -X POST "https://harbor.local.clusters/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -u "admin:Harbor12345" \
  -d '{
    "project_name": "library",
    "metadata": {
      "public": "true"
    }
  }'

# 检查项目是否创建成功
if [ $? -ne 0 ]; then
  echo "Warning: Failed to create project, it might already exist."
fi

# 2. 解压所有tar包
echo "Extracting tar files..."
for tar_file in *.tar; do
  echo "Extracting ${tar_file}..."
  docker load -i "${tar_file}"
done



# 定义镜像列表
images=(
  "harbor.local.clusters/library/nfs-subdir-external-provisioner:v4.0.2"
  
  # node-monitor.tar 内的镜像
  "harbor.local.clusters/kubesphereio/node-exporter:infiniband"
  "harbor.local.clusters/kubesphereio/metric-server:v0.7.2"
  "harbor.local.clusters/kubesphereio/kube-state-metrics:latest"
  
  # volcano-aicloud.tar 内的镜像
  "harbor.local.clusters/kubesphereio/vc-scheduler:v1.9.15"
  "harbor.local.clusters/kubesphereio/vc-controller-manager:v1.9.13"
  "harbor.local.clusters/kubesphereio/vc-webhook-manager:v1.9.2"
  "harbor.local.clusters/kubesphereio/grafana:latest"
  "harbor.local.clusters/kubesphereio/prometheus:v0.76.0"
  "harbor.local.clusters/kubesphereio/prometheus-config-reloader:v0.76.0"
  "harbor.local.clusters/kubesphereio/alertmanager:latest"
  
  # venus-aicloud.tar 内的基础镜像
  "harbor.local.clusters/kubesphereio/bill:v0.1.0-beta5"
  "harbor.local.clusters/kubesphereio/mysql:8.4"
  "harbor.local.clusters/kubesphereio/busybox:latest"
  "harbor.local.clusters/kubesphereio/filebeat:8.14.3"
  "harbor.local.clusters/kubesphereio/logstash:8.14.3"
  
  # machine.tar 内的镜像
  "harbor.local.clusters/kubesphereio/base-notebook:latest"
  "harbor.local.clusters/kubesphereio/code-server:latest"
  "harbor.local.clusters/kubesphereio/busybox:latest"
  "harbor.local.clusters/kubesphereio/skopeo-stable:latest"
  "harbor.local.clusters/kubesphereio/nerdctl:main"
  "harbor.local.clusters/kubesphereio/kaniko-executor:latest"
  "harbor.local.clusters/kubesphereio/default-custom-notebook:latest"
  
  # aicloud.tar 内的镜像
  "harbor.local.clusters/kubesphereio/aicloud-backend:v1.0.9-05211219"
  "harbor.local.clusters/kubesphereio/aicloud_dashboard:v1.0.9-05212220"

)

# 登录 Docker 仓库（如果需要认证）
 docker login -u admin -p Harbor12345 harbor.local.clusters

# 循环推送镜像
for image in "${images[@]}"; do
  echo "Pushing $image..."
  docker push "$image"
  
  # 检查推送是否成功
  if [ $? -eq 0 ]; then
    echo "Successfully pushed $image"
  else
    echo "Failed to push $image"
    exit 1
  fi
done

echo "All images pushed successfully!"
