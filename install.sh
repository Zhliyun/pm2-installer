#!/bin/bash

# PM2 Offline Installation Script
# Usage: ./install-parallel.sh [tgz_directory] [parallel_jobs]

# Note: Do not use set -e for better error handling

# Auto-detect directory: try script's directory first, then parameter, then current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$1" ]]; then
    # If no parameter provided, try to find packages directory relative to script
    if [[ -d "$SCRIPT_DIR/packages" ]]; then
        TGZ_DIR="$SCRIPT_DIR/packages"
    else
        TGZ_DIR="."
    fi
else
    TGZ_DIR="$1"
fi

# Default parallel jobs is half of CPU cores, minimum 2, maximum 8
DEFAULT_PARALLEL=$(( $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) / 2 ))
DEFAULT_PARALLEL=$(( DEFAULT_PARALLEL < 2 ? 2 : DEFAULT_PARALLEL ))
DEFAULT_PARALLEL=$(( DEFAULT_PARALLEL > 8 ? 8 : DEFAULT_PARALLEL ))
PARALLEL_JOBS="${2:-$DEFAULT_PARALLEL}"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "$GREEN[INFO]$NC $1"
}

log_warn() {
    echo -e "$YELLOW[WARN]$NC $1"
}

log_error() {
    echo -e "$RED[ERROR]$NC $1"
}

log_debug() {
    echo -e "$BLUE[DEBUG]$NC $1"
}

# Compare semantic versions (returns 0 if v1 >= v2, 1 if v1 < v2)
version_compare() {
    local v1="$1"
    local v2="$2"
    
    # Remove 'v' prefix if exists
    v1="${v1#v}"
    v2="${v2#v}"
    
    # Remove any whitespace
    v1=$(echo "$v1" | tr -d '[:space:]')
    v2=$(echo "$v2" | tr -d '[:space:]')
    
    # Validate version format
    if ! [[ "$v1" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        return 1  # Invalid v1, consider it less than v2
    fi
    if ! [[ "$v2" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        return 0  # Invalid v2, consider v1 greater
    fi
    
    # Split versions into array
    IFS='.' read -ra v1_parts <<< "$v1"
    IFS='.' read -ra v2_parts <<< "$v2"
    
    # Compare each part
    for i in 0 1 2; do
        local part1="${v1_parts[$i]:-0}"
        local part2="${v2_parts[$i]:-0}"
        
        # Remove non-numeric suffix (like -beta, -rc, etc)
        part1="${part1%%-*}"
        part2="${part2%%-*}"
        
        # Ensure parts are numeric
        if ! [[ "$part1" =~ ^[0-9]+$ ]]; then part1=0; fi
        if ! [[ "$part2" =~ ^[0-9]+$ ]]; then part2=0; fi
        
        if [[ $part1 -gt $part2 ]]; then
            return 0  # v1 > v2
        elif [[ $part1 -lt $part2 ]]; then
            return 1  # v1 < v2
        fi
    done
    
    return 0  # v1 == v2
}

# Get version from tgz file
get_tgz_version() {
    local tgz_file="$1"
    local extract_dir="$TEMP_DIR/version_check"
    
    mkdir -p "$extract_dir"
    tar -xzf "$tgz_file" -C "$extract_dir" --strip-components=1 2>/dev/null || return 1
    
    if [[ -f "$extract_dir/package.json" ]]; then
        local version=$(grep -m1 '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$extract_dir/package.json" | sed 's/.*"\([^"]*\)".*/\1/')
        rm -rf "$extract_dir"
        echo "$version"
        return 0
    else
        rm -rf "$extract_dir"
        return 1
    fi
}

# Check if npm exists
check_npm() {
    # If npm is already in PATH, we're good
    if command -v npm &> /dev/null; then
        log_info "npm version: $(npm --version)"
        return 0
    fi
    
    # Try to find npm in common system locations
    local npm_candidates=(
        "/usr/bin/npm"
        "/usr/local/bin/npm"
        "/opt/nodejs/bin/npm"
    )
    
    # Also check in user home directories (for nvm installations)
    if [ -d "/home" ]; then
        for user_home in /home/*; do
            if [ -d "$user_home/.nvm/versions/node" ]; then
                npm_candidates+=("$user_home/.nvm/versions/node/"*/bin/npm)
            fi
        done
    fi
    
    # Check root's nvm installation
    if [ -d "/root/.nvm/versions/node" ]; then
        npm_candidates+=("/root/.nvm/versions/node/"*/bin/npm)
    fi
    
    # Try each candidate
    for npm_path in "${npm_candidates[@]}"; do
        if [ -x "$npm_path" ] 2>/dev/null; then
            export PATH="$(dirname "$npm_path"):$PATH"
            log_info "Found npm at: $npm_path"
            log_info "npm version: $(npm --version)"
            return 0
        fi
    done
    
    # npm not found
    log_warn "npm not found, skipping PM2 installation"
    log_warn "Please install Node.js and npm manually, then run:"
    log_warn "  sudo $(dirname "$0")/install.sh"
    exit 0
}

# Clean up existing PM2 daemon processes
kill_pm2_daemon() {
    log_info "Checking and cleaning existing PM2 daemon processes..."
    
    if command -v pm2 &> /dev/null; then
        log_info "Found existing PM2 installation, executing pm2 kill..."
        if pm2 kill &> /dev/null; then
            log_info "PM2 daemon processes cleaned"
        else
            log_warn "Problem occurred while cleaning PM2 daemon processes, continuing installation..."
        fi
        # Wait for a while to ensure processes exit completely
        sleep 2
    else
        log_info "No existing PM2 installation found"
    fi
}

# Check tgz file directory
check_tgz_dir() {
    if [[ ! -d "$TGZ_DIR" ]]; then
        log_error "Directory does not exist: $TGZ_DIR"
        exit 1
    fi
    
    local tgz_count=$(find "$TGZ_DIR" -name "*.tgz" | wc -l)
    if [[ $tgz_count -eq 0 ]]; then
        log_error "No .tgz files found in directory $TGZ_DIR"
        exit 1
    fi
    
    log_info "Found $tgz_count .tgz files"
}

# Create temporary working directory
create_temp_dir() {
    TEMP_DIR=$(mktemp -d)
    log_info "Creating temporary directory: $TEMP_DIR"
    
    # Set cleanup on exit
    trap "rm -rf $TEMP_DIR" EXIT
}

# Parse package.json to get dependency relationships
parse_dependencies() {
    local tgz_file="$1"
    local extract_dir="$TEMP_DIR/$(basename "$tgz_file" .tgz)"
    
    # Extract to temporary directory
    mkdir -p "$extract_dir"
    tar -xzf "$tgz_file" -C "$extract_dir" --strip-components=1 2>/dev/null || return 1
    
    # Read package.json
    if [[ -f "$extract_dir/package.json" ]]; then
        # Extract package name and version
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
    
    # Clean up temporary extraction directory
    rm -rf "$extract_dir"
}

# Group packages by dependency order
categorize_packages() {
    local temp_mapping="$TEMP_DIR/package_mapping"
    local packages_list="$TEMP_DIR/packages_list"
    
    # Clear temporary files
    > "$temp_mapping"
    > "$packages_list"
    
    # First collect all package information
    while IFS= read -r -d '' tgz_file; do
        # Skip if file doesn't exist or is empty
        [[ ! -f "$tgz_file" ]] && continue
        
        local info=$(parse_dependencies "$tgz_file")
        local pkg_name=$(echo "$info" | cut -d'|' -f1)
        local file_path=$(echo "$info" | cut -d'|' -f2-)
        
        # Write package name and file path to temporary file (escape | in path)
        printf "%s|%s\n" "$pkg_name" "$file_path" >> "$temp_mapping"
        echo "$pkg_name" >> "$packages_list"
    done < <(find "$TGZ_DIR" -name "*.tgz" -print0)
    
    # Categorize packages: core dependencies, regular dependencies, PM2 main package
    local core_deps=()      # Core base dependencies, install first
    local regular_deps=()   # Regular dependencies, can install in parallel
    local pm2_core=()       # PM2 core packages, install after dependencies
    local pm2_main=""       # PM2 main package, install last
    
    while IFS='|' read -r pkg_name file_path; do
        if [[ -n "$file_path" && -f "$file_path" ]]; then
            case "$pkg_name" in
                # Core base dependencies, need to install first
                async@*|debug@*|semver@*|commander@*|eventemitter2@*|js-yaml@*)
                    core_deps+=("$file_path")
                    ;;
                # PM2 main package
                pm2@*)
                    pm2_main="$file_path"
                    ;;
                # PM2 related core packages
                *pm2-*|*@pm2*)
                    pm2_core+=("$file_path")
                    ;;
                # Other regular dependencies
                *)
                    regular_deps+=("$file_path")
                    ;;
            esac
        fi
    done < "$temp_mapping"
    
    # Output grouping results - use newline as separator to handle spaces in paths
    echo "===CORE_DEPS_BEGIN==="
    printf "%s\n" "${core_deps[@]}"
    echo "===CORE_DEPS_END==="
    echo "===REGULAR_DEPS_BEGIN==="
    printf "%s\n" "${regular_deps[@]}"
    echo "===REGULAR_DEPS_END==="
    echo "===PM2_CORE_BEGIN==="
    printf "%s\n" "${pm2_core[@]}"
    echo "===PM2_CORE_END==="
    echo "===PM2_MAIN==="
    echo "$pm2_main"
}

# Install package groups in parallel
parallel_install_group() {
    local packages=("$@")
    local total=${#packages[@]}
    
    if [[ $total -eq 0 ]]; then
        return 0
    fi
    
    local pids=()
    local results_dir="$TEMP_DIR/install_results"
    mkdir -p "$results_dir"
    local job_count=0
    
    for package_file in "${packages[@]}"; do
        # Wait until current job count is less than maximum parallel jobs
        while [[ ${#pids[@]} -ge $PARALLEL_JOBS ]]; do
            # Check completed jobs
            local new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            pids=("${new_pids[@]}")
            sleep 0.1
        done
        
        # Start new installation job
        (
            local pkg_name=$(basename "$package_file" .tgz)
            local job_id="$job_count"
            local result_file="$results_dir/$job_id.result"
            
            # Extract package name without version for uninstall check
            local pkg_base_name=$(echo "$pkg_name" | sed 's/-[0-9].*//')
            
            if npm install -g "$package_file" --no-audit --no-fund --silent >/dev/null 2>&1; then
                echo "SUCCESS:$pkg_name:$package_file" > "$result_file"
            else
                # If failed due to existing package, try to remove and reinstall
                npm uninstall -g "$pkg_base_name" --silent >/dev/null 2>&1 || true
                
                # Handle scoped packages (like @pm2/io)
                local scoped_path=""
                if [[ "$pkg_base_name" == pm2-* ]]; then
                    # Convert pm2-io to @pm2/io format
                    local scope_pkg="${pkg_base_name#pm2-}"
                    scoped_path="$(npm root -g)/@pm2/$scope_pkg"
                fi
                
                # Remove both regular and scoped package paths
                rm -rf "$(npm root -g)/$pkg_base_name" 2>/dev/null || true
                [[ -n "$scoped_path" ]] && rm -rf "$scoped_path" 2>/dev/null || true
                
                # Try installation again
                if npm install -g "$package_file" --no-audit --no-fund --silent >/dev/null 2>&1; then
                    echo "SUCCESS:$pkg_name:$package_file" > "$result_file"
                else
                    # Last resort: force installation
                    if npm install -g "$package_file" --force --no-audit --no-fund --silent >/dev/null 2>&1; then
                        echo "SUCCESS_FORCE:$pkg_name:$package_file" > "$result_file"
                    else
                        echo "FAILED:$pkg_name:$package_file" > "$result_file"
                    fi
                fi
            fi
        ) &
        
        local pid=$!
        pids+=("$pid")
        ((job_count++))
    done
    
    # Wait for all jobs to complete
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Calculate statistics
    local success=0
    local failed=0
    local force_success=0
    
    for ((i=0; i<job_count; i++)); do
        local idx="$i"
        local result_file="$results_dir/$idx.result"
        if [[ -f "$result_file" ]]; then
            local result=$(cat "$result_file")
            local status=$(echo "$result" | cut -d':' -f1)
            local pkg_name=$(echo "$result" | cut -d':' -f2)
            
            case "$status" in
                SUCCESS)
                    echo -e "$GREEN[OK]$NC $pkg_name"
                    ((success++))
                    ;;
                SUCCESS_FORCE)
                    echo -e "$YELLOW[OK]$NC $pkg_name (forced)"
                    ((force_success++))
                    ;;
                FAILED)
                    echo -e "$RED[FAIL]$NC $pkg_name"
                    ((failed++))
                    ;;
            esac
        fi
    done
    
    local total_success=$((success + force_success))
    if [ $failed -eq 0 ]; then
        log_info "All $total_success packages installed successfully"
    else
        log_info "$total_success packages installed successfully, $failed packages failed"
    fi
    
    return $failed
}

# Install single package (for PM2 main package)
install_single_package() {
    local tgz_file="$1"
    local pkg_name=$(basename "$tgz_file" .tgz)
    local pkg_base_name=$(echo "$pkg_name" | sed 's/-[0-9].*//')
    
    if npm install -g "$tgz_file" --no-audit --no-fund --silent >/dev/null 2>&1; then
        return 0
    else
        # If failed due to existing package, try to remove and reinstall
        log_info "Cleaning existing $pkg_base_name installation..."
        npm uninstall -g "$pkg_base_name" --silent >/dev/null 2>&1 || true
        rm -rf "$(npm root -g)/$pkg_base_name" 2>/dev/null || true
        
        # Try installation again
        if npm install -g "$tgz_file" --no-audit --no-fund --silent >/dev/null 2>&1; then
            return 0
        else
            # Last resort: force installation
            if npm install -g "$tgz_file" --force --no-audit --no-fund --silent >/dev/null 2>&1; then
                return 0
            else
                log_error "PM2 installation failed"
                return 1
            fi
        fi
    fi
}

# Verify PM2 installation
verify_pm2() {
    log_info "Verifying PM2 installation..."
    
    # Refresh PATH
    hash -r
    
    # Wait for npm to complete
    sleep 2
    
    if command -v pm2 &> /dev/null; then
        local pm2_version=$(pm2 --version 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || echo "unknown")
        log_info "PM2 installed successfully, version: $pm2_version"
        
        # Test basic functionality
        if pm2 list &> /dev/null; then
            log_info "PM2 functionality is normal"
        else
            log_warn "PM2 is installed but may have issues"
        fi
        return 0
    else
        # Try to use npm global path directly
        local npm_global_path=$(npm root -g 2>/dev/null)
        if [[ -n "$npm_global_path" && -f "$npm_global_path/../bin/pm2" ]]; then
            log_info "PM2 installed at: $npm_global_path/../bin/pm2"
            log_info "Recommend adding $(dirname $(npm root -g))/bin to PATH"
            return 0
        else
            log_error "PM2 not correctly installed"
            return 1
        fi
    fi
}

# Check if PM2 version is already sufficient
check_pm2_version() {
    local pm2_tgz="$1"
    
    # If PM2 is not installed, need to install
    if ! command -v pm2 &> /dev/null; then
        return 1  # Need installation
    fi
    
    # Get current version
    local current_version=$(pm2 --version 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
    if [[ -z "$current_version" ]]; then
        log_warn "Unable to get current PM2 version, proceeding with installation"
        return 1  # Need installation
    fi
    
    # Get target version from tgz
    local target_version=$(get_tgz_version "$pm2_tgz")
    if [[ -z "$target_version" ]]; then
        log_warn "Unable to get target PM2 version, proceeding with installation"
        return 1  # Need installation
    fi
    
    log_info "Current PM2 version: $current_version"
    log_info "Target PM2 version: $target_version"
    
    # Compare versions
    if version_compare "$current_version" "$target_version"; then
        log_info "Current PM2 version ($current_version) >= target version ($target_version)"
        return 0  # Skip installation
    else
        log_info "Current PM2 version ($current_version) < target version ($target_version)"
        return 1  # Need installation
    fi
}

# Main function
main() {
    log_info "Starting PM2 installation..."
    
    # Check environment
    check_npm
    kill_pm2_daemon
    check_tgz_dir
    create_temp_dir
    
    # Get grouped package list
    local categorization=$(categorize_packages)
    
    # Parse grouping results
    local core_deps=()
    local regular_deps=()
    local pm2_core=()
    local pm2_main=""
    
    local in_section=""
    while IFS= read -r line; do
        case "$line" in
            "===CORE_DEPS_BEGIN===")
                in_section="core"
                ;;
            "===CORE_DEPS_END===")
                in_section=""
                ;;
            "===REGULAR_DEPS_BEGIN===")
                in_section="regular"
                ;;
            "===REGULAR_DEPS_END===")
                in_section=""
                ;;
            "===PM2_CORE_BEGIN===")
                in_section="pm2core"
                ;;
            "===PM2_CORE_END===")
                in_section=""
                ;;
            "===PM2_MAIN===")
                in_section="pm2main"
                ;;
            *)
                if [ -n "$line" ]; then
                    case "$in_section" in
                        "core")
                            core_deps+=("$line")
                            ;;
                        "regular")
                            regular_deps+=("$line")
                            ;;
                        "pm2core")
                            pm2_core+=("$line")
                            ;;
                        "pm2main")
                            pm2_main="$line"
                            ;;
                    esac
                fi
                ;;
        esac
    done <<< "$categorization"
    
    # Early version check - skip installation if current version is sufficient
    if [[ -n "$pm2_main" && -f "$pm2_main" ]]; then
        if check_pm2_version "$pm2_main"; then
            log_info "PM2 installation skipped, existing version is sufficient"
            log_info "Only daemon cleanup was performed"
            
            # Verify PM2
            if verify_pm2; then
                log_info "PM2 daemon cleanup completed successfully!"
                return 0
            else
                log_error "PM2 verification failed"
                return 1
            fi
        else
            log_info "Proceeding with PM2 installation..."
        fi
    else
        log_error "PM2 main package not found"
        exit 1
    fi
    
    local total_failures=0
    
    # Stage 1: Install core dependencies
    if [[ ${#core_deps[@]} -gt 0 ]]; then
        log_info "Installing core dependencies..."
        parallel_install_group "${core_deps[@]}"
        total_failures=$((total_failures + $?))
    fi
    
    # Stage 2: Install regular dependencies in parallel
    if [[ ${#regular_deps[@]} -gt 0 ]]; then
        log_info "Installing regular dependencies..."
        parallel_install_group "${regular_deps[@]}"
        total_failures=$((total_failures + $?))
    fi
    
    # Stage 3: Install PM2 core packages
    if [[ ${#pm2_core[@]} -gt 0 ]]; then
        log_info "Installing PM2 core packages..."
        parallel_install_group "${pm2_core[@]}"
        total_failures=$((total_failures + $?))
    fi
    
    # Stage 4: Install PM2 main package
    if [[ -n "$pm2_main" && -f "$pm2_main" ]]; then
        log_info "Installing PM2..."
        install_single_package "$pm2_main"
        total_failures=$((total_failures + $?))
    else
        log_error "PM2 main package not found"
        total_failures=$((total_failures + 1))
    fi
    
    # Installation results
    if [[ $total_failures -eq 0 ]]; then
        log_info "All packages installed successfully!"
    else
        log_warn "$total_failures packages failed to install"
    fi
    
    # Verify PM2
    if verify_pm2; then
        log_info "PM2 installation completed successfully!"
    else
        log_error "PM2 installation verification failed"
        exit 1
    fi
}

# Show help
show_help() {
    echo "PM2 Offline Parallel Installation Script"
    echo
    echo "Usage:"
    echo "  $0 [tgz_directory] [parallel_jobs]"
    echo
    echo "Parameters:"
    echo "  tgz_directory    Directory path containing all tgz files (default: current directory)"
    echo "  parallel_jobs    Maximum number of parallel installation jobs (default: half of CPU cores, min 2, max 8)"
    echo
    echo "Examples:"
    echo "  $0                    # Use current directory, auto-detect parallel jobs"
    echo "  $0 ./packages         # Use ./packages directory, auto-detect parallel jobs"
    echo "  $0 ./packages 4       # Use ./packages directory, 4 parallel jobs"
    echo "  $0 /path/to/tgz 6     # Use specified path, 6 parallel jobs"
    echo
}

# Process command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
