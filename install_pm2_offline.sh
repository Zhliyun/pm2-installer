#!/bin/bash

# PM2 离线安装脚本
# 使用方法: ./install_pm2_offline.sh [tgz文件目录]

# 注意: 不使用 set -e，以便更好地处理错误

# 默认目录为当前目录
TGZ_DIR="${1:-.}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否有npm
check_npm() {
    if ! command -v npm &> /dev/null; then
        log_error "npm 未找到，请先安装 Node.js"
        exit 1
    fi
    log_info "npm 版本: $(npm --version)"
}

# 检查tgz文件目录
check_tgz_dir() {
    if [[ ! -d "$TGZ_DIR" ]]; then
        log_error "目录不存在: $TGZ_DIR"
        exit 1
    fi
    
    local tgz_count=$(find "$TGZ_DIR" -name "*.tgz" | wc -l)
    if [[ $tgz_count -eq 0 ]]; then
        log_error "在目录 $TGZ_DIR 中未找到 .tgz 文件"
        exit 1
    fi
    
    log_info "找到 $tgz_count 个 .tgz 文件"
}

# 创建临时工作目录
create_temp_dir() {
    TEMP_DIR=$(mktemp -d)
    log_info "创建临时目录: $TEMP_DIR"
    
    # 设置退出时清理
    trap "rm -rf $TEMP_DIR" EXIT
}

# 解析package.json获取依赖关系
parse_dependencies() {
    local tgz_file="$1"
    local extract_dir="$TEMP_DIR/$(basename "$tgz_file" .tgz)"
    
    # 解压到临时目录
    mkdir -p "$extract_dir"
    tar -xzf "$tgz_file" -C "$extract_dir" --strip-components=1 2>/dev/null || return 1
    
    # 读取package.json
    if [[ -f "$extract_dir/package.json" ]]; then
        # 提取包名和版本 - 只匹配第一个出现的name和version
        local name=$(grep -m1 '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$extract_dir/package.json" | sed 's/.*"\([^"]*\)".*/\1/')
        local version=$(grep -m1 '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$extract_dir/package.json" | sed 's/.*"\([^"]*\)".*/\1/')
        
        if [[ -n "$name" && -n "$version" ]]; then
            echo "$name@$version|$tgz_file"
        else
            echo "unknown|$tgz_file"
        fi
    else
        echo "unknown|$tgz_file"
    fi
    
    # 清理临时解压目录
    rm -rf "$extract_dir"
}

# 按依赖顺序排序
sort_by_dependencies() {
    local temp_mapping="$TEMP_DIR/package_mapping"
    local packages_list="$TEMP_DIR/packages_list"
    
    log_info "分析包依赖关系..."
    
    # 清空临时文件
    > "$temp_mapping"
    > "$packages_list"
    
    # 首先收集所有包信息
    while IFS= read -r -d '' tgz_file; do
        local info=$(parse_dependencies "$tgz_file")
        local pkg_name=$(echo "$info" | cut -d'|' -f1)
        local file_path=$(echo "$info" | cut -d'|' -f2-)
        
        # 将包名和文件路径写入临时文件
        echo "$pkg_name|$file_path" >> "$temp_mapping"
        echo "$pkg_name" >> "$packages_list"
    done < <(find "$TGZ_DIR" -name "*.tgz" -print0)
    
    # PM2应该最后安装
    local sorted_files=()
    local pm2_file=""
    local pm2_found=false
    
    while IFS='|' read -r pkg_name file_path; do
        # 确保文件路径不为空且文件存在
        if [[ -n "$file_path" && -f "$file_path" ]]; then
            if [[ "$pkg_name" == pm2@* ]] || [[ "$pkg_name" == "pm2" ]]; then
                pm2_file="$file_path"
                pm2_found=true
            else
                sorted_files+=("$file_path")
            fi
        fi
    done < "$temp_mapping"
    
    # PM2放在最后
    if [[ -n "$pm2_file" ]]; then
        sorted_files+=("$pm2_file")
    fi
    
    # 输出排序后的文件路径
    for file in "${sorted_files[@]}"; do
        echo "$file"
    done
}

