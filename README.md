## Alpine-php-V2
- 适用系统：**Alpine Linux**（轻量高效，专为小内存 VPS 优化）
- 集成组件：Caddy Web 服务器 + PHP 8.2 + SQLite 数据库 + V2 服务
- 优势：占用内存极低、部署速度快、配置简单，适合小型网站 / 个人项目
### 核心功能命令
```bash
# 追加新域名
./install.sh add
# 删除已配置域名
./install.sh del
# 查看已配置域名列表
./install.sh list
```
### Alpine-php-V2一键自动安装命令
```bash
wget -qO install.sh https://raw.githubusercontent.com/pc655/shell-sh/main/Alpine-php-V2/install.sh && chmod u+x install.sh && ./install.sh
```
### Alpine-Cps 自动安装命令
```bash
wget -qO install.sh https://raw.githubusercontent.com/pc655/shell-sh/main/Alpine-php-V2/install_cpsv.sh && chmod u+x install_cpsv.sh && ./install_cpsv.sh
```

---
### 星尘 Agent安装客户端脚本
```bash
wget -qO install_agent.sh https://raw.githubusercontent.com/pc655/shell-sh/main/Agent/install_agent.sh && chmod u+x install_agent.sh && ./install_agent.sh
```
