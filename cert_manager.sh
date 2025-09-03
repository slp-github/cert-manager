#!/bin/bash

# 域名证书管理面板
# 作者: slp
# 版本: 1.0
# 描述: 用于监控和管理SSL证书的状态，支持手动和自动续期功能

set -Eeuo pipefail

# 定义一个错误处理函数
handle_error() {
  local exit_code=$?
  local line_number=$1
  local command_string="${BASH_COMMAND}"
  echo "--- SCRIPT ERROR ---" >&2
  echo "命令: '${command_string}'" >&2
  echo "在文件: '${BASH_SOURCE[0]}' 的第 ${line_number} 行" >&2
  echo "以退出码 ${exit_code} 失败" >&2
  echo "--------------------" >&2
}

# 设置 trap，在 ERR 信号上调用 handle_error 函数
trap 'handle_error $LINENO' ERR


# 默认配置
DEFAULT_CERT_DIR="./cert-test"
DEFAULT_RENEW_SCRIPT="./ca_update"
DEFAULT_RELOAD_NGINX_SCRIPT="./reload-nginx"
LOG_DIR="./logs"
CONFIG_FILE="./config.conf"
AUTO_RENEW_CONFIG="./auto_renew.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BRIGHT_RED='\033[1;31m'
BRIGHT_GREEN='\033[1;32m'
BRIGHT_YELLOW='\033[1;33m'
BRIGHT_BLUE='\033[1;34m'
BRIGHT_PURPLE='\033[1;35m'
BRIGHT_CYAN='\033[1;36m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
NC='\033[0m' # No Color

# 全局变量
CERT_DIR="$DEFAULT_CERT_DIR"
RENEW_SCRIPT="$DEFAULT_RENEW_SCRIPT"
RELOAD_NGINX_SCRIPT="$DEFAULT_RELOAD_NGINX_SCRIPT"

# 检查Bash版本并初始化数组
if [[ ${BASH_VERSION%%.*} -ge 4 ]]; then
    declare -A DOMAIN_LIST
    declare -A CERT_INFO
    declare -A AUTO_RENEW_STATUS
    BASH_ARRAYS_SUPPORTED=true
else
    # 对于旧版本Bash，使用普通数组和文件存储
    BASH_ARRAYS_SUPPORTED=false
    DOMAIN_LIST_FILE="./domain_list.tmp"
    CERT_INFO_FILE="./cert_info.tmp"
fi

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" | tee -a "$LOG_DIR/cert_manager.log"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_DIR/cert_manager.log" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1" | tee -a "$LOG_DIR/cert_manager.log"
}

# 初始化函数
init_environment() {
    # 创建必要的目录
    mkdir -p "$LOG_DIR"
    
    # 加载配置文件
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "已加载配置文件: $CONFIG_FILE"
    fi
    
    # 检查证书目录
    if [[ ! -d "$CERT_DIR" ]]; then
        log_error "证书目录不存在: $CERT_DIR"
        exit 1
    fi
    
    # 检查续期脚本
    if [[ ! -f "$RENEW_SCRIPT" ]]; then
        log_error "续期脚本不存在: $RENEW_SCRIPT"
        exit 1
    fi

    # 检查Nginx重载脚本
    local reload_nginx_on_renew=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "reload_nginx_on_renew" 2>/dev/null || echo "true")
    if [[ "$reload_nginx_on_renew" == "true" && ! -x "$RELOAD_NGINX_SCRIPT" ]]; then
        log_warn "Nginx重载脚本不存在或不可执行: $RELOAD_NGINX_SCRIPT"
    fi
    
    # 加载自动续期配置
    load_auto_renew_config
}

# 兼容性函数：设置关联数组值
set_assoc_value() {
    local array_name="$1"
    local key="$2"
    local value="$3"
    
    if [[ "$BASH_ARRAYS_SUPPORTED" == "true" ]]; then
        case "$array_name" in
            "AUTO_RENEW_STATUS")
                AUTO_RENEW_STATUS["$key"]="$value"
                ;;
            "DOMAIN_LIST")
                DOMAIN_LIST["$key"]="$value"
                ;;
            "CERT_INFO")
                CERT_INFO["$key"]="$value"
                ;;
        esac
    else
        # 使用文件存储
        echo "${array_name}[${key}]=${value}" >> "./arrays.tmp"
    fi
}

# 兼容性函数：获取关联数组值
get_assoc_value() {
    local array_name="$1"
    local key="$2"
    
    if [[ "$BASH_ARRAYS_SUPPORTED" == "true" ]]; then
        case "$array_name" in
            "AUTO_RENEW_STATUS")
                echo "${AUTO_RENEW_STATUS[$key]:-}"
                ;;
            "DOMAIN_LIST")
                echo "${DOMAIN_LIST[$key]:-}"
                ;;
            "CERT_INFO")
                echo "${CERT_INFO[$key]:-}"
                ;;
        esac
    else
        # 从文件读取
        grep "^${array_name}\[${key}\]=" "./arrays.tmp" 2>/dev/null | cut -d= -f2- || echo ""
    fi
}

# 兼容性函数：获取所有数组键
get_assoc_keys() {
    local array_name="$1"
    
    if [[ "$BASH_ARRAYS_SUPPORTED" == "true" ]]; then
        case "$array_name" in
            "AUTO_RENEW_STATUS")
                printf '%s\n' "${!AUTO_RENEW_STATUS[@]}" 2>/dev/null || true
                ;;
            "DOMAIN_LIST")
                printf '%s\n' "${!DOMAIN_LIST[@]}" 2>/dev/null || true
                ;;
            "CERT_INFO")
                printf '%s\n' "${!CERT_INFO[@]}" 2>/dev/null || true
                ;;
        esac
    else
        # 从文件读取
        grep "^${array_name}\[" "./arrays.tmp" 2>/dev/null | sed "s/^${array_name}\[\([^]]*\)\]=.*/\1/" || true
    fi
}

# INI配置文件解析函数
parse_ini_config() {
    local config_file="$1"
    local section="$2"
    local key="$3"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    local in_section=false
    local result=""
    
    while IFS= read -r line; do
        # 去除前后空格
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 检查是否是section标题
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            local current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "$section" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi
        
        # 如果在目标section中，解析键值对
        if [[ "$in_section" == true && "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local config_key=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            local config_value=$(echo "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [[ "$config_key" == "$key" ]]; then
                echo "$config_value"
                return 0
            fi
        fi
    done < "$config_file"
    
    return 1
}

# 获取INI配置文件中所有键值对
get_ini_section_keys() {
    local config_file="$1"
    local section="$2"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    local in_section=false
    
    while IFS= read -r line; do
        # 去除前后空格
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 检查是否是section标题
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            local current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "$section" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi
        
        # 如果在目标section中，输出键名
        if [[ "$in_section" == true && "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local config_key=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            echo "$config_key"
        fi
    done < "$config_file"
}

# 加载自动续期配置 (INI格式)
load_auto_renew_config() {
    # 检查是否跳过配置文件完整性检查（用于兼容性）
    if [[ "${SKIP_CONFIG_CHECK:-false}" != "true" ]]; then
        # 首先检查和修复配置文件完整性
        monitor_config_integrity "$AUTO_RENEW_CONFIG"
    fi
    
    if [[ -f "$AUTO_RENEW_CONFIG" ]]; then
        # 读取auto_renew section中的所有域名配置
        for domain in $(get_ini_section_keys "$AUTO_RENEW_CONFIG" "auto_renew"); do
            local status=$(parse_ini_config "$AUTO_RENEW_CONFIG" "auto_renew" "$domain")
            if [[ -n "$status" ]]; then
                set_assoc_value "AUTO_RENEW_STATUS" "$domain" "$status"
            fi
        done
        
        log_info "已从INI配置文件加载自动续期设置"
    fi
}

# 更新INI配置文件中的键值对
update_ini_config() {
    local config_file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local temp_file="${config_file}.tmp"
    
    local in_section=false
    local key_updated=false
    
    # 如果配置文件不存在，创建基本结构
    if [[ ! -f "$config_file" ]]; then
        {
            echo "# 域名证书自动续期配置文件 (INI格式)"
            echo "# 配置每个域名的自动续期状态"
            echo "# 格式: 域名 = 状态(true/false)"
            echo ""
            echo "[auto_renew]"
            echo "# 域名自动续期开关配置"
            echo ""
            echo "[settings]"
            echo "# 全局设置"
            echo "default_auto_renew = true"
            echo "reload_nginx_on_renew = true"
            echo "renew_before_days = 7"
            echo "max_retry_count = 3"
        } > "$config_file"
    fi
    
    while IFS= read -r line; do
        # 检查是否是section标题
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            local current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "$section" ]]; then
                in_section=true
            else
                in_section=false
            fi
            echo "$line"
            continue
        fi
        
        # 如果在目标section中，检查是否需要更新键值对
        if [[ "$in_section" == true && "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local config_key=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [[ "$config_key" == "$key" ]]; then
                echo "$key = $value"
                key_updated=true
            else
                echo "$line"
            fi
        else
            echo "$line"
            
            # 如果刚离开目标section且键未更新，添加新键值对
            if [[ "$in_section" == false && "$key_updated" == false && "$line" =~ ^\[(.*)\]$ ]]; then
                local prev_section="${BASH_REMATCH[1]}"
                if [[ "$prev_section" != "$section" ]]; then
                    # 回到上一行，在正确的section中添加键值对
                    continue
                fi
            fi
        fi
    done < "$config_file" > "$temp_file"
    
    # 如果键未更新，在目标section末尾添加
    if [[ "$key_updated" == false ]]; then
        # 重新处理，在目标section末尾添加键值对
        local in_target_section=false
        local found_target_section=false
        rm -f "$temp_file"
        
        while IFS= read -r line; do
            # 检查是否是section标题
            if [[ "$line" =~ ^\[(.*)\]$ ]]; then
                local current_section="${BASH_REMATCH[1]}"
                
                # 如果之前在目标section中，现在离开了，添加新键值对
                if [[ "$in_target_section" == true && "$current_section" != "$section" ]]; then
                    echo "$key = $value"
                    in_target_section=false
                fi
                
                # 检查是否进入目标section
                if [[ "$current_section" == "$section" ]]; then
                    in_target_section=true
                    found_target_section=true
                else
                    in_target_section=false
                fi
            fi
            
            echo "$line"
        done < "$config_file" > "$temp_file"
        
        # 如果文件以目标section结尾，在文件末尾添加键值对
        if [[ "$in_target_section" == true ]]; then
            echo "$key = $value" >> "$temp_file"
        elif [[ "$found_target_section" == false ]]; then
            # 如果没有找到目标section，在文件末尾添加section和键值对
            {
                echo ""
                echo "[$section]"
                echo "$key = $value"
            } >> "$temp_file"
        fi
    fi
    
    mv "$temp_file" "$config_file"
}

# 保存自动续期配置 (INI格式)
save_auto_renew_config() {
    # 创建临时文件来重建配置
    local temp_file="${AUTO_RENEW_CONFIG}.tmp"
    
    {
        echo "# 域名证书自动续期配置文件 (INI格式)"
        echo "# 配置每个域名的自动续期状态"
        echo "# 格式: 域名 = 状态(true/false)"
        echo ""
        echo "[auto_renew]"
        echo "# 域名自动续期开关配置"
        
        # 添加所有域名的自动续期状态
        for domain in $(get_assoc_keys "AUTO_RENEW_STATUS" | sort); do
            local status=$(get_assoc_value "AUTO_RENEW_STATUS" "$domain")
            echo "$domain = $status"
        done
        
        echo ""
        echo "[settings]"
        echo "# 全局设置"
        
        # 保留现有的settings配置，如果存在的话
        if [[ -f "$AUTO_RENEW_CONFIG" ]]; then
            local default_auto_renew=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "default_auto_renew" 2>/dev/null || echo "true")
            local renew_before_days=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "renew_before_days" 2>/dev/null || echo "7")
            local max_retry_count=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "max_retry_count" 2>/dev/null || echo "3")
            local reload_nginx_on_renew=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "reload_nginx_on_renew" 2>/dev/null || echo "true")

            echo "default_auto_renew = $default_auto_renew"
            echo "renew_before_days = $renew_before_days"
            echo "max_retry_count = $max_retry_count"
            echo "reload_nginx_on_renew = $reload_nginx_on_renew"
        else
            echo "default_auto_renew = true"
            echo "reload_nginx_on_renew = true"
            echo "renew_before_days = 7"
            echo "max_retry_count = 3"
        fi
    } > "$temp_file"
    
    mv "$temp_file" "$AUTO_RENEW_CONFIG"
    log_info "自动续期配置已保存为INI格式"
}

# 扫描证书目录
scan_certificates() {
    local index=1
    
    # 清理临时文件
    [[ "$BASH_ARRAYS_SUPPORTED" == "false" ]] && rm -f "./arrays.tmp"
    
    log_info "开始扫描证书目录: $CERT_DIR"
    
    for cert_dir in "$CERT_DIR"/*/; do
        [[ ! -d "$cert_dir" ]] && continue
        
        local domain=$(basename "$cert_dir")
        local cert_file=""
        
        # 查找证书文件
        for ext in fullchain.pem cert.pem certificate.pem cert.crt certificate.crt; do
            if [[ -f "$cert_dir/$ext" ]]; then
                cert_file="$cert_dir/$ext"
                break
            fi
        done
        
        if [[ -z "$cert_file" ]]; then
            log_warn "域名 $domain 未找到有效的证书文件"
            continue
        fi
        
        # 解析证书信息
        if parse_certificate "$cert_file" "$domain" "$index"; then
            set_assoc_value "DOMAIN_LIST" "$index" "$domain"
            # 设置默认自动续期状态
            local current_status=$(get_assoc_value "AUTO_RENEW_STATUS" "$domain")
            if [[ -z "$current_status" ]]; then
                local default_auto_renew=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "default_auto_renew" 2>/dev/null || echo "true")
                set_assoc_value "AUTO_RENEW_STATUS" "$domain" "$default_auto_renew"
            fi
            ((++index))
        fi
    done
    
    log_info "证书扫描完成，共发现 $((index-1)) 个有效证书"
}

# 解析证书信息
parse_certificate() {
    local cert_file="$1"
    local domain="$2"
    local index="$3"
    
    if ! openssl x509 -in "$cert_file" -noout -dates &>/dev/null; then
        log_error "证书文件损坏或格式不正确: $cert_file"
        return 1
    fi
    
    local not_after
    not_after=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
    
    if [[ -z "$not_after" ]]; then
        log_error "无法解析证书到期时间: $cert_file"
        return 1
    fi
    
    # 转换日期格式 - 兼容macOS和Linux
    local expire_date
    local expire_timestamp
    local current_timestamp
    local days_left
    
    # 尝试不同的日期解析方法
    if command -v gdate &>/dev/null; then
        # macOS with GNU date (推荐)
        expire_date=$(gdate -d "$not_after" '+%Y-%m-%d' 2>/dev/null)
        if [[ -n "$expire_date" ]]; then
            expire_timestamp=$(gdate -d "$expire_date" '+%s')
            current_timestamp=$(gdate '+%s')
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux date
        expire_date=$(date -d "$not_after" '+%Y-%m-%d' 2>/dev/null)
        if [[ -n "$expire_date" ]]; then
            expire_timestamp=$(date -d "$expire_date" '+%s')
            current_timestamp=$(date '+%s')
        fi
    else
        # macOS native date - 需要特殊处理
        # 将 "Jul 19 23:43:57 2025 GMT" 格式转换
        local month_name=$(echo "$not_after" | awk '{print $1}')
        local day=$(echo "$not_after" | awk '{print $2}')
        local year=$(echo "$not_after" | awk '{print $4}')
        
        # 月份名称到数字的映射
        case "$month_name" in
            Jan) local month="01" ;;
            Feb) local month="02" ;;
            Mar) local month="03" ;;
            Apr) local month="04" ;;
            May) local month="05" ;;
            Jun) local month="06" ;;
            Jul) local month="07" ;;
            Aug) local month="08" ;;
            Sep) local month="09" ;;
            Oct) local month="10" ;;
            Nov) local month="11" ;;
            Dec) local month="12" ;;
            *) 
                log_error "无法识别的月份: $month_name"
                return 1
                ;;
        esac
        
        # 格式化日期 (避免八进制问题)
         expire_date=$(printf "%04d-%02d-%02d" "$year" "$((10#$month))" "$((10#$day))")
        
        # 计算时间戳 (macOS date)
        expire_timestamp=$(date -j -f "%Y-%m-%d" "$expire_date" "+%s" 2>/dev/null)
        current_timestamp=$(date "+%s")
    fi
    
    if [[ -z "$expire_date" || -z "$expire_timestamp" || -z "$current_timestamp" ]]; then
        log_error "日期格式转换失败: $not_after"
        return 1
    fi
    
    days_left=$(( (expire_timestamp - current_timestamp) / 86400 ))
    
    # 获取续期前天数设置
    local renew_before_days=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "renew_before_days" 2>/dev/null || echo "7")
    
    # 确定状态
    local status
    if [[ $days_left -le 0 ]]; then
        status="已过期"
    elif [[ $days_left -le 2 ]]; then
        status="警告"
    elif [[ $days_left -le $renew_before_days ]]; then
        status="即将过期"
    else
        status="正常"
    fi
    
    # 存储证书信息
    local cert_path="${domain}/$(basename "$cert_file")"
    set_assoc_value "CERT_INFO" "${index}_domain" "$domain"
    set_assoc_value "CERT_INFO" "${index}_expire_date" "$expire_date"
    set_assoc_value "CERT_INFO" "${index}_days_left" "$days_left"
    set_assoc_value "CERT_INFO" "${index}_status" "$status"
    set_assoc_value "CERT_INFO" "${index}_cert_path" "$cert_path"
    
    return 0
}

# 显示证书状态统计信息
# 参数: $1 - 是否显示统计 (true/false，可选，默认从配置读取)
show_certificate_statistics() {
    local show_stats="${1:-}"
    
    # 如果没有指定参数，从配置文件读取
    if [[ -z "$show_stats" ]]; then
        show_stats=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "show_statistics" 2>/dev/null || echo "true")
    fi
    
    # 检查是否启用统计显示
    if [[ "$show_stats" != "true" ]]; then
        return 0
    fi
    
    # 统计各种状态的证书数量
    local total_count=0
    local normal_count=0
    local warning_count=0
    local expired_count=0
    local soon_expire_count=0
    
    for index in $(get_assoc_keys "DOMAIN_LIST"); do
        local status=$(get_assoc_value "CERT_INFO" "${index}_status")
        ((++total_count))
        case "$status" in
            "正常") ((++normal_count)) ;;
            "警告") ((++warning_count)) ;;
            "已过期") ((++expired_count)) ;;
            "即将过期") ((++soon_expire_count)) ;;
        esac
    done
    
    # 显示统计信息
    echo -e "${BOLD}📊 证书状态统计:${NC}"
    echo -e "  ${BRIGHT_GREEN}✅ 正常: $normal_count${NC}  ${BRIGHT_YELLOW}🟡 即将过期: $soon_expire_count${NC}  ${RED}🔴 警告: $warning_count${NC}  ${BRIGHT_RED}⚠️  已过期: $expired_count${NC}  ${CYAN}📋 总计: $total_count${NC}"
    echo
}

# 显示证书状态表格
display_certificates() {
    clear
    echo -e "${BRIGHT_BLUE}${BOLD}=== 域名证书管理面板 ===${NC}"
    echo
    
    # 表格头 - 使用加粗和下划线
    echo -e "${BOLD}${UNDERLINE}"
    printf "%-4s %-27s %-13s %-15s %-10s %-8s %-32s\n" \
        "序号" "域名" "到期时间" "剩余天数" "状态" "自动续期" "证书位置"
    echo -e "${NC}"
    echo "$(printf '%*s' 100 '' | tr ' ' '=')"
    
    # 表格内容
    for index in $(get_assoc_keys "DOMAIN_LIST" | sort -n); do
        local domain=$(get_assoc_value "DOMAIN_LIST" "$index")
        local expire_date=$(get_assoc_value "CERT_INFO" "${index}_expire_date")
        local days_left=$(get_assoc_value "CERT_INFO" "${index}_days_left")
        local status=$(get_assoc_value "CERT_INFO" "${index}_status")
        local cert_path=$(get_assoc_value "CERT_INFO" "${index}_cert_path")
        local auto_renew=$(get_assoc_value "AUTO_RENEW_STATUS" "$domain")
        [[ -z "$auto_renew" ]] && auto_renew="false"
        
        # 状态颜色 - 增强颜色效果
        local status_color="$NC"
        local status_display="$status"
        case "$status" in
            "已过期") 
                status_color="$BRIGHT_RED$BOLD"
                status_display="⚠️  已过期"
                ;;
            "警告") 
                status_color="$RED$BOLD"
                status_display="🔴 警告"
                ;;
            "即将过期") 
                status_color="$BRIGHT_YELLOW$BOLD"
                status_display="🟡 即将过期"
                ;;
            "正常") 
                status_color="$BRIGHT_GREEN$BOLD"
                status_display="✅ 正常"
                ;;
        esac
        
        # 剩余天数颜色
        local days_color="$NC"
        if [[ $days_left -le 0 ]]; then
            days_color="$BRIGHT_RED$BOLD"
        elif [[ $days_left -le 2 ]]; then
            days_color="$RED$BOLD"
        elif [[ $days_left -le 7 ]]; then
            days_color="$YELLOW$BOLD"
        elif [[ $days_left -le 30 ]]; then
            days_color="$CYAN"
        else
            days_color="$GREEN"
        fi
        
        # 自动续期显示 - 增加颜色
        local auto_renew_display
        local auto_renew_color
        if [[ "$auto_renew" == "true" ]]; then
            auto_renew_display="✓ 是"
            auto_renew_color="$BRIGHT_GREEN"
        else
            auto_renew_display="✗ 否"
            auto_renew_color="$RED"
        fi
        
        # 域名颜色 - 根据状态调整
        local domain_color="$WHITE"
        case "$status" in
            "已过期"|"警告") domain_color="$BRIGHT_RED" ;;
            "即将过期") domain_color="$BRIGHT_YELLOW" ;;
            "正常") domain_color="$BRIGHT_CYAN" ;;
        esac
        
        printf "${BOLD}%-4s${NC} ${domain_color}%-25s${NC} ${CYAN}%-12s${NC} ${days_color}%-8s${NC} ${status_color}%-12s${NC} ${auto_renew_color}%-8s${NC} ${PURPLE}%-30s${NC}\n" \
            "$index" "$domain" "$expire_date" "$days_left" "$status_display" "$auto_renew_display" "$cert_path"
    done
    
    echo
    echo "$(printf '%*s' 100 '' | tr ' ' '-')"
    echo
    echo -e "${BRIGHT_BLUE}${BOLD}📋 操作指令:${NC}"
    echo -e "  ${BRIGHT_GREEN}s + [序号]${NC} - 🔄 手动续期指定域名"
    echo -e "  ${BRIGHT_GREEN}a${NC}          - 🚀 自动续期所有需要续期的域名"
    echo -e "  ${BRIGHT_CYAN}r${NC}          - 🔃 刷新显示"
    echo -e "  ${BRIGHT_YELLOW}t + [序号]${NC} - ⚙️  切换自动续期开关"
    echo -e "  ${BRIGHT_BLUE}h${NC}          - ❓ 显示帮助"
    echo -e "  ${BRIGHT_RED}q${NC}          - 🚪 退出程序"
    echo
    
    # 显示状态统计（可选）
    show_certificate_statistics
}

# 显示帮助信息
show_help() {
    clear
    echo -e "${BRIGHT_BLUE}${BOLD}=== 域名证书管理面板帮助 ===${NC}"
    echo
    echo -e "${BOLD}📖 使用方法:${NC}"
    echo -e "  ${CYAN}$0 [选项]${NC}"
    echo
    echo -e "${BOLD}⚙️  命令行选项:${NC}"
    echo -e "  ${BRIGHT_GREEN}--auto-renew${NC}    🚀 执行自动续期后退出"
    echo -e "  ${BRIGHT_GREEN}--cert-dir DIR${NC}  📁 指定证书目录 (默认: ${YELLOW}$DEFAULT_CERT_DIR${NC})"
    echo -e "  ${BRIGHT_GREEN}--renew-script${NC}  📜 指定续期脚本 (默认: ${YELLOW}$DEFAULT_RENEW_SCRIPT${NC})"
    echo -e "  ${BRIGHT_GREEN}-h, --help${NC}      ❓ 显示此帮助信息"
    echo
    echo -e "${BOLD}🎮 交互式命令:${NC}"
    echo -e "  ${BRIGHT_CYAN}s[序号]${NC}  - 🔄 为指定序号的域名执行手动续期"
    echo -e "  ${BRIGHT_CYAN}a${NC}        - 🚀 为所有启用自动续期且需要续期的域名执行续期"
    echo -e "  ${BRIGHT_CYAN}r${NC}        - 🔃 刷新显示当前状态"
    echo -e "  ${BRIGHT_CYAN}t[序号]${NC}  - ⚙️  切换指定域名的自动续期开关"
    echo -e "  ${BRIGHT_CYAN}q${NC}        - 🚪 退出程序"
    echo -e "  ${BRIGHT_CYAN}h${NC}        - ❓ 显示帮助信息"
    echo
    echo -e "${BOLD}📊 状态说明:${NC}"
    echo -e "  ${BRIGHT_GREEN}✅ 正常${NC}     - 剩余天数 > 配置的续期前天数"
    echo -e "  ${BRIGHT_YELLOW}🟡 即将过期${NC} - 剩余天数 3-配置的续期前天数"
    echo -e "  ${RED}🔴 警告${NC}     - 剩余天数 1-2天"
    echo -e "  ${BRIGHT_RED}⚠️  已过期${NC}   - 剩余天数 ≤ 0"
    echo
    echo -e "${BOLD}📋 INI配置文件说明:${NC}"
    echo -e "  ${PURPLE}[auto_renew]${NC} - 域名自动续期开关配置"
    echo -e "  ${PURPLE}[settings]${NC}   - 全局设置"
    echo -e "    ${CYAN}default_auto_renew${NC} - 新域名默认自动续期状态 (${YELLOW}true/false${NC})"
    echo -e "    ${CYAN}renew_before_days${NC}  - 续期前天数阈值 (默认${YELLOW}7天${NC})"
    echo -e "    ${CYAN}max_retry_count${NC}    - 最大重试次数 (默认${YELLOW}3次${NC})"
    echo -e "    ${CYAN}show_statistics${NC}    - 是否显示证书状态统计 (${YELLOW}true/false${NC}，默认${YELLOW}true${NC})"
    echo -e "    ${CYAN}reload_nginx_on_renew${NC} - 续期后是否重载Nginx (${YELLOW}true/false${NC}，默认${YELLOW}true${NC})"
    echo
    echo -e "${BOLD}⏰ Cron定时任务示例:${NC}"
    echo -e "  ${GREEN}# 每天凌晨2点执行自动续期检查${NC}"
    echo -e "  ${BRIGHT_YELLOW}0 2 * * * /path/to/cert_manager.sh --auto-renew${NC}"
    echo
    echo -e "${BOLD}按任意键返回主界面...${NC}"
    read -r
}

# 执行续期操作
renew_certificate() {
    local domain="$1"
    local show_progress="${2:-true}"

    if [[ "$show_progress" == "true" ]]; then
        echo -e "${YELLOW}正在为域名 $domain 执行续期操作...${NC}"
    fi

    log_info "开始续期域名: $domain"

    # 执行续期脚本
    if "$RENEW_SCRIPT" renew "$domain" 2>&1 | tee -a "$LOG_DIR/renew_${domain}_$(date +%Y%m%d_%H%M%S).log"; then
        log_info "域名 $domain 续期成功"
        if [[ "$show_progress" == "true" ]]; then
            echo -e "${GREEN}域名 $domain 续期成功!${NC}"
        fi

        return 0
    else
        log_error "域名 $domain 续期失败"
        if [[ "$show_progress" == "true" ]]; then
            echo -e "${RED}域名 $domain 续期失败!${NC}"
        fi
        return 1
    fi
}

# 重载Nginx
reload_nginx() {
    local reload_nginx_on_renew=$(parse_ini_config "$AUTO_RENEW_CONFIG" "settings" "reload_nginx_on_renew" 2>/dev/null || echo "true")

    if [[ "$reload_nginx_on_renew" == "true" ]]; then
        if [[ -x "$RELOAD_NGINX_SCRIPT" ]]; then
            log_info "开始重载Nginx..."
            if "$RELOAD_NGINX_SCRIPT"; then
                log_info "Nginx重载成功"
                echo -e "${GREEN}Nginx重载成功!${NC}"
            else
                log_error "Nginx重载失败"
                echo -e "${RED}Nginx重载失败!${NC}"
            fi
        else
            log_warn "Nginx重载脚本不存在或不可执行: $RELOAD_NGINX_SCRIPT"
        fi
    fi
}

# 手动续期
manual_renew() {
    local index="$1"
    
    local domain=$(get_assoc_value "DOMAIN_LIST" "$index")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}错误: 无效的序号 $index${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}确认要为域名 $domain 执行续期操作吗? (y/N)${NC}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if renew_certificate "$domain"; then
            reload_nginx
        fi
        echo "按任意键继续..."
        read -r
    else
        echo "操作已取消"
    fi
}

# 自动续期所有需要续期的域名
auto_renew_all() {
    local renewed_count=0
    local failed_count=0
    local show_progress="${1:-true}"
    
    if [[ "$show_progress" == "true" ]]; then
        echo -e "${BLUE}开始执行自动续期检查...${NC}"
    fi
    
    for index in $(get_assoc_keys "DOMAIN_LIST"); do
        local domain=$(get_assoc_value "DOMAIN_LIST" "$index")
        local status=$(get_assoc_value "CERT_INFO" "${index}_status")
        local auto_renew=$(get_assoc_value "AUTO_RENEW_STATUS" "$domain")
        [[ -z "$auto_renew" ]] && auto_renew="false"
        
        # 检查是否需要续期
        if [[ "$auto_renew" == "true" ]] && [[ "$status" =~ ^(即将过期|已过期|警告)$ ]]; then
            if [[ "$show_progress" == "true" ]]; then
                echo "处理域名: $domain (状态: $status)"
            fi
            
            if renew_certificate "$domain" "$show_progress"; then
                ((++renewed_count))
            else
                ((++failed_count))
            fi
        fi
    done
    
    if [[ "$show_progress" == "true" ]]; then
        echo
        echo -e "${BLUE}自动续期完成:${NC}"
        echo "  成功续期: $renewed_count 个域名"
        echo "  续期失败: $failed_count 个域名"
        
        if [[ $renewed_count -gt 0 || $failed_count -gt 0 ]]; then
            echo "按任意键继续..."
            read -r < /dev/tty
        fi
    fi
    
    if [[ $renewed_count -gt 0 ]]; then
        reload_nginx
    fi

    log_info "自动续期完成: 成功 $renewed_count 个, 失败 $failed_count 个"
}

# 配置文件完整性检查和修复函数
validate_and_repair_config() {
    local config_file="$1"
    local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # 创建备份
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "$backup_file"
        log_info "配置文件已备份到: $backup_file"
    fi
    
    # 检查并修复配置文件
    local temp_file="${config_file}.repair.tmp"
    local in_auto_renew_section=false
    # 兼容性改进：更安全的数组初始化
    declare -a seen_domains
    seen_domains=()
    
    {
        echo "# 域名证书自动续期配置文件 (INI格式)"
        echo "# 配置每个域名的自动续期状态"
        echo "# 格式: 域名 = 状态(true/false)"
        echo ""
        echo "[auto_renew]"
        echo "# 域名自动续期开关配置"
        
        # 处理auto_renew section，去重和验证
        if [[ -f "$config_file" ]]; then
            while IFS= read -r line; do
                # 检查section
                if [[ "$line" =~ ^\[(.*)\]$ ]]; then
                    local section="${BASH_REMATCH[1]}"
                    if [[ "$section" == "auto_renew" ]]; then
                        in_auto_renew_section=true
                        continue
                    else
                        in_auto_renew_section=false
                        break
                    fi
                fi
                
                # 处理auto_renew section中的配置
                if [[ "$in_auto_renew_section" == true && "$line" =~ ^([^=]+)=(.*)$ ]]; then
                    local domain=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    local value=$(echo "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    
                    # 验证域名格式和值
                    if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && [[ "$value" =~ ^(true|false)$ ]]; then
                        # 检查是否已经处理过这个域名（兼容性改进）
                        local already_seen=false
                        local array_length=${#seen_domains[@]:-0}
                        
                        if [[ $array_length -gt 0 ]]; then
                            for seen_domain in "${seen_domains[@]}"; do
                                if [[ "$seen_domain" == "$domain" ]]; then
                                    already_seen=true
                                    break
                                fi
                            done
                        fi
                        
                        if [[ "$already_seen" == false ]]; then
                            echo "$domain = $value"
                            seen_domains+=("$domain")
                        fi
                    fi
                fi
            done < "$config_file"
        fi
        
        echo ""
        echo "[settings]"
        echo "# 全局设置"
        
        # 保留settings section
        if [[ -f "$config_file" ]]; then
            local default_auto_renew=$(parse_ini_config "$config_file" "settings" "default_auto_renew" 2>/dev/null || echo "true")
            local renew_before_days=$(parse_ini_config "$config_file" "settings" "renew_before_days" 2>/dev/null || echo "7")
            local max_retry_count=$(parse_ini_config "$config_file" "settings" "max_retry_count" 2>/dev/null || echo "3")
            
            echo "default_auto_renew = $default_auto_renew"
            echo "renew_before_days = $renew_before_days"
            echo "max_retry_count = $max_retry_count"
        else
            echo "default_auto_renew = true"
            echo "reload_nginx_on_renew = true"
            echo "renew_before_days = 7"
            echo "max_retry_count = 3"
            echo "show_statistics = false"
        fi
    } > "$temp_file"
    
    mv "$temp_file" "$config_file"
    log_info "配置文件已修复和清理"
}

# 配置文件监控和自动修复
monitor_config_integrity() {
    local config_file="$1"
    
    # 检查文件是否存在
    if [[ ! -f "$config_file" ]]; then
        log_warn "配置文件不存在，将创建默认配置"
        validate_and_repair_config "$config_file"
        return
    fi
    
    # 检查文件格式
    local has_auto_renew_section=false
    local has_settings_section=false
    local line_count=0
    local invalid_lines=0
    
    while IFS= read -r line; do
        ((++line_count))
        
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # 检查section
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            local section="${BASH_REMATCH[1]}"
            [[ "$section" == "auto_renew" ]] && has_auto_renew_section=true
            [[ "$section" == "settings" ]] && has_settings_section=true
            continue
        fi
        
        # 检查键值对格式
        if [[ ! "$line" =~ ^[^=]+=.+$ ]]; then
            ((++invalid_lines))
        fi
    done < "$config_file"
    
    # 如果发现问题，自动修复（优化检查条件）
    if [[ "$has_auto_renew_section" == false ]] || [[ "$has_settings_section" == false ]]; then
        log_warn "检测到配置文件缺少必需的section，自动修复中..."
        log_warn "auto_renew section: $has_auto_renew_section, settings section: $has_settings_section"
        validate_and_repair_config "$config_file"
    elif [[ $invalid_lines -gt 5 ]]; then
        # 只有当无效行数过多时才进行修复，避免因少量格式问题导致程序退出
        log_warn "检测到过多无效行($invalid_lines)，自动修复中..."
        validate_and_repair_config "$config_file"
    elif [[ $invalid_lines -gt 0 ]]; then
        log_warn "检测到 $invalid_lines 行格式问题，但数量较少，跳过修复"
    fi
}

# 切换自动续期状态（安全版本）
toggle_auto_renew() {
    local index="$1"
    
    local domain=$(get_assoc_value "DOMAIN_LIST" "$index")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}错误: 无效的序号 $index${NC}"
        return 1
    fi
    
    local current_status=$(get_assoc_value "AUTO_RENEW_STATUS" "$domain")
    [[ -z "$current_status" ]] && current_status="false"
    
    local new_status
    if [[ "$current_status" == "true" ]]; then
        new_status="false"
        echo -e "${YELLOW}域名 $domain 的自动续期已关闭${NC}"
    else
        new_status="true"
        echo -e "${GREEN}域名 $domain 的自动续期已开启${NC}"
    fi
    
    # 更新内存中的状态
    set_assoc_value "AUTO_RENEW_STATUS" "$domain" "$new_status"
    
    # 使用精确的INI更新，只修改指定域名的配置
    update_ini_config "$AUTO_RENEW_CONFIG" "auto_renew" "$domain" "$new_status"
    
    log_info "域名 $domain 自动续期状态已安全切换为: $new_status"
}

# 主交互循环
main_loop() {
    while true; do
        display_certificates
        
        echo -n "请输入操作指令: "
        read -r input
        
        case "$input" in
            s*)
                local index="${input#s}"
                if [[ "$index" =~ ^[0-9]+$ ]]; then
                    manual_renew "$index"
                else
                    echo "请输入 s 后跟序号，例如: s1"
                    sleep 2
                fi
                ;;
            a)
                auto_renew_all
                scan_certificates  # 重新扫描以更新状态
                ;;
            r)
                scan_certificates
                ;;
            t*)
                local index="${input#t}"
                if [[ "$index" =~ ^[0-9]+$ ]]; then
                    toggle_auto_renew "$index"
                    sleep 2
                else
                    echo "请输入 t 后跟序号，例如: t1"
                    sleep 2
                fi
                ;;
            h)
                show_help
                echo "按任意键继续..."
                read -r < /dev/tty
                ;;
            q)
                echo -e "${BLUE}感谢使用域名证书管理面板!${NC}"
                exit 0
                ;;
            "")
                # 空输入，刷新显示
                continue
                ;;
            *)
                echo -e "${RED}无效的指令: $input${NC}"
                echo "输入 h 查看帮助信息"
                sleep 2
                ;;
        esac
    done
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto-renew)
                AUTO_RENEW_MODE=true
                shift
                ;;
            --cert-dir)
                CERT_DIR="$2"
                shift 2
                ;;
            --renew-script)
                RENEW_SCRIPT="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
}

# 主函数
main() {
    local AUTO_RENEW_MODE=false
    
    # 解析命令行参数
    parse_arguments "$@"
    
    # 初始化环境
    init_environment
    
    # 扫描证书
    scan_certificates
    
    # 根据模式执行
    if [[ "$AUTO_RENEW_MODE" == "true" ]]; then
        # 自动续期模式
        auto_renew_all false
        exit 0
    else
        # 交互模式
        main_loop
    fi
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi