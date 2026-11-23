# baserust-stack 常用命令。用法:just <目标>

# 基础设施容器 —— pg(+迁移)· minio(+建桶)· nats · dbhub。
# 后端 / 前端在本机手动起:baserust 里 just dev,basereact 里 pnpm dev(连接配置见各自 .env)。
infra_services := "pg migrate minio minio-init nats dbhub"

# 只起基础容器(改了迁移要重建 migrate 镜像:just infra --build)
infra *flags:
    docker compose up -d {{flags}} {{infra_services}}

# 整栈(含 app / idm / web / nginx)
up *flags:
    docker compose up -d --build {{flags}}

# 看状态
ps:
    docker compose ps -a

# 停掉(保留数据卷);连数据一起清用 just down -v
down *flags:
    docker compose down {{flags}}
