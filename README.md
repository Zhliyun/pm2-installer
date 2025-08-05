# PM2 离线安装包

这是一个用于在没有互联网连接的环境中安装 PM2 进程管理器的离线安装包。该包包含了 PM2 及其所有依赖的 tgz 文件。

## 📋 项目结构

```
pm2-installer/
├── README.md                    # 本文档
├── install_pm2_offline.sh       # 安装脚本
└── packages/                    # tgz 包文件目录
    ├── pm2-6.0.8.tgz           # PM2 主包
    ├── commander-14.0.0.tgz     # 依赖包
    ├── chokidar-4.0.3.tgz      # 依赖包
    └── ...                      # 其他依赖包
```

## ⚙️ 系统要求

- **Node.js**: 需要预先安装 Node.js (推荐 v16 或更高版本)
- **npm**: Node.js 自带的包管理器
- **操作系统**: Linux/macOS/Windows (需要 Bash 环境)
- **权限**: 需要安装全局包的权限 (可能需要 sudo)

## 🚀 安装方法

### 基本使用

1. **下载或拷贝** 整个 `pm2-installer` 目录到目标服务器

2. **赋予执行权限**：
   ```bash
   chmod +x install_pm2_offline.sh
   ```

3. **运行安装脚本**：
   ```bash
   # 使用默认目录 (packages)
   ./install_pm2_offline.sh packages
   
   # 或者指定自定义目录
   ./install_pm2_offline.sh /path/to/tgz/files
   ```

### 高级用法

```bash
# 查看帮助信息
./install_pm2_offline.sh --help

# 使用 sudo 权限安装（如果需要）
sudo ./install_pm2_offline.sh packages
```

### 验证安装

安装完成后，可以通过以下命令验证：

```bash
# 检查 PM2 版本
pm2 --version

# 列出当前进程
pm2 list

# 测试启动一个应用
pm2 start app.js --name "test-app"
```

## 📦 制作 tgz 包的方法

如果您需要制作新的离线安装包或更新现有包，请按照以下步骤：

### 推荐方法：自动获取依赖 (推荐)

这是最简洁高效的方法，会自动获取 PM2 的所有依赖：

**前提条件**：
- 确保系统已安装 `jq` 工具用于解析 JSON
  ```bash
  # Ubuntu/Debian
  sudo apt-get install jq
  
  # CentOS/RHEL
  sudo yum install jq
  
  # macOS
  brew install jq
  ```

**执行步骤**：

1. **创建包目录**：
   ```bash
   mkdir packages
   cd packages
   ```

2. **自动下载 PM2 及其所有依赖**：
   ```bash
   # 下载 PM2 主包
   npm pack pm2
   
   # 自动获取并下载所有依赖
   npm pack $(npm view pm2 dependencies --json | jq -r 'keys[]')
   ```

3. **验证包的完整性**：
   ```bash
   ls -la packages/
   # 确保所有必要的 tgz 文件都存在
   ```

## 🛠️ 脚本功能特性

### 智能安装顺序
- 自动分析包依赖关系
- 按正确顺序安装依赖
- PM2 主包最后安装

### 错误处理
- 彩色日志输出 (绿色=成功, 黄色=警告, 红色=错误)
- 失败时自动尝试强制安装
- 详细的错误信息和建议

### 安全特性
- 自动清理临时文件
- 验证安装结果
- 检查环境要求

## 🔧 故障排除

### 常见问题

**1. "npm 未找到" 错误**
```bash
# 确保 Node.js 已安装
node --version
npm --version

# 如果未安装，请先安装 Node.js
# https://nodejs.org/
```

**2. 权限不足错误**
```bash
# 使用 sudo 权限
sudo ./install_pm2_offline.sh packages

# 或者配置 npm 全局目录
mkdir ~/.npm-global
npm config set prefix '~/.npm-global'
export PATH=~/.npm-global/bin:$PATH
```

**3. PM2 命令找不到**
```bash
# 检查 npm 全局目录
npm root -g

# 手动添加到 PATH
export PATH=$(npm root -g)/../bin:$PATH

# 永久添加到环境变量
echo 'export PATH=$(npm root -g)/../bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

**4. 包文件损坏或缺失**
```bash
# 验证 tgz 文件完整性
tar -tzf packages/pm2-*.tgz > /dev/null && echo "文件完整" || echo "文件损坏"

# 重新下载损坏的包
npm pack package-name
```

### 日志和调试

如果遇到问题，可以：

1. **查看详细输出**：脚本会显示每个包的安装状态
2. **检查临时目录**：安装失败时临时文件不会被删除
3. **手动安装**：可以手动运行 `npm install -g package.tgz` 来测试特定包

## 📝 更新指南

### 更新 PM2 版本

**推荐方法（自动更新）**：

1. **清空现有包文件**：
   ```bash
   rm -rf packages/*.tgz
   cd packages
   ```

2. **重新下载所有包**：
   ```bash
   # 下载最新版本的 PM2
   npm pack pm2@latest
   
   # 自动下载所有依赖
   npm pack $(npm view pm2@latest dependencies --json | jq -r 'keys[]')
   ```

3. **测试新版本**：
   ```bash
   cd ..
   ./install_pm2_offline.sh packages
   ```

**手动方法**：

1. **下载新版本的 PM2**：
   ```bash
   cd packages
   rm pm2-*.tgz
   npm pack pm2@latest
   ```

2. **检查并更新依赖**：
   ```bash
   # 查看依赖变化
   npm view pm2@latest dependencies
   
   # 下载有变化的依赖
   npm pack new-dependency-name
   ```

### 验证包完整性

更新后建议验证所有包：

1. **检查包文件**：
   ```bash
   ls -la packages/
   ```

2. **验证依赖关系**：
   ```bash
   # 检查 PM2 的当前依赖
   npm view pm2 dependencies --json | jq -r 'keys[]'
   
   # 对比本地包文件
   ls packages/*.tgz | sed 's/.*\///;s/-[0-9].*//' | sort
   ```

## 📞 支持

如果您遇到问题：

1. 确保 Node.js 版本兼容 (建议 v16+)
2. 检查所有 tgz 文件是否完整
3. 验证系统权限设置
4. 查看脚本输出的详细错误信息

## 📄 许可证

本项目基于 MIT 许可证发布。PM2 本身遵循其原始许可证条款。

---

**注意**: 此离线安装包适用于无法访问 npm 仓库的环境。在有网络连接的环境中，建议直接使用 `npm install -g pm2` 进行安装。