# 安装单个tgz包
install_package() {
    local tgz_file="$1"
    local pkg_name=$(basename "$tgz_file" .tgz)
    
    echo -n -e "${GREEN}[INFO]${NC} 安装: $pkg_name ... "
    
    if npm install -g "$tgz_file" --no-audit --no-fund --silent >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 成功${NC}"
        return 0
    else
        echo -e "${YELLOW}✗ 失败，尝试强制安装...${NC}"
        if npm install -g "$tgz_file" --force --no-audit --no-fund --silent >/dev/null 2>&1; then
            log_info "✓ 强制安装成功: $pkg_name"
            return 0
        else
            log_error "✗ 安装失败: $pkg_name"
            return 1
        fi
    fi
}

# 验证PM2安装
verify_pm2() {
    log_info "验证 PM2 安装..."
    
    # 刷新PATH
    hash -r
    
    # 等待一秒让npm完成
    sleep 1
    
    if command -v pm2 &> /dev/null; then
        local pm2_version=$(pm2 --version 2>/dev/null || echo "unknown")
        log_info "✓ PM2 安装成功，版本: $pm2_version"
        
        # 测试基本功能
        if pm2 list &> /dev/null; then
            log_info "✓ PM2 功能正常"
        else
            log_warn "PM2 安装了但可能有问题"
        fi
        return 0
    else
        # 尝试直接使用npm全局路径
        local npm_global_path=$(npm root -g 2>/dev/null)
        if [[ -n "$npm_global_path" && -f "$npm_global_path/../bin/pm2" ]]; then
            log_info "✓ PM2 已安装在: $npm_global_path/../bin/pm2"
            log_info "建议将 $(dirname $(npm root -g))/bin 添加到 PATH"
            return 0
        else
            log_error "✗ PM2 未正确安装"
            return 1
        fi
    fi
}

# 主函数
main() {
    log_info "开始 PM2 离线安装..."
    log_info "tgz 文件目录: $TGZ_DIR"
    
    # 检查环境
    check_npm
    check_tgz_dir
    create_temp_dir
    
    # 获取排序后的包列表
    local sorted_files=$(sort_by_dependencies)
    
    # 检查是否获取到文件列表
    if [[ -z "$sorted_files" ]]; then
        log_error "未能获取到要安装的包文件列表"
        exit 1
    fi
    
    # 过滤空行后计算包数量
    local total_packages=$(echo "$sorted_files" | grep -v '^$' | wc -l)
    local installed=0
    local failed=0
    
    if [[ $total_packages -eq 0 ]]; then
        log_error "没有找到有效的包文件"
        exit 1
    fi
    
    log_info "开始安装 $total_packages 个包..."
    
    # 逐个安装
    while IFS= read -r tgz_file; do
        if [[ -n "$tgz_file" && -f "$tgz_file" ]]; then
            if install_package "$tgz_file"; then
                ((installed++))
            else
                ((failed++))
            fi
        fi
    done <<< "$sorted_files"
    
    # 安装结果
    log_info "安装完成: 成功 $installed 个，失败 $failed 个"
    
    # 验证PM2
    if verify_pm2; then
        log_info "🎉 PM2 离线安装完成！"
        echo
        echo "可以使用以下命令测试 PM2："
        echo "  pm2 --version"
        echo "  pm2 list"
    else
        log_error "PM2 安装可能存在问题"
        exit 1
    fi
}

# 显示帮助
show_help() {
    echo "PM2 离线安装脚本"
    echo
    echo "使用方法:"
    echo "  $0 [tgz文件目录]"
    echo
    echo "参数:"
    echo "  tgz文件目录    包含所有tgz文件的目录路径（默认为当前目录）"
    echo
    echo "示例:"
    echo "  $0                    # 使用当前目录的tgz文件"
    echo "  $0 ./packages         # 使用./packages目录的tgz文件"
    echo "  $0 /path/to/tgz       # 使用指定路径的tgz文件"
}

# 处理命令行参数
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac