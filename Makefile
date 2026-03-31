# =====================================================================
# 🌐 ZONE 1: 全局变量与环境配置 (Global Variables & Config)
# =====================================================================
PROJECT_NAME := sl-minetest-spot-on-server
AWS_REGION := us-east-1
ECR_REPO_NAME := $(PROJECT_NAME)-repo
CLUSTER_NAME := sl-minetest-cluster

# 自动获取 AWS 账号 ID 并拼接 ECR 完整地址
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text)
ECR_URI := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPO_NAME)

# CloudFormation 堆栈名称
CLOUDFORMATION_STACK_ECR := $(PROJECT_NAME)-ecr
CLOUDFORMATION_STACK_EFS := $(PROJECT_NAME)-efs
CLOUDFORMATION_STACK_VPC := $(PROJECT_NAME)-vpc
CLOUDFORMATION_STACK_EKS := $(PROJECT_NAME)-eks

# 使用 Git 的短哈希值作为不可变标签 (例如: a1b2c3d)
# 如果当前不在 git 仓库中，则默认回退到 'dev'
IMAGE_TAG := $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")

.PHONY: help build-image run-local clean deploy-vpc destroy-vpc deploy-eks check-eks destroy-eks deploy-ecr push-image deploy-k8s get-ip destroy-k8s deploy-efs deploy-all destroy-all

# =====================================================================
# 🏗️ ZONE 2: 底层基础设施即代码 (IaC: VPC, EKS, EFS)
# =====================================================================
help: ## 显示所有可用的 make 命令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'


build-image: ## 构建 Minetest 的 Docker 镜像
	@echo "Building Docker image with tag: $(IMAGE_TAG)..."
	docker build -t $(ECR_REPO_NAME):$(IMAGE_TAG) ./app/minetest-server

run-local: ## 在本地 WSL 运行容器进行测试
	@echo "Running Minetest server locally..."
	docker run -d --name local-minetest -p 30000:30000/udp $(ECR_REPO_NAME):$(IMAGE_TAG)

clean: ## 清理本地运行的容器
	@echo "Cleaning up local containers..."
	-docker stop local-minetest
	-docker rm local-minetest 

# =====================================================================
# 🏗️ ZONE 2: VPC 建造与部署
# =====================================================================
deploy-vpc: ## 使用 CloudFormation 部署生产级 VPC
	@echo "Deploying VPC stack to $(AWS_REGION)..."
	aws cloudformation deploy \
		--template-file ./infrastructure/cloudformation/vpc.yaml \
		--stack-name $(CLOUDFORMATION_STACK_VPC) \
		--region $(AWS_REGION) \
		--capabilities CAPABILITY_NAMED_IAM \
		--tags Project=$(PROJECT_NAME)

destroy-vpc: ## 销毁 VPC 环境 (节省成本！)
	@echo "Destroying VPC stack..."
	aws cloudformation delete-stack \
		--stack-name $(CLOUDFORMATION_STACK_VPC) \
		--region $(AWS_REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(CLOUDFORMATION_STACK_VPC) \
		--region $(AWS_REGION)
	@echo "VPC successfully destroyed."

# =====================================================================
# 🏗️ ZONE 3: EKS 建造与部署
# =====================================================================
deploy-eks: ## 部署 EKS 集群 (注意：创建 EKS 大约需要 15-20 分钟)
	@echo "Deploying EKS stack to $(AWS_REGION)..."
	aws cloudformation deploy \
		--template-file ./infrastructure/cloudformation/eks.yaml \
		--stack-name $(CLOUDFORMATION_STACK_EKS) \
		--region $(AWS_REGION) \
		--capabilities CAPABILITY_NAMED_IAM \
		--tags Project=$(PROJECT_NAME)
	@echo "Updating local kubeconfig..."
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME)
	@echo "EKS deployment complete! Try running: kubectl get nodes"

check-eks: ## 检查 EKS 集群状态
	@echo "Checking EKS cluster status..."
	kubectl get nodes

