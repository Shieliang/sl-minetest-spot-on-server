# 1. 极致轻量：使用 Alpine Linux 作为基础镜像
FROM alpine:3.19

# 2. 安装 Minetest 服务端以及用于下载游戏包的 curl 和 tar
RUN apk add --no-cache minetest-server curl tar

# 3. DevSecOps：创建非 root 用户和用户组
RUN addgroup -S minetestgroup && adduser -S minetestuser -G minetestgroup

# 4. 创建世界存档和游戏数据所需的目录
RUN mkdir -p /home/minetestuser/.minetest/worlds/world \
             /home/minetestuser/.minetest/games

# 5. 【新增修复】下载官方默认游戏包 (minetest_game) 并解压到正确位置
RUN curl -sL https://github.com/minetest/minetest_game/archive/refs/heads/master.tar.gz | \
    tar -xz -C /home/minetestuser/.minetest/games/ && \
    mv /home/minetestuser/.minetest/games/minetest_game-master /home/minetestuser/.minetest/games/minetest_game

# 6. 统一赋予普通用户权限
RUN chown -R minetestuser:minetestgroup /home/minetestuser/.minetest

# 7. 复制配置文件
COPY --chown=minetestuser:minetestgroup minetest.conf /home/minetestuser/.minetest/minetest.conf

# 8. 安全降级：切换到普通用户身份
USER minetestuser

# 9. 设置工作目录
WORKDIR /home/minetestuser

# 10. 声明暴露端口
EXPOSE 30000/udp

# 11. 【新增修复】启动命令增加 --gameid minetest_game，告诉引擎加载我们刚才下载的游戏数据
CMD ["minetestserver", "--config", "/home/minetestuser/.minetest/minetest.conf", "--world", "/home/minetestuser/.minetest/worlds/world", "--gameid", "minetest_game"]