destroy-eks: ## 销毁 EKS 集群
	@echo "Destroying EKS stack..."
	aws cloudformation delete-stack \
		--stack-name $(CLOUDFORMATION_STACK_EKS) \
		--region $(AWS_REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(CLOUDFORMATION_STACK_EKS) \
		--region $(AWS_REGION)
	@echo "EKS successfully destroyed."

# =====================================================================
# 🏗️ ZONE 4: ECR 建造与部署
# =====================================================================
deploy-ecr: ## 部署 ECR 镜像仓库
	@echo "Deploying ECR stack..."
	aws cloudformation deploy \
		--template-file ./infrastructure/cloudformation/ecr.yaml \
		--stack-name $(CLOUDFORMATION_STACK_ECR) \
		--region $(AWS_REGION)

push-image: build-image ## 将本地镜像打标签并推送到 ECR
	@echo "Logging into Amazon ECR..."
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	@echo "Tagging image for ECR..."
	docker tag $(ECR_REPO_NAME):$(IMAGE_TAG) $(ECR_URI):$(IMAGE_TAG)
	@echo "Pushing image to ECR..."
	docker push $(ECR_URI):$(IMAGE_TAG)
	@echo "Image pushed successfully: $(ECR_URI):$(IMAGE_TAG)"

# =====================================================================
# 🏗️ ZONE 5: K8s 建造与部署
# =====================================================================
deploy-k8s: ## 部署游戏服务端到 EKS 集群 (带持久化存储)
	@echo "Fetching EFS ID from CloudFormation..."
	$(eval EFS_ID=$(shell aws cloudformation describe-stacks --stack-name $(CLOUDFORMATION_STACK_EFS) --query "Stacks[0].Outputs[?OutputKey=='FileSystemId'].OutputValue" --output text))
	@echo "Injecting EFS ID: $(EFS_ID) and Image URI: $(ECR_URI):$(IMAGE_TAG)"
	@sed -e 's|IMAGE_PLACEHOLDER|$(ECR_URI):$(IMAGE_TAG)|g' -e 's|EFS_ID_PLACEHOLDER|$(EFS_ID)|g' ./infrastructure/kubernetes/minetest.yaml | kubectl apply -f -
	@echo "Deployment applied! Waiting for AWS LoadBalancer..."

get-ip: ## 获取游戏服务器的公网连接地址
	@echo "Fetching Game Server IP..."
	@kubectl get svc minetest-service -o wide

install-csi-driver: ## 4. 为 K8s 安装 EFS 驱动 (翻译官)
	@echo "Installing AWS EFS CSI Driver..."
	kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=master"
	@echo "CSI Driver installed successfully!"

destroy-k8s: ## 从 EKS 卸载游戏服务并释放公网负载均衡器 (NLB)
	@echo "Deleting K8s resources and releasing AWS Load Balancer..."
	-kubectl delete -f ./infrastructure/kubernetes/minetest.yaml
	@echo "K8s resources deleted. (The '-' prefix ignores errors if already deleted)"

# =====================================================================
# 🏗️ ZONE 6: EFS 建造与部署
# =====================================================================
deploy-efs: ## 部署 EFS 弹性文件系统 (数据持久化)
	@echo "Deploying EFS stack for data persistence..."
	aws cloudformation deploy \
		--template-file ./infrastructure/cloudformation/efs.yaml \
		--stack-name $(CLOUDFORMATION_STACK_EFS) \
		--region $(AWS_REGION) \
		--parameter-overrides EnvironmentName=sl-minetest-prod
	@echo "EFS deployment complete!"

destroy-efs: ## 销毁 EFS 资源
	@echo "Destroying EFS stack..."
	aws cloudformation delete-stack \
		--stack-name $(CLOUDFORMATION_STACK_EFS) \
		--region $(AWS_REGION)
	aws cloudformation wait stack-delete-complete \
		--stack-name $(CLOUDFORMATION_STACK_EFS) \
		--region $(AWS_REGION)
	@echo "EFS successfully destroyed."

# =====================================================================
# 🏗️ ZONE 7: 一键部署/摧毁所有资源
# =====================================================================

# 部署顺序：网络 -> 仓库 -> 镜像 -> 存储 -> 集群 -> 驱动 -> 游戏
deploy-all: deploy-vpc deploy-ecr push-image deploy-efs deploy-eks install-csi-driver deploy-k8s ## 一键部署全部环境
	@echo "======================================================="
	@echo "🚀 [SUCCESS] 整个云端生产环境已全自动化部署完毕！"
	@echo "注意：由于 NLB 注册需要时间，请等待约 3-5 分钟后运行 'make get-ip'。"
	@echo "======================================================="

# 销毁顺序：游戏(释放NLB) -> 集群 -> 存储 -> 网络 (仓库通常保留以节省重复上传时间)
# 警告：必须先销毁 K8s 以确保负载均衡器(NLB)被删除，否则 VPC 将无法删除
destroy-all: destroy-k8s
	@echo "Waiting for Load Balancer to release (30s)..."
	@sleep 30
	$(MAKE) destroy-eks
	$(MAKE) destroy-efs
	$(MAKE) destroy-vpc
	@echo "======================================================="
	@echo "🗑️ [CLEANED] 所有计费资源已安全销毁！"
	@echo "提示：ECR 仓库已保留。若需完全抹除，请手动运行 'aws cloudformation delete-stack --stack-name $(CLOUDFORMATION_STACK_ECR)'"
	@echo "======================================================="